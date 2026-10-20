//
//  RemotePortForwarder.swift
//  rootshell
//
//  Starts and stops the loopback forwards opened from the remote-port pill.
//  The forwards belong to the transport manager of the pane's connection
//  owner (the gateway for a tmux -CC or herdr pane), so they end with that
//  connection and their state is always read back from it.
//

import Foundation

nonisolated enum RemotePortForwardError: LocalizedError {
    case unsupportedTransport
    case noSession

    var errorDescription: String? {
        switch self {
        case .unsupportedTransport:
            return String(localized: "Port forwarding is unavailable for this connection.",
                          comment: "Remote ports: transport cannot forward")
        case .noSession:
            return String(localized: "The connection is not ready.",
                          comment: "Remote ports: no live session")
        }
    }
}

@MainActor
final class RemotePortForwarder {
    private weak var terminal: Ghostty.TerminalView?

    init(terminal: Ghostty.TerminalView) {
        self.terminal = terminal
    }

    private func forwarding(create: Bool) -> AdHocForwarding? {
        guard let terminal,
              let owner = TerminalConnectionOwner.resolve(for: terminal),
              let provider = owner.session as? AdHocForwardingProviding else { return nil }
        return provider.adHocForwarding(create: create)
    }

    /// nil once the transport dropped the forward, e.g. after a reconnect.
    func localPort(for remotePort: UInt16) -> UInt16? {
        forwarding(create: false)?.adHocForward(forRemotePort: remotePort)?.localPort
    }

    /// Returns the loopback port the page should use. Reuses an existing
    /// forward for the same remote port.
    func forward(_ port: RemotePort) async throws -> UInt16 {
        guard let terminal,
              let owner = TerminalConnectionOwner.resolve(for: terminal),
              owner.session != nil else { throw RemotePortForwardError.noSession }
        guard let forwarding = forwarding(create: true) else {
            throw RemotePortForwardError.unsupportedTransport
        }

        // Prefer the remote number locally so `localhost:9090` just works and
        // a reload keeps its address. Privileged ports are never preferred:
        // binding them is not what a mobile app should attempt.
        let preferred: UInt16? = port.number >= 1024 ? port.number : nil
        let handle = try await forwarding.startAdHocLocalForward(
            remoteHost: port.targetHost,
            remotePort: port.number,
            preferredLocalPort: preferred
        )
        return handle.localPort
    }

    func stop(remotePort: UInt16) async {
        guard let forwarding = forwarding(create: false),
              let handle = forwarding.adHocForward(forRemotePort: remotePort) else { return }
        await forwarding.stopAdHocLocalForward(handle)
    }
}
