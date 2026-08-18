//
//  SSHAgentConfig.swift
//  rootshell
//
//  Configuration for SSH agent forwarding per connection
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Configuration for SSH agent forwarding on a specific connection
nonisolated struct SSHAgentConfig: Codable, Hashable, Sendable {
    /// Approval mode for agent forwarding requests
    nonisolated enum ApprovalMode: String, Codable, CaseIterable, Sendable {
        /// Automatically approve all forwarding requests
        case autoApprove = "auto"
        /// Approve all requests for this session (until disconnection)
        case sessionApprove = "session"
        /// Prompt for each individual request
        case perRequest = "prompt"

        var displayName: String {
            switch self {
            case .autoApprove: return String(localized: "Auto-approve", comment: "SSH agent approval: auto-approve")
            case .sessionApprove: return String(localized: "Session", comment: "SSH agent approval: session")
            case .perRequest: return String(localized: "Ask each time", comment: "SSH agent approval: ask each time")
            }
        }

        var description: String {
            switch self {
            case .autoApprove:
                return String(localized: "Automatically approve all signing requests", comment: "SSH agent approval description: auto-approve")
            case .sessionApprove:
                return String(localized: "Approve requests until disconnection", comment: "SSH agent approval description: session")
            case .perRequest:
                return String(localized: "Prompt for approval on each request", comment: "SSH agent approval description: per request")
            }
        }
    }

    /// Whether agent forwarding is enabled for this connection
    var enabled: Bool

    /// The approval mode for signing requests
    var approvalMode: ApprovalMode

    /// IDs of keys to forward (empty means none)
    var forwardedKeyIDs: Set<UUID>

    /// Default configuration with agent forwarding disabled
    static let disabled = SSHAgentConfig(
        enabled: false,
        approvalMode: .perRequest,
        forwardedKeyIDs: []
    )

    /// Create a configuration with all available keys forwarded
    static func withAllKeys(mode: ApprovalMode) -> SSHAgentConfig {
        SSHAgentConfig(
            enabled: true,
            approvalMode: mode,
            forwardedKeyIDs: []  // Empty means "all available keys"
        )
    }
}

/// Represents a pending agent signing request awaiting user approval
struct SSHAgentApprovalRequest: Identifiable, Sendable {
    let id = UUID()

    /// The name of the key being requested for signing
    let keyName: String

    /// The fingerprint of the key
    let fingerprint: String

    /// The remote host making the request
    let remoteHost: String?

    /// Human-readable session name (e.g., "user@host via jumphost")
    let sessionName: String

    /// Completion handler to call with the result
    let completion: @Sendable (Bool) -> Void

    /// Time the request was created (for timeout display)
    let timestamp = Date()
}
