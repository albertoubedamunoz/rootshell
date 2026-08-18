//
//  ExternalSSHAgentClient.swift
//  rootshell (Catalyst Standalone + native macOS rootshellvpn host)
//
//  Client for a local OpenSSH agent (1Password, Secretive, ssh-agent) over its
//  AF_UNIX socket. Only the two operations every agent supports are used:
//  list identities and sign. Blocking socket I/O with per-call timeouts; one
//  fresh connection per operation so instances are freely usable from the
//  main actor (via Task.detached) and from NIO event-loop threads.
//

#if (targetEnvironment(macCatalyst) && STANDALONE) || os(macOS)

import Foundation
import Darwin
import os.log

/// A key served by an external agent. Secret material never leaves the agent.
nonisolated struct ExternalAgentIdentity: Sendable, Hashable, Identifiable {
    let publicKeyBlob: Data
    let comment: String

    var id: Data { publicKeyBlob }

    /// Algorithm string, i.e. the first SSH string of the public key blob
    /// ("ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa", ...).
    var algorithm: String {
        var reader = SSHAgentReader(publicKeyBlob)
        return reader.readString() ?? ""
    }

    var isCertificate: Bool { algorithm.hasSuffix("-cert-v01@openssh.com") }
    var isSecurityKey: Bool { algorithm.hasPrefix("sk-") }
}

nonisolated enum ExternalAgentError: LocalizedError, Sendable, Equatable {
    case socketNotFound(String)
    case pathTooLong(String)
    case connectFailed(errno: Int32)
    case timeout
    case agentFailure
    case keyNotInAgent
    case cancelled
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .socketNotFound(let path):
            return "No SSH agent socket at \(path). Is the agent running?"
        case .pathTooLong(let path):
            return "Agent socket path is too long for a unix socket: \(path)"
        case .connectFailed(let err):
            if err == ECONNREFUSED {
                return "The SSH agent socket exists but nothing is listening (stale socket?)."
            }
            return "Could not connect to the SSH agent (errno \(err))."
        case .timeout:
            return "The SSH agent did not respond in time."
        case .agentFailure:
            return "The SSH agent declined the request."
        case .keyNotInAgent:
            return "This key is no longer available in the SSH agent."
        case .cancelled:
            return "The SSH agent request was cancelled."
        case .protocolError(let detail):
            return "Unexpected reply from the SSH agent: \(detail)"
        }
    }
}

/// Lets another thread abort a blocking agent round trip: `cancel()`
/// shuts down the registered socket so the owning thread's blocked read
/// returns immediately. Only `shutdown(2)` is issued from the cancelling
/// side — the owning thread always does the `close(2)` itself, so there is
/// no descriptor-reuse race. One token covers one logical operation (it
/// stays cancelled once cancelled).
nonisolated final class ExternalAgentCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    /// Owner registers its live socket. Returns false when the token was
    /// already cancelled — the caller should close the fd and bail.
    func register(fd: Int32) -> Bool {
        lock.withLock {
            if cancelled { return false }
            self.fd = fd
            return true
        }
    }

    /// Owner detaches the socket before closing it.
    func unregister() {
        lock.withLock { fd = -1 }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if fd >= 0 {
                shutdown(fd, SHUT_RDWR)
            }
        }
    }
}

/// Blocking ssh-agent protocol client. Thread-safe: immutable state, one
/// socket per call.
nonisolated final class ExternalSSHAgentClient: Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "ExternalSSHAgent")

    /// Signing waits out an interactive approval dialog (1Password shows one
    /// on every signature unless the user enables approval caching).
    static let signTimeout: TimeInterval = 120
    static let listTimeout: TimeInterval = 3

    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Operations

    func listIdentities(timeout: TimeInterval = ExternalSSHAgentClient.listTimeout) throws -> [ExternalAgentIdentity] {
        let response = try roundTrip(frame: SSHAgentWireCodec.requestIdentitiesFrame, timeout: timeout)
        switch response {
        case .identities(let identities):
            return identities.map { ExternalAgentIdentity(publicKeyBlob: $0.publicKeyBlob, comment: $0.comment) }
        case .failure:
            throw ExternalAgentError.agentFailure
        case .signature, .unknown:
            throw ExternalAgentError.protocolError("expected identities answer")
        }
    }

    /// Returns the raw SSH signature blob (`string algorithm, string signature`).
    /// `cancellation` lets another thread abort the blocking round trip
    /// (the VPN broker uses it so a stopped tunnel doesn't leave an agent
    /// approval prompt pending for the full timeout).
    func sign(
        keyBlob: Data,
        data: Data,
        flags: UInt32,
        timeout: TimeInterval = ExternalSSHAgentClient.signTimeout,
        cancellation: ExternalAgentCancellationToken? = nil
    ) throws -> Data {
        let frame = SSHAgentWireCodec.signRequestFrame(keyBlob: keyBlob, data: data, flags: flags)
        let response = try roundTrip(frame: frame, timeout: timeout, cancellation: cancellation)
        switch response {
        case .signature(let blob):
            return blob
        case .failure:
            // Agents answer SSH_AGENT_FAILURE both for "no such key" and
            // "user declined" — re-list (best effort) to tell them apart.
            if let identities = try? listIdentities(),
               !identities.contains(where: { $0.publicKeyBlob == keyBlob }) {
                throw ExternalAgentError.keyNotInAgent
            }
            throw ExternalAgentError.agentFailure
        case .identities, .unknown:
            throw ExternalAgentError.protocolError("expected sign response")
        }
    }

    /// True if something at `socketPath` answers a list request.
    static func probe(socketPath: String, timeout: TimeInterval = 1.5) -> Bool {
        let client = ExternalSSHAgentClient(socketPath: socketPath)
        return (try? client.listIdentities(timeout: timeout)) != nil
    }

    // MARK: - Transport

    private func roundTrip(
        frame: Data,
        timeout: TimeInterval,
        cancellation: ExternalAgentCancellationToken? = nil
    ) throws -> SSHAgentWireCodec.ClientResponse {
        let fd = try connect(timeout: timeout)
        if let cancellation, !cancellation.register(fd: fd) {
            close(fd)
            throw ExternalAgentError.cancelled
        }
        defer {
            cancellation?.unregister()
            close(fd)
        }

        SSHAgentWireCodec.writeFrame(fd: fd, frame: frame)
        guard let reply = SSHAgentWireCodec.readFrame(fd: fd) else {
            if cancellation?.isCancelled == true {
                throw ExternalAgentError.cancelled
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ExternalAgentError.timeout
            }
            throw ExternalAgentError.protocolError("connection closed by agent")
        }
        return SSHAgentWireCodec.parseClientResponse(frame: reply)
    }

    private func connect(timeout: TimeInterval) throws -> Int32 {
        var addr = sockaddr_un()
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < cap else {
            throw ExternalAgentError.pathTooLong(socketPath)
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw ExternalAgentError.socketNotFound(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ExternalAgentError.connectFailed(errno: errno) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString {
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, cap - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        guard rc == 0 else {
            let err = errno
            close(fd)
            Self.logger.warning("agent connect failed: errno \(err) path \(self.socketPath, privacy: .public)")
            throw ExternalAgentError.connectFailed(errno: err)
        }
        return fd
    }
}

#endif
