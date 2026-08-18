//
//  ConsoleConfig.swift
//  rootshell
//
//  Configuration and error types for cloud console sessions (LISH, etc.)
//

import Foundation

/// Configuration for a cloud console session
nonisolated struct ConsoleConfig: Codable, Equatable, Sendable {
    /// Unique session identifier
    let sessionId: UUID

    /// The cloud account to use
    let accountId: UUID

    /// Provider-specific instance ID (e.g., Linode ID "12345678")
    let providerInstanceId: String

    /// Provider identifier (e.g., "linode")
    let providerID: String

    /// Human-readable instance label
    let instanceLabel: String

    /// Created timestamp
    let createdAt: Date

    /// Display name for UI
    var displayName: String {
        "Console: \(instanceLabel)"
    }

    /// Short session ID for logging (first 8 chars)
    var shortSessionId: String {
        String(sessionId.uuidString.prefix(8)).lowercased()
    }

    init(
        sessionId: UUID = UUID(),
        accountId: UUID,
        providerInstanceId: String,
        providerID: String,
        instanceLabel: String,
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.accountId = accountId
        self.providerInstanceId = providerInstanceId
        self.providerID = providerID
        self.instanceLabel = instanceLabel
        self.createdAt = createdAt
    }

    /// Creates a new config with the same instance but a fresh session ID.
    /// Used when splitting a console terminal to create a new independent session.
    func withNewSession() -> ConsoleConfig {
        ConsoleConfig(
            sessionId: UUID(),
            accountId: accountId,
            providerInstanceId: providerInstanceId,
            providerID: providerID,
            instanceLabel: instanceLabel,
            createdAt: Date()
        )
    }
}

/// Errors specific to console session operations
enum ConsoleError: LocalizedError, Equatable {
    /// Cloud account not found
    case accountNotFound

    /// Credentials not found in Keychain
    case credentialsNotFound

    /// Instance not found
    case instanceNotFound(String)

    /// Instance is offline
    case instanceOffline(String)

    /// Failed to request console token
    case tokenRequestFailed(String)

    /// Failed to connect WebSocket
    case connectionFailed(String)

    /// WebSocket connection closed
    case connectionClosed(String?)

    /// Authentication failed
    case authenticationFailed(String)

    /// Network error
    case networkError(String)

    /// Provider does not support console
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return String(localized: "Cloud account not found", comment: "Cloud console error")
        case .credentialsNotFound:
            return String(localized: "Credentials not found in Keychain", comment: "Cloud console error")
        case .instanceNotFound(let id):
            return String(localized: "Instance '\(id)' not found", comment: "Cloud console error")
        case .instanceOffline(let label):
            return String(localized: "Instance '\(label)' is offline", comment: "Cloud console error")
        case .tokenRequestFailed(let detail):
            return String(localized: "Failed to get console access: \(detail)", comment: "Cloud console error")
        case .connectionFailed(let detail):
            return String(localized: "Failed to connect: \(detail)", comment: "Cloud console error")
        case .connectionClosed(let reason):
            if let reason = reason {
                return String(localized: "Connection closed: \(reason)", comment: "Cloud console error")
            }
            return String(localized: "Connection closed unexpectedly", comment: "Cloud console error")
        case .authenticationFailed(let detail):
            return String(localized: "Authentication failed: \(detail)", comment: "Cloud console error")
        case .networkError(let detail):
            return String(localized: "Network error: \(detail)", comment: "Cloud console error")
        case .unsupportedProvider(let provider):
            return String(localized: "Console not supported for provider: \(provider)", comment: "Cloud console error")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accountNotFound, .credentialsNotFound:
            return String(localized: "Re-authenticate with your cloud provider in Settings", comment: "Cloud console recovery suggestion")
        case .instanceOffline:
            return String(localized: "Start the instance before connecting to console", comment: "Cloud console recovery suggestion")
        case .tokenRequestFailed:
            return String(localized: "Check your internet connection and try again", comment: "Cloud console recovery suggestion")
        case .unsupportedProvider:
            return String(localized: "This cloud provider does not support out-of-band console access", comment: "Cloud console recovery suggestion")
        default:
            return nil
        }
    }
}

/// State machine for console session lifecycle
enum ConsoleState: Equatable, Sendable {
    /// Initial state before starting
    case initial

    /// Fetching console access token from provider API
    case fetchingToken

    /// Connecting WebSocket
    case connecting

    /// Session is running and ready for input
    case running

    /// Session disconnected, may reconnect
    case disconnected(reason: DisconnectReason)

    /// Session terminated (cannot restart)
    case terminated

    /// Session failed with error
    case failed(ConsoleError)

    /// Reasons for disconnection
    enum DisconnectReason: Equatable, Sendable {
        case userClosed
        case sessionEnded
        case sessionExpired
        case connectionLost
    }

    /// Human-readable description for UI
    var statusDescription: String {
        switch self {
        case .initial:
            return String(localized: "Ready to connect", comment: "Cloud console status")
        case .fetchingToken:
            return String(localized: "Requesting console access...", comment: "Cloud console status")
        case .connecting:
            return String(localized: "Connecting...", comment: "Cloud console status")
        case .running:
            return String(localized: "Connected", comment: "Cloud console status")
        case .disconnected(let reason):
            switch reason {
            case .userClosed:
                return String(localized: "Disconnected", comment: "Cloud console status")
            case .sessionEnded:
                return String(localized: "Session ended", comment: "Cloud console status")
            case .sessionExpired:
                return String(localized: "Session expired", comment: "Cloud console status")
            case .connectionLost:
                return String(localized: "Connection lost", comment: "Cloud console status")
            }
        case .terminated:
            return String(localized: "Terminated", comment: "Cloud console status")
        case .failed(let error):
            return error.localizedDescription
        }
    }

    /// Whether the session can be restarted
    var canRestart: Bool {
        switch self {
        case .disconnected, .failed, .terminated:
            return true
        default:
            return false
        }
    }

    /// Whether the session is in a terminal state
    var isTerminal: Bool {
        switch self {
        case .terminated, .failed:
            return true
        default:
            return false
        }
    }

    /// Color style for spinner animation based on current state
    var spinnerColorStyle: SpinnerAnimator.ColorStyle {
        switch self {
        case .fetchingToken, .connecting:
            return .connecting
        case .running:
            return .success
        case .failed:
            return .error
        default:
            return .connecting
        }
    }

    /// Joke category for console connections
    var jokeCategory: ConnectionJokeCategory {
        return .general
    }
}
