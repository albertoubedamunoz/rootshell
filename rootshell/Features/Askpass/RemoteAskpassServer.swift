//
//  RemoteAskpassServer.swift
//  rootshell
//
//  Serves `rootshell-askpass` connections arriving on a session's
//  forwarded Unix socket. One server per session; one pending request
//  at a time.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Synchronization
import os

@MainActor
final class RemoteAskpassServer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RemoteAskpassServer")

    nonisolated static let readTimeout: Duration = .seconds(10)
    nonisolated static let answerTimeout: Duration = .seconds(120)

    let remoteHost: String
    let remoteUser: String
    let sessionName: String

    /// Request delivery and withdrawal are both synchronous so the UI sees
    /// them in order; a withdrawal can never overtake its request.
    private let onRequest: @MainActor (RemoteAskpassRequest) -> Void
    private let onWithdrawal: @MainActor (UUID) -> Void

    private var pending: (id: UUID, resumer: AnswerResumer)?
    private var isShutDown = false

    init(
        remoteHost: String,
        remoteUser: String,
        sessionName: String,
        onRequest: @escaping @MainActor (RemoteAskpassRequest) -> Void,
        onWithdrawal: @escaping @MainActor (UUID) -> Void
    ) {
        self.remoteHost = remoteHost
        self.remoteUser = remoteUser
        self.sessionName = sessionName
        self.onRequest = onRequest
        self.onWithdrawal = onWithdrawal
    }

    /// Serves one forwarded connection: read the request, wait for the
    /// user, write the reply, close.
    func serve(stream: any AsyncBytePipe) async {
        let reply: Data
        do {
            if let request = try await readRequest(from: stream) {
                reply = await answer(request, stream: stream)
            } else {
                await stream.close()
                return
            }
        } catch {
            Self.logger.warning("Rejected credential request: \(String(describing: error))")
            reply = RemoteAskpassProtocol.failure(.protocolError)
        }
        try? await stream.write(reply)
        await stream.close()
    }

    /// Cancels the pending request and stops accepting new ones. Called on
    /// session teardown, while the session can still deliver the withdrawal.
    func shutdown() {
        isShutDown = true
        guard let pending else { return }
        self.pending = nil
        onWithdrawal(pending.id)
        pending.resumer.resume(.canceled)
    }

    // MARK: - Internals

    private func readRequest(from stream: any AsyncBytePipe) async throws -> RemoteAskpassProtocol.Request? {
        // Closing the pipe unblocks a read from a client that never finishes.
        let watchdog = Task {
            guard (try? await Task.sleep(for: Self.readTimeout)) != nil else { return }
            await stream.close()
        }
        defer { watchdog.cancel() }

        var buffer = Data()
        while true {
            guard let chunk = try await stream.read(maxBytes: 4096) else { return nil }
            buffer.append(chunk)
            if let request = try RemoteAskpassProtocol.parse(buffer) {
                return request
            }
        }
    }

    private func answer(_ request: RemoteAskpassProtocol.Request, stream: any AsyncBytePipe) async -> Data {
        guard !isShutDown else { return RemoteAskpassProtocol.failure(.canceled) }
        guard pending == nil else { return RemoteAskpassProtocol.failure(.busy) }

        let id = UUID()
        let resumer = AnswerResumer()
        pending = (id, resumer)
        defer { if pending?.id == id { pending = nil } }

        let timeout = Task {
            guard (try? await Task.sleep(for: Self.answerTimeout)) != nil else { return }
            resumer.resume(.timeout)
        }
        defer { timeout.cancel() }

        // EOF or a read error while waiting means the helper hung up (e.g.
        // Ctrl-C). Also ends when serve() closes the stream after replying.
        Task {
            while let _ = try? await stream.read(maxBytes: 4096) {}
            resumer.resume(.disconnected)
        }

        let outcome = await withCheckedContinuation { continuation in
            resumer.attach(continuation)
            onRequest(RemoteAskpassRequest(
                id: id,
                remoteHost: remoteHost,
                remoteUser: remoteUser,
                sessionName: sessionName,
                prompt: request.prompt,
                command: request.command,
                completion: { value in
                    resumer.resume(value.map(AnswerResumer.Outcome.value) ?? .canceled)
                }
            ))
        }
        // No-op when the UI already dismissed it.
        onWithdrawal(id)

        switch outcome {
        case .value(let value): return RemoteAskpassProtocol.success(value)
        case .canceled, .disconnected: return RemoteAskpassProtocol.failure(.canceled)
        case .timeout: return RemoteAskpassProtocol.failure(.timeout)
        }
    }
}

/// Resumes once, from whichever of the UI, the timeout, or shutdown
/// fires first.
nonisolated private final class AnswerResumer: Sendable {
    enum Outcome: Sendable {
        case value(String)
        case canceled
        case timeout
        case disconnected
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, Never>?
        var early: Outcome?
        var done = false
    }

    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<Outcome, Never>) {
        let early: Outcome? = state.withLock {
            if let early = $0.early { return early }
            $0.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ outcome: Outcome) {
        let continuation: CheckedContinuation<Outcome, Never>? = state.withLock {
            guard !$0.done else { return nil }
            $0.done = true
            guard let continuation = $0.continuation else {
                $0.early = outcome
                return nil
            }
            $0.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
