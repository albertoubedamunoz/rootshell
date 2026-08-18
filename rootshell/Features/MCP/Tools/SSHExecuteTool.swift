//
//  SSHExecuteTool.swift
//  rootshell
//
//  MCP tool for executing commands on remote SSH hosts
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Citadel
import NIOCore
import NIOSSH
import os.log

/// Tool for executing commands on remote SSH hosts
/// This is a DANGEROUS tool and requires explicit user approval
struct SSHExecuteTool: MCPTool {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHExecuteTool")

    static let name = "ssh_execute"
    static let description = """
        Execute a command on a remote SSH host. \
        The host parameter accepts: user@host, user@host:port, or hostname/IP from connection history. \
        If you have a cloud VM name, use cloud_list_instances first to get the IP and sshTarget.
        """

    static let inputSchema = MCPInputSchema(
        properties: [
            "host": .string(description: "SSH target: user@host, user@host:port, or hostname/IP from history. Cloud VM names won't work - look up the IP first."),
            "command": .string(description: "Command to execute on the remote host"),
            "timeout": .integer(description: "Timeout in seconds (default: 60, max: 300)")
        ],
        required: ["host", "command"]
    )

    static let operationRisk: MCPOperationRisk = .dangerous

    @MainActor
    func execute(params: MCPToolCallParams, session: MCPSession) async throws -> MCPToolResult {
        guard let hostSpec = params.stringArg("host"), !hostSpec.isEmpty else {
            throw MCPError.invalidParams("host parameter is required")
        }

        guard let command = params.stringArg("command"), !command.isEmpty else {
            throw MCPError.invalidParams("command parameter is required")
        }

        let timeout = min(max(params.intArg("timeout") ?? 60, 1), 300) // 1s...5 minutes

        Self.logger.info("Executing SSH command on \(hostSpec): \(command.prefix(50))...")

        // Resolve host from history or parse directly
        let sshConfig = try await resolveSSHConfig(hostSpec)

        // Execute the command
        let result: HeadlessSSHExecutor.CommandOutput
        do {
            result = try await HeadlessSSHExecutor.execute(
                config: sshConfig,
                command: command,
                timeout: timeout,
                logLabel: "[MCP]",
                buildTargetAuth: { try await self.buildAuthMethod(for: $0) },
                buildJumpAuth: { try await self.buildMCPAuthMethod(username: $0.username, authMethod: $0.authMethod) }
            )
        } catch let error as HeadlessSSHExecutor.ExecError {
            throw Self.mapExecError(error)
        }

        let exitCodeDescription = result.exitCode.map(String.init) ?? "unknown"
        let durationMs = result.durationMs
        Self.logger.info("Command completed with exit code \(exitCodeDescription) in \(durationMs)ms")

        // Return structured result. exitCode -1 means the command was
        // forcibly terminated (output cap exceeded) before reporting a
        // status — truncated is true in that case.
        return .json([
            "exitCode": result.exitCode ?? -1,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "durationMs": result.durationMs,
            "truncated": result.truncated
        ])
    }

    private static func mapExecError(_ error: HeadlessSSHExecutor.ExecError) -> MCPError {
        switch error {
        case .connectionFailed(let message):
            return MCPError.sshConnectionFailed(message)
        case .hostKeyUntrusted(let host, let port):
            return MCPError.sshConnectionFailed(
                "Host key for \(host):\(port) is not trusted (unknown or changed key). "
                + "Open a terminal session to this host once to verify and save its host key, then retry."
            )
        case .commandFailed(let message):
            return MCPError.sshCommandFailed(message)
        case .timedOut(let seconds):
            return MCPError.sshCommandFailed("Command timed out after \(seconds)s")
        }
    }

    // MARK: - Host Resolution

    /// Resolve a host specification to an SSHConfig
    @MainActor
    private func resolveSSHConfig(_ hostSpec: String) async throws -> SSHConfig {
        let historyManager = SSHConnectionHistoryManager.shared

        // First, try to find in history
        let matches = historyManager.getSuggestions(matching: hostSpec, mode: .substring)

        if let entry = matches.first {
            // Found in history - use stored config
            return buildSSHConfig(from: entry)
        }

        // Not in history - parse the host spec
        return try parseHostSpec(hostSpec)
    }

