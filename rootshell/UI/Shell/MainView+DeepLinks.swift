//
//  MainView+DeepLinks.swift
//  rootshell
//
//  SSH and Mosh URL deep-link handling for MainView.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

private extension SSHConfig {
    /// A copy carrying the history entry's TERM override.
    ///
    /// Deep links rebuild an `SSHConfig` from a history entry by hand, and the
    /// convenience initializers don't take `terminalType`, so without this an
    /// ssh:// or mosh:// link silently falls back to the global default even
    /// though the saved connection pins a TERM.
    func carryingTerminalType(from entry: SSHConnectionHistoryEntry) -> SSHConfig {
        var copy = self
        copy.terminalType = entry.terminalType
        return copy
    }
}

extension MainView {

    // MARK: - SSH URL Deep Link Handling
    
    /// Handle an incoming SSH URL (ssh://user@host:port)
    func handleSSHURL(_ components: SSHURLComponents) {
        // Look up connection history for matching host/username
        let historyManager = SSHConnectionHistoryManager.shared
        
        // Find matching history entry
        let matchingEntry = historyManager.entries.first { entry in
            entry.host == components.host &&
            (components.username == nil || entry.username == components.username)
        }
        
        if let entry = matchingEntry {
            // Found history match - check if we can connect directly (key auth)
            switch entry.authType {
            case .key(let keyID, _):
                // Key-based auth - connect directly
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .key(keyID)
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                // Build fallback keys for target
                let fallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }

                let config = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    keyID: keyID,
                    fallbackKeyIDs: fallbackIDs.isEmpty ? nil : fallbackIDs,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: entry.portForwardConfig ?? .none
                )
                createSSHTab(with: config.carryingTerminalType(from: entry))
                
            case .password:
                // Password auth - need to show connection sheet pre-filled
                // We can't store passwords, so user needs to enter it
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .password("")
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let prefillConfig = SSHConfig(
                    host: components.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    password: "",
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: entry.portForwardConfig ?? .none
                )
                reconnectConfig = prefillConfig.carryingTerminalType(from: entry)
                showConnectionSidebar = true

            case .savedPassword:
                // Saved password - try to load from keychain and connect
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .savedPassword
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let config = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .savedPassword,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: entry.portForwardConfig ?? .none
                )
                createSSHTab(with: config.carryingTerminalType(from: entry))

