#if !CHINA_BUILD
//
//  ChatGPTLoopbackServer.swift
//  rootshell
//
//  Minimal one-shot HTTP listener that catches the OAuth redirect on
//  http://127.0.0.1:<port>/auth/callback.
//

import Foundation
import Network
import os.log

/// What the authorization redirect carried.
nonisolated struct ChatGPTCallback: Sendable {
    let code: String
    /// The issued client ID; present on new registrations, may be absent on reauthorization.
    let clientID: String?
    let scopes: [String]?
}

/// Listens for exactly one `GET /auth/callback`.
///
/// Prefers port 1455 and falls back to any free port; OpenAI only lets the
/// port vary, so the redirect URI is built from whichever port bound.
/// This is deliberately not `Cloud/OAuth/OAuthCallbackServer` — that listener
/// binds all interfaces (triggering the Local Network prompt), while this one is
/// loopback-only.
nonisolated final class ChatGPTLoopbackServer: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.rootshell", category: "ChatGPTLoopback")
    private let queue = DispatchQueue(label: "com.ghostty.chatgpt-oauth-callback")

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<ChatGPTCallback, Error>?
    /// A result that arrived before `waitForCallback` was called.
    private var pendingResult: Result<ChatGPTCallback, Error>?
    private var timeoutWork: DispatchWorkItem?
    private var expectedState = ""
    private let lock = NSLock()

    /// Binds the listener and returns the port the redirect URI must use.
    func start(expectedState: String) async throws -> UInt16 {
        lock.withLock { self.expectedState = expectedState }

        if let preferred = NWEndpoint.Port(rawValue: ChatGPTOAuth.preferredCallbackPort),
           let port = try? await listen(on: preferred) {
            return port
        }
        logger.info("Port \(ChatGPTOAuth.preferredCallbackPort) unavailable; using an ephemeral port")
        return try await listen(on: .any)
    }

    /// Suspends until the browser redirects back.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> ChatGPTCallback {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.finish(with: .failure(ChatGPTAuthError.cancelled))
            }
            self.continuation = continuation
            self.timeoutWork = work
            lock.unlock()

            queue.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Tears the listener down and fails any in-flight wait. Safe to call twice.
    func stop() {
        finish(with: .failure(ChatGPTAuthError.cancelled))
    }

    // MARK: - Listener

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Without reuse, a listener torn down moments earlier leaves the port in
        // TIME_WAIT and a retried sign-in fails with EADDRINUSE.
        parameters.allowLocalEndpointReuse = true
        // Restricting to lo0 keeps the socket off the LAN, so no Local Network prompt.
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw ChatGPTAuthError.listenerUnavailable
        }

        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let bound = listener.port?.rawValue, bound != 0 else {
                        if once.claim() {
                            listener.cancel()
                            continuation.resume(throwing: ChatGPTAuthError.listenerUnavailable)
                        }
                        return
                    }
                    if once.claim() {
                        self?.logger.info("Listening on 127.0.0.1:\(bound)")
                        continuation.resume(returning: bound)
                    }
                case .failed, .waiting:
                    if once.claim() {
                        listener.cancel()
                        continuation.resume(throwing: ChatGPTAuthError.listenerUnavailable)
                    } else if case .failed(let error) = state, let self, self.isCurrent(listener) {
                        self.logger.error("Listener failed: \(error)")
                        self.finish(with: .failure(ChatGPTAuthError.listenerUnavailable))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            lock.lock()
            self.listener = listener
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    /// A listener abandoned for the fallback port must not tear down its replacement.
    private func isCurrent(_ listener: NWListener) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.listener === listener
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
        lock.lock()
        let expectedState = self.expectedState
        lock.unlock()

        guard let result = Self.parse(request: request, expectedState: expectedState) else {
            // Some other path (e.g. /favicon.ico); answer and keep waiting.
            let body = Self.page(title: "Not found", message: "")
            connection.send(content: Self.http(status: "404 Not Found", body: body), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

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
        }

        let body = Self.page(title: title, message: message)
        connection.send(content: Self.http(status: status, body: body), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.finish(with: result)
        })
    }

    // MARK: - Parsing

    /// Returns nil when the request is for some path other than the callback.
    /// `state` is checked before anything else, including an error result.
    static func parse(request: String, expectedState: String) -> Result<ChatGPTCallback, Error>? {
        guard let requestLine = request.split(separator: "\r\n").first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET" else { return nil }

        let target = String(fields[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
              components.path == ChatGPTOAuth.callbackPath else {
            return nil
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.nilIfBlank
        }

        guard !expectedState.isEmpty, value("state") == expectedState else {
            return .failure(ChatGPTAuthError.stateMismatch)
        }

        if let error = value("error") {
            if error == "access_denied" {
                return .failure(ChatGPTAuthError.accessDenied)
            }
            return .failure(ChatGPTAuthError.authorizationFailed(value("error_description") ?? error))
        }

        guard let code = value("code") else {
            return .failure(ChatGPTAuthError.authorizationFailed("no authorization code was returned"))
        }

        return .success(ChatGPTCallback(
            code: code,
            clientID: value("client_id"),
            scopes: value("scope").map(ChatGPTOAuth.parseScopes)
        ))
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

    private func finish(with result: Result<ChatGPTCallback, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil, pendingResult == nil {
            pendingResult = result
        }
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

        continuation?.resume(with: result)
    }
}

/// Guards a continuation that several listener states could resume.
private nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private nonisolated extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