    /// Build SSHConfig from a history entry
    @MainActor
    private func buildSSHConfig(from entry: SSHConnectionHistoryEntry) -> SSHConfig {
        var config: SSHConfig

        // Set auth method based on entry type
        switch entry.authType {
        case .password, .savedPassword, .keyboardInteractive, .unknown:
            // We can't use password/interactive auth from MCP for security reasons
            // Try to find a default key instead
            if let defaultKey = SSHKeyManager.shared.savedKeys.first {
                config = SSHConfig(
                    host: entry.host,
                    port: entry.port,
                    username: entry.username,
                    keyID: defaultKey.id
                )
            } else {
                // No key available - create with password placeholder
                config = SSHConfig(
                    host: entry.host,
                    port: entry.port,
                    username: entry.username,
                    password: ""
                )
            }
        case .key(let keyID, _):
            config = SSHConfig(
                host: entry.host,
                port: entry.port,
                username: entry.username,
                keyID: keyID
            )
        case .none:
            config = SSHConfig(
                host: entry.host,
                port: entry.port,
                username: entry.username,
                authMethod: .none
            )
        }

        // Set jump host if present
        if entry.hasJumpHost,
           let jumpHost = entry.jumpHost,
           let jumpUsername = entry.jumpUsername {
            // Determine auth method for jump host
            let jumpAuthMethod: SSHConfig.AuthMethod
            if let jumpAuth = entry.jumpAuthType {
                switch jumpAuth {
                case .password, .savedPassword, .keyboardInteractive, .unknown:
                    // MCP can't drive interactive auth — try a default key instead
                    if let defaultKey = SSHKeyManager.shared.savedKeys.first {
                        jumpAuthMethod = .key(defaultKey.id)
                    } else {
                        jumpAuthMethod = .password("")
                    }
                case .key(let keyID, _):
                    jumpAuthMethod = .key(keyID)
                case .none:
                    jumpAuthMethod = .none
                }
            } else if let defaultKey = SSHKeyManager.shared.savedKeys.first {
                jumpAuthMethod = .key(defaultKey.id)
            } else {
                jumpAuthMethod = .password("")
            }

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if case .key(let keyID) = jumpAuthMethod {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            let jumpConfig = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: entry.jumpPort ?? 22,
                username: jumpUsername,
                authMethod: jumpAuthMethod,
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )

            config.jumpHost = jumpConfig
        }

        // Use cached IP for .local hostnames
        config.cachedIP = entry.cachedIP

        return config
    }

    /// Parse a host specification string into SSHConfig
    @MainActor
    private func parseHostSpec(_ hostSpec: String) throws -> SSHConfig {
        // Parse formats:
        // - user@host
        // - user@host:port
        // - host (assumes current user or "root")

        var username = "root"
        var host = hostSpec
        var port = 22

        // Check for user@host format — split on LAST @ so usernames containing @
        // (e.g. AD-style user@domain) survive host separation.
        if let atIndex = hostSpec.lastIndex(of: "@") {
            username = String(hostSpec[..<atIndex])
            host = String(hostSpec[hostSpec.index(after: atIndex)...])
        }

        // Check for host:port format
        if let colonIndex = host.lastIndex(of: ":"),
           let portNum = Int(host[host.index(after: colonIndex)...]) {
            port = portNum
            host = String(host[..<colonIndex])
        }

        guard !host.isEmpty else {
            throw MCPError.invalidParams("Invalid host specification: \(hostSpec)")
        }

        // Try to use a default key
        let keyManager = SSHKeyManager.shared
        if let defaultKey = keyManager.savedKeys.first {
            return SSHConfig(host: host, port: port, username: username, keyID: defaultKey.id)
        } else {
            // No keys available - this will fail on connect
            return SSHConfig(host: host, port: port, username: username, password: "")
        }
    }

    // MARK: - MCP Auth Policy

    /// Build authentication method for MCP connections.
    /// MCP-specific: falls back to default key when password is empty or savedPassword.
    @MainActor
    private func buildAuthMethod(for config: SSHConfig) async throws -> SSHAuthenticationMethod {
        switch config.authMethod {
        case .password(let password) where password.isEmpty:
            // No password - fall back to first available key
            return try await mcpFallbackToDefaultKey(username: config.username,
                error: "No SSH key available. Configure key-based authentication for this host.")

        case .savedPassword:
            // MCP can't use interactive prompts - fall back to first available key
            return try await mcpFallbackToDefaultKey(username: config.username,
                error: "Saved password auth requires interactive prompt. Configure key-based authentication for MCP access.")

        default:
            return try await SSHConnectionHelper.buildAuthMethod(for: config)
        }
    }

    /// Build auth method for MCP context (falls back to default key for empty passwords)
    @MainActor
    private func buildMCPAuthMethod(username: String, authMethod: SSHConfig.AuthMethod) async throws -> SSHAuthenticationMethod {
        switch authMethod {
        case .password(let password) where password.isEmpty:
            return try await mcpFallbackToDefaultKey(username: username,
                error: "No SSH key available for jump host")

        case .savedPassword:
            return try await mcpFallbackToDefaultKey(username: username,
                error: "Saved password auth requires interactive prompt. Configure key-based authentication for MCP access.")

        default:
            return try await SSHConnectionHelper.buildAuthMethod(username: username, authMethod: authMethod)
        }
    }

    /// MCP fallback: use first available saved key when password/savedPassword auth isn't possible
    @MainActor
    private func mcpFallbackToDefaultKey(username: String, error: String) async throws -> SSHAuthenticationMethod {
        guard let defaultKey = SSHKeyManager.shared.savedKeys.first else {
            throw MCPError.authenticationFailed(error)
        }
        return try await SSHConnectionHelper.buildAuthMethod(username: username, authMethod: .key(defaultKey.id))
    }
}
