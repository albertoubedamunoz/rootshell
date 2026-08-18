//
//  SSHGetHostInfoTool.swift
//  rootshell
//
//  MCP tool for getting detailed info about an SSH host
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Tool for getting detailed information about an SSH host from history
struct SSHGetHostInfoTool: MCPTool {
    static let name = "ssh_get_host_info"
    static let description = """
        Get detailed SSH connection info for a host from history. \
        The host parameter must match a hostname, IP, or user@host from previous connections. \
        Cloud VM names won't match - use cloud_list_instances first to get the IP address.
        """

    static let inputSchema = MCPInputSchema(
        properties: [
            "host": .string(description: "Hostname, IP address, or user@host to look up. Must match a previous connection - cloud VM display names are not supported.")
        ],
        required: ["host"]
    )

    static let operationRisk: MCPOperationRisk = .safe

    @MainActor
    func execute(params: MCPToolCallParams, session: MCPSession) async throws -> MCPToolResult {
        guard let hostQuery = params.stringArg("host"), !hostQuery.isEmpty else {
            throw MCPError.invalidParams("host parameter is required")
        }

        // Search for matching entries
        let historyManager = SSHConnectionHistoryManager.shared
        let matches = historyManager.getSuggestions(matching: hostQuery, mode: .substring)

        // Find best match
        guard let entry = matches.first else {
            throw MCPError.sshHostNotFound(hostQuery)
        }

        // Build detailed response
        var info: [String: Any] = [
            "host": entry.host,
            "username": entry.username,
            "port": entry.port,
            "displayName": entry.displayString,
            "lastUsed": ISO8601DateFormatter().string(from: entry.lastUsed),
            "hasJumpHost": entry.hasJumpHost
        ]

        // Auth method (without exposing actual keys/passwords)
        switch entry.authType {
        case .password:
            info["authMethod"] = "password"
        case .savedPassword:
            info["authMethod"] = "savedPassword"
        case .key(let keyID, _):
            info["authMethod"] = "key"
            // Try to get key name without exposing sensitive info
            if let keyName = await getKeyName(keyID: keyID) {
                info["keyName"] = keyName
            }
        case .keyboardInteractive:
            info["authMethod"] = "keyboardInteractive"
        case .none:
            info["authMethod"] = "none"
        case .unknown(let rawType):
            info["authMethod"] = rawType
        }

        // Jump host details
        if entry.hasJumpHost {
            var jumpInfo: [String: Any] = [
                "host": entry.jumpHost ?? "",
                "port": entry.jumpPort ?? 22,
                "username": entry.jumpUsername ?? ""
            ]

            if let jumpAuth = entry.jumpAuthType {
                switch jumpAuth {
                case .password:
                    jumpInfo["authMethod"] = "password"
                case .savedPassword:
                    jumpInfo["authMethod"] = "savedPassword"
                case .key:
                    jumpInfo["authMethod"] = "key"
                case .keyboardInteractive:
                    jumpInfo["authMethod"] = "keyboardInteractive"
                case .none:
                    jumpInfo["authMethod"] = "none"
                case .unknown(let rawType):
                    jumpInfo["authMethod"] = rawType
                }
            }

            info["jumpHost"] = jumpInfo
        }

        // Cached IP for .local hostnames
        if let cachedIP = entry.cachedIP {
            info["cachedIP"] = cachedIP
        }

        // HSS shorthand
        if let shorthand = entry.hssShorthand {
            info["hssShorthand"] = shorthand
        }

        // Agent forwarding status
        if let agentConfig = entry.agentConfig {
            info["agentForwardingEnabled"] = agentConfig.enabled
        }

        // Port forwarding status
        if let portConfig = entry.portForwardConfig, !portConfig.forwards.isEmpty {
            info["portForwardingEnabled"] = true
            info["portForwardCount"] = portConfig.forwards.count
        }

        return .json(info)
    }

    /// Get the name of an SSH key by its ID (without exposing the key itself)
    @MainActor
    private func getKeyName(keyID: UUID) async -> String? {
        // Access the key manager to get the key name
        // This should be safe as we're not exposing the actual key
        let keyManager = SSHKeyManager.shared
        return keyManager.savedKeys.first { $0.id == keyID }?.name
    }
}
