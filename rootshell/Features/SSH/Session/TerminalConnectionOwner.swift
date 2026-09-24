//
//  TerminalConnectionOwner.swift
//  rootshell
//

import Foundation

/// Which pane holds the connection a pane's shell actually runs on.
@MainActor
enum TerminalConnectionOwner {
    /// A tmux -CC or herdr pane rides its gateway's session; every other pane
    /// owns its own. nil when the gateway is gone.
    static func resolve(for terminal: Ghostty.TerminalView) -> Ghostty.TerminalView? {
        if let herdr = terminal.herdrPaneBinding {
            // A herdr pane's surface is local; its host is the gateway's.
            return HerdrController.controller(forGateway: herdr.gatewayUUID)?.gateway
        }
        guard let binding = terminal.tmuxPaneBinding else { return terminal }
        for model in TmuxWindowRegistry.allTabsModels() {
            for tab in model.tabs {
                for candidate in tab.splitTree.terminalLeaves where candidate.uuid == binding.parentUUID {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `user@host:port` for a remote owner, `local` otherwise.
    static func targetKey(for owner: Ghostty.TerminalView) -> String {
        targetKey(for: owner.connectionConfig)
    }

    static func targetKey(for config: ConnectionConfig) -> String {
        guard let ssh = config.underlyingSSHConfig else { return TerminalTargetKey.local }
        return TerminalTargetKey.remote(username: ssh.username, host: ssh.host, port: ssh.port)
    }
}
