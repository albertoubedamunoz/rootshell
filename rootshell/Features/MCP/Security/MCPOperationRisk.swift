//
//  MCPOperationRisk.swift
//  rootshell
//
//  Risk classification for MCP operations
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Risk level for MCP operations
enum MCPOperationRisk: String, Codable, Sendable, Comparable {
    /// Safe operations that don't modify state or access sensitive data
    /// Examples: listing resources, getting info
    case safe = "safe"

    /// Moderate risk operations that open connections but don't execute commands
    /// Examples: opening SSH sessions, subscribing to resources
    case moderate = "moderate"

    /// Dangerous operations that can execute arbitrary code or modify state
    /// Examples: executing SSH commands, writing files
    case dangerous = "dangerous"

    var displayName: String {
        switch self {
        case .safe: return String(localized: "Safe", comment: "MCP operation risk level: safe")
        case .moderate: return String(localized: "Moderate", comment: "MCP operation risk level: moderate")
        case .dangerous: return String(localized: "Dangerous", comment: "MCP operation risk level: dangerous")
        }
    }

    var description: String {
        switch self {
        case .safe:
            return String(localized: "Read-only operation that doesn't access sensitive data", comment: "MCP operation risk description: safe")
        case .moderate:
            return String(localized: "Opens connections or accesses potentially sensitive info", comment: "MCP operation risk description: moderate")
        case .dangerous:
            return String(localized: "Can execute code or modify system state", comment: "MCP operation risk description: dangerous")
        }
    }

    /// Color hint for UI
    var colorName: String {
        switch self {
        case .safe: return "green"
        case .moderate: return "yellow"
        case .dangerous: return "red"
        }
    }

    // Comparable implementation for risk ordering
    private var sortOrder: Int {
        switch self {
        case .safe: return 0
        case .moderate: return 1
        case .dangerous: return 2
        }
    }

    static func < (lhs: MCPOperationRisk, rhs: MCPOperationRisk) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

/// Classification of MCP methods and tools by risk level
enum MCPRiskClassification {
    /// Get the risk level for a protocol method
    static func riskFor(method: String) -> MCPOperationRisk {
        switch method {
        // Protocol methods (all safe - they're just queries)
        case "initialize":
            return .safe
        case "tools/list":
            return .safe
        case "resources/list":
            return .safe
        case "resources/read":
            return .safe
        case "prompts/list":
            return .safe
        case "prompts/get":
            return .safe

        // Tool calls are determined by the specific tool
        case "tools/call":
            // Actual risk is determined by the tool being called
            return .dangerous  // Default to dangerous, let tool override

        // Resource subscriptions
        case "resources/subscribe":
            return .moderate

        // Unknown methods default to dangerous
        default:
            return .dangerous
        }
    }

    /// Get the risk level for a specific tool
    static func riskFor(tool: String) -> MCPOperationRisk {
        switch tool {
        // SSH tools
        case "ssh_execute":
            return .dangerous  // Can run arbitrary commands
        case "ssh_list_hosts":
            return .safe  // Just listing known hosts
        case "ssh_get_host_info":
            return .safe  // Just reading host info
        case "ssh_open_session":
            return .moderate  // Opens connection but doesn't run commands

        // Cloud tools
        case "cloud_list_instances":
            return .safe
        case "cloud_get_instance":
            return .safe
        case "cloud_refresh":
            return .safe  // Just refreshes cached data

        // Kubernetes tools
        case "k8s_list_clusters":
            return .safe
        case "k8s_get_cluster":
            return .safe
        case "k8s_list_nodes":
            return .safe
        case "k8s_exec":
            return .dangerous  // Can run commands in pods

        // Unknown tools default to dangerous
        default:
            return .dangerous
        }
    }

    /// Check if an operation should be auto-approved in standard mode
    static func isAutoApprovable(tool: String) -> Bool {
        riskFor(tool: tool) == .safe
    }

    /// Check if an operation should be session-approvable in standard mode
    static func isSessionApprovable(tool: String) -> Bool {
        riskFor(tool: tool) <= .moderate
    }
}
