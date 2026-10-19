//
//  RemotePortForwarder.swift
//  rootshell
//
//  Owns the loopback forwards started by the remote-port pill. One forward per
//  remote port, kept for as long as the pane lives; stopping is explicit or
//  happens with the session.
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
    private var handles: [UInt16: AdHocForwardHandle] = [:]

    init(terminal: Ghostty.TerminalView) {
        self.terminal = terminal
    }

    func localPort(for remotePort: UInt16) -> UInt16? {
        handles[remotePort]?.localPort
    }

    func canStop(remotePort: UInt16) -> Bool {
        handles[remotePort]?.canStop ?? false
    }

    /// Returns the loopback port the page should use. Reuses an existing
    /// forward for the same remote port.
    func forward(_ port: RemotePort) async throws -> UInt16 {
        if let handle = handles[port.number] {
            return handle.localPort
        }
        guard let terminal else { throw RemotePortForwardError.noSession }
        guard let session = terminal.session else { throw RemotePortForwardError.noSession }
        guard let provider = session as? AdHocForwardingProviding,
              let forwarding = provider.adHocForwarding else {
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
        handles[port.number] = handle
        return handle.localPort
    }

    func stop(remotePort: UInt16) async {
        guard let handle = handles.removeValue(forKey: remotePort) else { return }
        guard let session = terminal?.session,
              let provider = session as? AdHocForwardingProviding,
              let forwarding = provider.adHocForwarding else { return }
        await forwarding.stopAdHocLocalForward(handle)
    }

    func stopAll() async {
        let live = handles
        handles.removeAll()
        guard let session = terminal?.session,
              let provider = session as? AdHocForwardingProviding,
              let forwarding = provider.adHocForwarding else { return }
        for handle in live.values {
            await forwarding.stopAdHocLocalForward(handle)
        }
    }
}