            case .none:
                // None auth (Tailscale/WireGuard) - connect directly
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .none
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let config = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .none,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: entry.portForwardConfig ?? .none
                )
                createSSHTab(with: config.carryingTerminalType(from: entry))

            case .keyboardInteractive:
                // Server-driven prompts (2FA/OTP/PAM) — connect directly; the
                // keyboard-interactive UI handles the challenge.
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .keyboardInteractive
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let config = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .keyboardInteractive,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: entry.portForwardConfig ?? .none
                )
                createSSHTab(with: config.carryingTerminalType(from: entry))

            case .unknown:
                // Auth method from a newer app version — prefill the sidebar so
                // the user can choose a supported method.
                let prefillConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    password: ""
                )
                reconnectConfig = prefillConfig.carryingTerminalType(from: entry)
                showConnectionSidebar = true
            }
        } else {
            // No history match - show connection sheet with URL components pre-filled
            let prefillConfig = SSHConfig(
                host: components.host,
                port: components.port,
                username: components.username ?? "",
                password: ""
            )
            reconnectConfig = prefillConfig
            showConnectionSidebar = true
        }
    }
    
    /// Convert SSHAuthType (from history) to SSHConfig.AuthMethod
    private func convertAuthType(_ authType: SSHAuthType?) -> SSHConfig.AuthMethod? {
        guard let authType = authType else { return nil }
        switch authType {
        case .password:
            return .password("")
        case .savedPassword:
            return .savedPassword
        case .key(let keyID, _):
            return .key(keyID)
        case .keyboardInteractive:
            return .keyboardInteractive
        case .none:
            return SSHConfig.AuthMethod.none
        case .unknown(let rawType):
            return .unknown(rawType: rawType)
        }
    }

    /// Build fallback key IDs for a jump host auth method
    private func buildJumpFallbackKeys(for authMethod: SSHConfig.AuthMethod) -> [UUID]? {
        guard case .key(let keyID) = authMethod else { return nil }
        let fallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
        return fallbackIDs.isEmpty ? nil : fallbackIDs
    }

    // MARK: - Mosh URL Deep Link Handling

    /// Handle an incoming Mosh URL (mosh://user@host:port)
    func handleMoshURL(_ components: MoshURLComponents) {
        // Reuse SSH connection history since Mosh uses SSH for server spawn
        let historyManager = SSHConnectionHistoryManager.shared

        // Find matching history entry
        let matchingEntry = historyManager.entries.first { entry in
            entry.host == components.host &&
            (components.username == nil || entry.username == components.username)
        }

        if let entry = matchingEntry {
            // Found history match - build SSH config for mosh-server spawn
            switch entry.authType {
            case .key(let keyID, _):
                // Key-based auth - connect directly via Mosh
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .key(keyID)
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                // Build fallback keys for target
                let fallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }

                let sshConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    keyID: keyID,
                    fallbackKeyIDs: fallbackIDs.isEmpty ? nil : fallbackIDs,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: .none  // Mosh handles its own transport
                )
                let moshConfig = MoshConfig(sshConfig: sshConfig.carryingTerminalType(from: entry))
                createMoshTab(with: moshConfig)

            case .password:
                // Password auth - need to show connection sheet pre-filled
                // For now, fall through to SSH connection sheet
                // TODO: Add Mosh-specific connection sheet option
                let prefillConfig = SSHConfig(
                    host: components.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    password: "",
                    cachedIP: entry.cachedIP
                )
                reconnectConfig = prefillConfig.carryingTerminalType(from: entry)
                showConnectionSidebar = true

            case .savedPassword:
                // Saved password - build config and connect via Mosh
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .savedPassword
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let sshConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .savedPassword,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: .none
                )
                let moshConfig = MoshConfig(sshConfig: sshConfig.carryingTerminalType(from: entry))
                createMoshTab(with: moshConfig)

            case .none:
                // None auth (Tailscale/WireGuard) - connect directly via Mosh
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .none
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let sshConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .none,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: .none
                )
                let moshConfig = MoshConfig(sshConfig: sshConfig.carryingTerminalType(from: entry))
                createMoshTab(with: moshConfig)

            case .keyboardInteractive:
                // Server-driven prompts — connect via Mosh; the keyboard-interactive
                // UI handles the challenge during the bootstrap SSH connection.
                let jumpConfig: SSHConfig.JumpHostConfig?
                if entry.hasJumpHost {
                    let jumpAuthMethod = convertAuthType(entry.jumpAuthType) ?? .keyboardInteractive
                    let jumpFallbackIDs = buildJumpFallbackKeys(for: jumpAuthMethod)
                    jumpConfig = SSHConfig.JumpHostConfig(
                        host: entry.jumpHost!,
                        port: entry.jumpPort ?? 22,
                        username: entry.jumpUsername ?? entry.username,
                        authMethod: jumpAuthMethod,
                        fallbackKeyIDs: jumpFallbackIDs
                    )
                } else {
                    jumpConfig = nil
                }

                let sshConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    authMethod: .keyboardInteractive,
                    cachedIP: entry.cachedIP,
                    jumpHost: jumpConfig,
                    hssShorthand: entry.hssShorthand,
                    cloudInstanceLabel: nil,
                    agentConfig: entry.agentConfig ?? .disabled,
                    portForwardConfig: .none
                )
                let moshConfig = MoshConfig(sshConfig: sshConfig.carryingTerminalType(from: entry))
                createMoshTab(with: moshConfig)

            case .unknown:
                // Auth method from a newer app version — prefill the sidebar.
                let prefillConfig = SSHConfig(
                    host: entry.host,
                    port: components.port,
                    username: components.username ?? entry.username,
                    password: ""
                )
                reconnectConfig = prefillConfig.carryingTerminalType(from: entry)
                showConnectionSidebar = true
            }
        } else {
            // No history match - show connection sheet with URL components pre-filled
            // For now, show SSH connection sheet - user can connect via SSH first
            // and then subsequent mosh:// URLs will use the saved credentials
            let prefillConfig = SSHConfig(
                host: components.host,
                port: components.port,
                username: components.username ?? "",
                password: ""
            )
            reconnectConfig = prefillConfig
            showConnectionSidebar = true
        }
    }
}
