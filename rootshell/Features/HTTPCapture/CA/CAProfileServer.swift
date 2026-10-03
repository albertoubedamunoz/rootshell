//
//  CAProfileServer.swift
//  rootshell
//
//  Short-lived loopback HTTP server that hands the capture CA profile to
//  Safari (iOS only installs profiles downloaded through Safari). Used when
//  no VPN is up; otherwise the engine serves it at http://10.0.0.1/.
//

#if !CHINA_BUILD

import Foundation
import Network
import UIKit

@MainActor
final class CAProfileServer {
    static let shared = CAProfileServer()

    private var listener: NWListener?
    private var profile = Data()
    private var stopTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let queue = DispatchQueue(label: "com.rootshell.capture.profile-server")

    /// Starts (or refreshes) the server and returns the profile URL.
    func serve(_ profile: Data) async throws -> URL {
        self.profile = profile
        if listener == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.handle(connection) }
            }
            self.listener = listener
            try await waitUntilReady(listener)
        }
        guard let port = listener?.port?.rawValue else { throw CocoaError(.fileReadUnknown) }
        // Safari takes the foreground; keep serving long enough for the download.
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CaptureProfileServer") { [weak self] in
                Task { @MainActor in self?.stop() }
            }
        }
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        return URL(string: "http://127.0.0.1:\(port)/rootshell-capture-ca.mobileconfig")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stopTask?.cancel()
        stopTask = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func waitUntilReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // Handler calls are serialized on `queue`; clearing it guarantees one resume.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ connection: NWConnection) {
        let body = profile
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 << 10) { _, _, _, _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-apple-aspen-config\r\n"
                + "Content-Disposition: attachment; filename=\"rootshell-capture-ca.mobileconfig\"\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

#endif
