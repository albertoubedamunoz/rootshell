//
//  TerminalRestorationReconnector.swift
//  rootshell
//
//  Restoration-time reconnection, extracted from MainViewPersistence:
//  drives RestorationState / startRestoredSession for terminals rebuilt
//  from persisted window state (before a session controller exists).
//
//  Counterpart to TerminalReconnectionController, which is the per-session
//  LIVE auto-reconnect driver (countdown timer, inline overlay animators)
//  for mid-session disconnects. The two flows hand off via
//  isLiveDisconnectionOverlay / restorationState and are deliberately kept
//  separate.
//

import SwiftUI
import os

/// Stateless entry points for reconnecting restored terminals. MainActor by
/// the project's default isolation (mutates TerminalView view-model state).
enum TerminalRestorationReconnector {

    /// Initiate reconnection for a restored terminal
    static func initiateReconnection(_ terminalView: Ghostty.TerminalView) {
        ResumeDebugLogger.shared.log("initiateReconnection: uuid=\(terminalView.uuid.uuidString.prefix(8)), config=\(terminalView.connectionConfig.displayName)")
        let config = terminalView.connectionConfig

        // Check if password is needed for SSH
        if case .ssh(var sshConfig) = config {
            let ready = fillSavedPasswords(&sshConfig)
            terminalView.connectionConfig = .ssh(sshConfig)
            if !ready {
                terminalView.restorationState = .needsPassword(sshConfig)
                return
            }
        }

        // Can auto-reconnect (key auth or local/k8s/console)
        performReconnection(terminalView)
    }

    /// Swaps empty passwords for Keychain ones, jump hops first then the target
    /// (the overlay's prompt order). False when one still needs typing; the
    /// config keeps whatever was filled so far.
    static func fillSavedPasswords(_ sshConfig: inout SSHConfig) -> Bool {
        var chain = sshConfig.jumpChain
        defer { sshConfig.jumpChain = chain }
        for index in chain.indices {
            guard case .password(let pwd) = chain[index].authMethod, pwd.isEmpty else { continue }
            guard SSHPasswordManager.shared.hasPassword(host: chain[index].host, port: chain[index].port,
                                                        username: chain[index].username) else { return false }
            chain[index].authMethod = .savedPassword
        }
        if case .password(let pwd) = sshConfig.authMethod, pwd.isEmpty {
            guard SSHPasswordManager.shared.hasPassword(host: sshConfig.host, port: sshConfig.port,
                                                        username: sshConfig.username) else { return false }
            sshConfig.authMethod = .savedPassword
        }
        return true
    }

    /// Perform the actual reconnection
    static func performReconnection(_ terminalView: Ghostty.TerminalView) {
        ResumeDebugLogger.shared.log("performReconnection START: uuid=\(terminalView.uuid.uuidString.prefix(8))")
        terminalView.restorationState = Ghostty.TerminalView.RestorationState.connectingFromRestore

        // Start the restored session
        terminalView.startRestoredSession { result in
            switch result {
            case .success:
                ResumeDebugLogger.shared.log("performReconnection SUCCESS: uuid=\(terminalView.uuid.uuidString.prefix(8))")
                terminalView.restorationState = Ghostty.TerminalView.RestorationState.none
            case .failure(let error):
                ResumeDebugLogger.shared.log("performReconnection FAILED: uuid=\(terminalView.uuid.uuidString.prefix(8)), error=\(error.localizedDescription)")
                Ghostty.logger.error("Reconnection failed: \(error.localizedDescription)")
                terminalView.restorationState = Ghostty.TerminalView.RestorationState.failed(error.localizedDescription)
            }
        }
    }

    /// Handle password entry for a restored SSH session
    static func handlePasswordEntry(for terminalView: Ghostty.TerminalView, password: String) {
        guard case .ssh(var sshConfig) = terminalView.connectionConfig else { return }

        // The prompt's config carries the preflight's saved-password fills.
        if case .needsPassword(let config) = terminalView.restorationState {
            sshConfig = config
            // Same order as the overlay: the first jump host without one, else the target
            var chain = sshConfig.jumpChain
            if let index = chain.firstIndex(where: { if case .password(let pwd) = $0.authMethod { return pwd.isEmpty }; return false }) {
                chain[index].authMethod = .password(password)
                sshConfig.jumpChain = chain
            } else if case .password = sshConfig.authMethod {
                sshConfig.authMethod = .password(password)
            }
        }

        terminalView.connectionConfig = .ssh(sshConfig)
        // Re-run the checks: a later hop or the target may still need a password.
        initiateReconnection(terminalView)
    }

    /// Retry reconnection for a failed terminal
    static func retryReconnection(for terminalView: Ghostty.TerminalView) {
        initiateReconnection(terminalView)
    }
}
