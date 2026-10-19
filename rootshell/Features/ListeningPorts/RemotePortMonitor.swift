//
//  RemotePortMonitor.swift
//  rootshell
//
//  Polls the host behind one pane for its listening TCP ports. One probe at a
//  time, only while the pane is visible and the app is in the foreground.
//

import Foundation
import os

@MainActor
final class RemotePortMonitor {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RemotePortMonitor")

    private weak var terminal: Ghostty.TerminalView?
    private var task: Task<Void, Never>?
    private var visible = true
    private var consecutiveFailures = 0

    /// Ports open and close at human pace; the probe is a cheap `ss`/`lsof`.
    private let interval: Duration = .seconds(5)
    /// A failed host is retried less often so a dead link does not spin.
    private let retryInterval: Duration = .seconds(20)

    init(terminal: Ghostty.TerminalView) {
        self.terminal = terminal
    }

    func start() {
        guard task == nil else { return }
        consecutiveFailures = 0
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIfNeeded()
                let delay = (self?.consecutiveFailures ?? 0) == 0
                    ? (self?.interval ?? .seconds(5))
                    : (self?.retryInterval ?? .seconds(20))
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        consecutiveFailures = 0
        terminal?.remotePorts = []
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
    }

    private func refreshIfNeeded() async {
        guard visible, !Ghostty.isAppBackgroundedAtomic, let terminal else { return }
        guard SettingsStore.shared.value(Settings.Terminal.showRemotePorts) else {
            if !terminal.remotePorts.isEmpty { terminal.remotePorts = [] }
            return
        }
        // A tmux -CC or herdr pane rides its gateway's connection.
        guard let owner = TerminalConnectionOwner.resolve(for: terminal) else {
            if !terminal.remotePorts.isEmpty { terminal.remotePorts = [] }
            return
        }
        guard owner.connectionConfig.underlyingSSHConfig != nil,
              owner.session != nil,
              RemoteExecProbe.canProbe(owner)
        else { return }

        let (command, nonce) = RemotePortScanCommand.command(
            pathPrefix: SSHConfig.remoteExecPathPrefix
        )
        do {
            let output = try await RemoteExecProbe.run(
                command,
                on: owner,
                timeout: 6,
                maxResponseBytes: 128 * 1024
            )
            let result = RemotePortScanParser.parse(output, nonce: nonce)
            consecutiveFailures = 0
            if terminal.remotePorts != result.ports {
                terminal.remotePorts = result.ports
            }
        } catch RemoteExecProbe.ProbeError.busy {
            // The tssh transport allows one probe at a time; another feature
            // owns the slot. Not a failure, just wait for the next tick.
        } catch {
            consecutiveFailures += 1
            Self.logger.debug("Remote port scan failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
