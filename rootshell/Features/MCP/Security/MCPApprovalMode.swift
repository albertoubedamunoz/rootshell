//
//  MCPApprovalMode.swift
//  rootshell
//
//  Approval mode configuration for MCP operations
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Approval mode for individual MCP operations
/// Matches the pattern from SSHAgentConfig.ApprovalMode
enum MCPApprovalMode: String, Codable, CaseIterable, Sendable {
    /// Automatically approve all requests
    case autoApprove = "auto"

    /// Approve all requests for this session (until disconnection)
    case sessionApprove = "session"

    /// Prompt for each individual request
    case perRequest = "prompt"

    var displayName: String {
        switch self {
        case .autoApprove: return String(localized: "Auto-approve", comment: "MCP approval mode: automatically approve")
        case .sessionApprove: return String(localized: "Session", comment: "MCP approval mode: approve for session")
        case .perRequest: return String(localized: "Ask each time", comment: "MCP approval mode: ask for each request")
        }
    }

    var description: String {
        switch self {
        case .autoApprove:
            return String(localized: "Automatically approve all requests", comment: "MCP approval mode description: auto-approve")
        case .sessionApprove:
            return String(localized: "Approve requests until disconnection", comment: "MCP approval mode description: session approve")
        case .perRequest:
            return String(localized: "Prompt for approval on each request", comment: "MCP approval mode description: per-request")
        }
    }
}

/// Session-level security mode that determines how operations are approved
enum MCPSessionMode: String, Codable, CaseIterable, Sendable {
    /// Standard mode: safe operations auto-approve, dangerous require perRequest
    case standard = "standard"

    /// Cautious mode: all operations require perRequest approval
    case cautious = "cautious"

    /// YOLO mode: all operations auto-approve (dangerous!)
    case yolo = "yolo"

    var displayName: String {
        switch self {
        case .standard: return String(localized: "Standard", comment: "MCP session mode: standard security")
        case .cautious: return String(localized: "Cautious", comment: "MCP session mode: cautious security")
        case .yolo: return String(localized: "YOLO", comment: "MCP session mode: no restrictions")
        }
    }

    var description: String {
        switch self {
        case .standard:
            return String(localized: "Safe operations auto-approve, commands require approval", comment: "MCP session mode description: standard")
        case .cautious:
            return String(localized: "All operations require explicit approval", comment: "MCP session mode description: cautious")
        case .yolo:
            return String(localized: "All operations auto-approve (not recommended)", comment: "MCP session mode description: YOLO")
        }
    }

    /// Warning shown when selecting this mode
    var warning: String? {
        switch self {
        case .yolo:
            return String(localized: "YOLO mode allows AI tools to execute commands without approval. This is dangerous and should only be used in controlled environments.", comment: "MCP session mode warning: YOLO mode danger warning")
        default:
            return nil
        }
    }

    /// Determine the approval mode for an operation based on session mode and risk level
    func approvalModeFor(risk: MCPOperationRisk) -> MCPApprovalMode {
        switch self {
        case .standard:
            switch risk {
            case .safe:
                return .autoApprove
            case .moderate:
                return .sessionApprove
            case .dangerous:
                return .perRequest
            }
        case .cautious:
            return .perRequest
        case .yolo:
            return .autoApprove
        }
    }
}

/// Persisted MCP server configuration
struct MCPServerConfig: Codable, Sendable {
    /// Whether the MCP server is enabled
    var isEnabled: Bool

    /// The session mode to use for new connections
    var sessionMode: MCPSessionMode

    /// Port to bind to (0 = auto-assign)
    var port: Int

    /// Timeout for approval requests (seconds)
    var approvalTimeout: TimeInterval

    static let `default` = MCPServerConfig(
        isEnabled: false,
        sessionMode: .standard,
        port: 0,
        approvalTimeout: 30
    )

    // MARK: - Persistence

    private static let key = "mcp_server_config"

    static func load() -> MCPServerConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let config = try? JSONDecoder().decode(MCPServerConfig.self, from: data) else {
            return .default
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
