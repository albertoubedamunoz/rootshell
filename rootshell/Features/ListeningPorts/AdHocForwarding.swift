//
//  AdHocForwarding.swift
//  rootshell
//
//  A forward started by the user from the remote-port status bar. It is not
//  part of the connection's saved PortForwardConfig: it belongs to the
//  connection's transport manager and is torn down with the connection.
//

import Darwin
import Foundation

nonisolated struct AdHocForwardHandle: Hashable, Sendable {
    let id: UUID
    let remotePort: UInt16
    /// The loopback port the browser connects to. Usually the remote port,
    /// or an ephemeral one when that local port was taken.
    let localPort: UInt16
}

/// Implemented by the transport-specific port-forward managers.
@MainActor
protocol AdHocForwarding: AnyObject {
    /// Binds a loopback listener and returns its actual port. `preferred`
    /// is tried first; when it is already in use the implementation falls
    /// back to an ephemeral port.
    func startAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle

    func stopAdHocLocalForward(_ handle: AdHocForwardHandle) async

    /// The live forward for `remotePort`, nil once the transport dropped it.
    func adHocForward(forRemotePort remotePort: UInt16) -> AdHocForwardHandle?
}

/// A session that can host a status-bar forward.
@MainActor
protocol AdHocForwardingProviding: AnyObject {
    /// `create: false` never builds a manager, so lookups and stops cannot
    /// spawn one that owns nothing.
    func adHocForwarding(create: Bool) -> AdHocForwarding?
}

nonisolated enum LoopbackPort {
    /// True when nothing listens on `port` on either loopback family.
    /// Binds without SO_REUSEADDR, which would let a 127.0.0.1 bind shadow
    /// a local server listening on the wildcard address.
    static func isFree(_ port: UInt16) -> Bool {
        canBind(family: AF_INET, port: port) && canBind(family: AF_INET6, port: port)
    }

    /// Only EADDRINUSE counts as taken: a family the device lacks cannot
    /// conflict with anything.
    private static func canBind(family: Int32, port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 || errno != EADDRINUSE
                }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 || errno != EADDRINUSE
            }
        }
    }
}
