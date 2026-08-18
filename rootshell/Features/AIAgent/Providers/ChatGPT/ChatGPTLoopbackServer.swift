#if !CHINA_BUILD
//
//  ChatGPTLoopbackServer.swift
//  rootshell
//
//  Minimal one-shot HTTP listener that catches the OAuth redirect on
//  http://localhost:1455/auth/callback.
//

import Foundation
import Network
import os.log

/// Listens on port 1455 for exactly one `GET /auth/callback` and hands back the
/// authorization code.
///
/// OpenAI pins the redirect to `http://localhost:1455/auth/callback`, so the port
/// is not negotiable; a different one makes the token exchange fail with 403.
/// This is deliberately not `Cloud/OAuth/OAuthCallbackServer` — that listener
/// binds all interfaces (triggering the Local Network prompt), while this one is
/// loopback-only.
nonisolated final class ChatGPTLoopbackServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTLoopback")
    private let queue = DispatchQueue(label: "com.ghostty.chatgpt-oauth-callback")

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var expectedState = ""
    private let lock = NSLock()

    /// Starts listening and suspends until the browser redirects back.
    /// - Returns: the `code` query parameter, once `state` has been verified.
    func waitForCallback(expectedState: String, timeout: TimeInterval = 300) async throws -> String {
        self.expectedState = expectedState

        return try await withCheckedThrowingContinuation { continuation in
            let work = DispatchWorkItem { [weak self] in
                self?.finish(with: .failure(ChatGPTAuthError.cancelled))
            }

            lock.lock()
            self.continuation = continuation
            // Armed before the listener starts so that a callback arriving
            // immediately can cancel it, rather than leaving a stray timer.
            self.timeoutWork = work
            lock.unlock()

            queue.asyncAfter(deadline: .now() + timeout, execute: work)

            do {
                try start()
            } catch {
                finish(with: .failure(error))
            }
        }
    }

    /// Tears the listener down and fails any in-flight wait. Safe to call twice.
    func stop() {
        finish(with: .failure(ChatGPTAuthError.cancelled))
    }

    // MARK: - Listener

    private func start() throws {
        let parameters = NWParameters.tcp
        // Without reuse, a listener torn down moments earlier leaves the port in
        // TIME_WAIT and a retried sign-in fails with EADDRINUSE.
        parameters.allowLocalEndpointReuse = true
        // Restricting to lo0 keeps the socket off the LAN (so no Local Network
        // permission prompt) while still covering both ::1 and 127.0.0.1 —
        // Safari resolves "localhost" to ::1 first, so IPv4-only would miss it.
        parameters.requiredInterfaceType = .loopback

        guard let port = NWEndpoint.Port(rawValue: ChatGPTOAuth.callbackPort) else {
            throw ChatGPTAuthError.portUnavailable
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            logger.error("Failed to open port \(ChatGPTOAuth.callbackPort): \(error)")
            throw ChatGPTAuthError.portUnavailable
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.logger.info("Listening on 127.0.0.1:\(ChatGPTOAuth.callbackPort)")
            case .failed(let error):
                self.logger.error("Listener failed: \(error)")
                self.finish(with: .failure(ChatGPTAuthError.portUnavailable))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()

        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }

            // Only the request line matters; wait for the end of the headers.
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                self.respond(on: connection, to: request)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            // Cap the buffer so a malformed request can't grow without bound.
            guard buffer.count < 64 * 1024 else {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(on connection: NWConnection, to request: String) {
        let result = Self.parse(request: request, expectedState: expectedState)

        let (status, title, message): (String, String, String)
        switch result {
        case .success:
            (status, title, message) = (
                "200 OK",
                "Signed in",
                "You can close this page and return to rootshell."
            )
        case .failure(let error):
            (status, title, message) = (
                "400 Bad Request",
                "Sign-in failed",
                error.localizedDescription
            )
        case nil:
            // Some other path (e.g. /favicon.ico); answer and keep waiting.
            let body = Self.page(title: "Not found", message: "")
            connection.send(content: Self.http(status: "404 Not Found", body: body), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let body = Self.page(title: title, message: message)
        connection.send(content: Self.http(status: status, body: body), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.finish(with: result!)
        })
    }

    // MARK: - Parsing

    /// Returns nil when the request is for some path other than the callback.
    static func parse(request: String, expectedState: String) -> Result<String, Error>? {
        guard let requestLine = request.split(separator: "\r\n").first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }

        let target = String(fields[1])
        guard let components = URLComponents(string: "http://localhost\(target)"),
              components.path == ChatGPTOAuth.callbackPath else {
            return nil
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nilIfBlank
        }

        if let error = value("error") {
            let detail = value("error_description") ?? error
            return .failure(ChatGPTAuthError.authorizationDenied(detail))
        }

        guard value("state") == expectedState else {
            return .failure(ChatGPTAuthError.stateMismatch)
        }

        guard let code = value("code") else {
            return .failure(ChatGPTAuthError.authorizationDenied("no authorization code was returned"))
        }

        return .success(code)
    }

    // MARK: - Responses

    private static func http(status: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        return Data(header.utf8) + bodyData
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title></head>
        <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:4rem 1.5rem;color:#111">
        <h1 style="font-size:1.5rem;margin:0 0 .5rem">\(title)</h1>
        <p style="color:#666;margin:0">\(message)</p>
        </body></html>
        """
    }

    // MARK: - Teardown

    private func finish(with result: Result<String, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let listener = self.listener
        self.listener = nil
        let connections = self.connections
        self.connections = []
        let timeoutWork = self.timeoutWork
        self.timeoutWork = nil
        lock.unlock()

        timeoutWork?.cancel()
        listener?.cancel()
        connections.forEach { $0.cancel() }

        guard let continuation else { return }
        switch result {
        case .success(let code):
            continuation.resume(returning: code)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
