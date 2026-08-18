//
//  SSHListHostsTool.swift
//  rootshell
//
//  MCP tool for listing SSH hosts from connection history
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Tool for listing available SSH hosts from connection history
struct SSHListHostsTool: MCPTool {
    static let name = "ssh_list_hosts"
    static let description = """
        List SSH hosts from connection history. Returns previously-used SSH connections, NOT cloud VM inventories. \
        If searching for a VM by its display name (e.g., 'my-web-server'), use cloud_list_instances first to get the IP address. \
        The 'host' field in results can be passed to ssh_get_host_info and ssh_execute.
        """

    static let inputSchema = MCPInputSchema(
        properties: [
            "filter": .string(description: "Search by hostname, IP address, or user@host format. Does NOT match cloud VM display names."),
            "limit": .integer(description: "Maximum number of results (default: 20)")
        ],
        required: nil
    )

    static let operationRisk: MCPOperationRisk = .safe

    @MainActor
    func execute(params: MCPToolCallParams, session: MCPSession) async throws -> MCPToolResult {
        let filter = params.stringArg("filter") ?? ""
        let limit = params.intArg("limit") ?? 20

        // Get history entries
        let historyManager = SSHConnectionHistoryManager.shared
        let entries: [SSHConnectionHistoryEntry]

        if filter.isEmpty {
            // Return most recent
            entries = Array(historyManager.entries.prefix(limit))
        } else {
            // Search with substring matching for filters
            entries = historyManager.getSuggestions(
                matching: filter,
                mode: filter.isEmpty ? .prefix : .substring
            )
        }

        // Convert to response format
        let hostList = entries.prefix(limit).map { entry -> [String: Any] in
            var host: [String: Any] = [
                "display": entry.displayString,
                "host": entry.host,
                "username": entry.username,
                "port": entry.port,
                "hasJumpHost": entry.hasJumpHost,
                "lastUsed": ISO8601DateFormatter().string(from: entry.lastUsed)
            ]

            // Include auth type info (without exposing keys)
            switch entry.authType {
            case .password:
                host["authMethod"] = "password"
            case .savedPassword:
                host["authMethod"] = "savedPassword"
            case .key:
                host["authMethod"] = "key"
            case .keyboardInteractive:
                host["authMethod"] = "keyboardInteractive"
            case .none:
                host["authMethod"] = "none"
            case .unknown(let rawType):
                host["authMethod"] = rawType
            }

            // Include jump host details if present
            if entry.hasJumpHost {
                host["jumpHost"] = entry.jumpHost
                host["jumpPort"] = entry.jumpPort ?? 22
                host["jumpUsername"] = entry.jumpUsername
            }

            // Include HSS shorthand if present
            if let shorthand = entry.hssShorthand {
                host["hssShorthand"] = shorthand
            }

            return host
        }

        return .json(["hosts": Array(hostList)])
    }
}
