//
//  VPNHostConnection.swift
//  rootshell (Catalyst, Standalone)
//
//  Socket client to the native macOS VPN host agent (`rootshellvpn.app`). The
//  Catalyst app cannot host a packet tunnel, so it drives the host over the
//  App Group unix socket (both run as the same user). Wire format reuses
//  `SocketMessage` (length-prefixed JSON) — identical to `VPNControlServer`.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import Darwin
import os.log

enum VPNHostConnectionError: LocalizedError {
    case socketUnavailable
    case connectFailed(Int32)
    case untrustedPeer
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "VPN control socket unavailable."
        case .connectFailed(let e): return "Could not reach the VPN host (errno \(e))."
        case .untrustedPeer: return "The process answering the VPN control socket is not the rootshell VPN helper."
        case .requestFailed(let m): return m
        }
    }
}

/// One request/response round trip to the host over the App Group unix socket.
enum VPNHostConnection {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VPNHostConnection")

    /// Send a control request and decode the response. Blocking socket I/O,
    /// run off the main actor by the caller. `nonisolated` so it never hops back
    /// to the main actor (which would beachball the UI during a slow host reply).
    nonisolated static func send(
        _ request: VPNControlRequest, timeoutSeconds: Int = 10
    ) throws -> VPNControlResponse {
        guard let path = VPNControlPaths.controlSocketPath else {
            throw VPNHostConnectionError.socketUnavailable
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPNHostConnectionError.connectFailed(errno) }
        defer { close(fd) }

        // Hard timeouts: a host that accepts but never replies must fail the
        // request, not hang the app's status polling / connect flow forever.
        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, cap - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw VPNHostConnectionError.connectFailed(errno) }

        // A successful connect proves nothing: any same-user process can
        // pre-bind the App Group socket path and impersonate the host to
        // capture the resolved SSH credentials a startVPN request carries.
        // Verify the listener's code signature before sending a single byte.
        guard VPNPeerTrust.isPeerTrusted(fd: fd, requirement: VPNPeerTrust.hostServerRequirement) else {
            let pid = VPNPeerTrust.peerPID(fd: fd)
            logger.error("control socket answered by untrusted peer (pid \(pid)); refusing to talk")
            throw VPNHostConnectionError.untrustedPeer
        }

        let framed = try SocketMessage.encode(request)
        try SocketMessage.write(framed, to: fd)
        let responseData = try SocketMessage.read(from: fd)
        return try SocketMessage.decode(responseData, as: VPNControlResponse.self)
    }

    /// True if the host agent is up and answering pings. Short timeout: a ping
    /// that doesn't come back promptly means the host is dead or wedged, and
    /// the caller's recovery path (kill + relaunch) shouldn't wait 10s to start.
    nonisolated static func ping() -> Bool {
        guard let response = try? send(VPNControlRequest(command: .ping), timeoutSeconds: 2) else { return false }
        return response.success
    }

    /// Ping and identify the running host build. nil when no host answers;
    /// `VPNHostInfoResponse` when a current host replies. A reply WITHOUT a
    /// payload is a pre-2026-07 host — reported as version "0" so callers
    /// treat it as stale.
    nonisolated static func hostInfo() -> VPNHostInfoResponse? {
        guard let response = try? send(VPNControlRequest(command: .ping), timeoutSeconds: 2),
              response.success else { return nil }
        guard let payload = response.payload,
              let info = try? JSONDecoder().decode(VPNHostInfoResponse.self, from: payload) else {
            return VPNHostInfoResponse(version: "0", bundlePath: "")
        }
        return info
    }
}

#endif
