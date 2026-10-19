//
//  AdHocForwarding.swift
//  rootshell
//
//  A forward started by the user from the remote-port status bar. It is not
//  part of the connection's saved PortForwardConfig: it exists only while the
//  status bar or its opened page keeps it, and is torn down with the session.
//

import Foundation

nonisolated struct AdHocForwardHandle: Hashable, Sendable {
    let id: UUID
    let remotePort: UInt16
    /// The loopback port the browser connects to. Usually the remote port,
    /// or an ephemeral one when that local port was taken.
    let localPort: UInt16
    /// False when the transport can only tear down its whole forwarder, so
    /// stopping one port while others stay open is impossible.
    let canStop: Bool

    init(id: UUID, remotePort: UInt16, localPort: UInt16, canStop: Bool = true) {
        self.id = id
        self.remotePort = remotePort
        self.localPort = localPort
        self.canStop = canStop
    }
}

/// Implemented by the transport-specific port-forward managers.
@MainActor
protocol AdHocForwarding: AnyObject {
    /// Binds a loopback listener and returns its actual port. `preferred`
    /// is tried first; when it is already in use the implementation may fall
    /// back to an ephemeral port.
    func startAdHocLocalForward(
        remoteHost: String,
        remotePort: UInt16,
        preferredLocalPort: UInt16?
    ) async throws -> AdHocForwardHandle

    func stopAdHocLocalForward(_ handle: AdHocForwardHandle) async
}

/// A session that can host a status-bar forward.
@MainActor
protocol AdHocForwardingProviding: AnyObject {
    var adHocForwarding: AdHocForwarding? { get }
}
