//
//  EC2ConsoleConfig.swift
//  rootshell
//
//  Configuration for EC2 Serial Console sessions.
//

import Foundation

/// Configuration for an EC2 Serial Console session
nonisolated struct EC2ConsoleConfig: Codable, Equatable, Sendable {
    /// Unique session identifier
    let sessionId: UUID

    /// The cloud account to use
    let accountId: UUID

    /// EC2 instance ID (e.g., "i-0123456789abcdef0")
    let instanceId: String

    /// AWS region (e.g., "us-east-1")
    let region: String

    /// Human-readable instance label
    let instanceLabel: String

    /// Serial port number (0 for most instances)
    let serialPort: Int

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

    /// SSH host for EC2 Serial Console
    var sshHost: String {
        "serial-console.ec2-instance-connect.\(region).aws"
    }

    /// SSH username for EC2 Serial Console
    var sshUsername: String {
        "\(instanceId).port\(serialPort)"
    }

    init(
        sessionId: UUID = UUID(),
        accountId: UUID,
        instanceId: String,
        region: String,
        instanceLabel: String,
        serialPort: Int = 0,
        createdAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.accountId = accountId
        self.instanceId = instanceId
        self.region = region
        self.instanceLabel = instanceLabel
        self.serialPort = serialPort
        self.createdAt = createdAt
    }

    /// Creates a new config with the same instance but a fresh session ID.
    /// Used when splitting a console terminal to create a new independent session.
    func withNewSession() -> EC2ConsoleConfig {
        EC2ConsoleConfig(
            sessionId: UUID(),
            accountId: accountId,
            instanceId: instanceId,
            region: region,
            instanceLabel: instanceLabel,
            serialPort: serialPort,
            createdAt: Date()
        )
    }
}

/// State machine for EC2 console session lifecycle
enum EC2ConsoleState: Equatable, Sendable {
    /// Initial state before starting
    case initial

    /// Generating ephemeral SSH key pair
    case generatingKey

    /// Uploading public key to AWS
    case uploadingKey

    /// Connecting via SSH
    case connectingSSH

    /// SSH authentication in progress
    case authenticating

    /// Session is running and ready for input
    case running

    /// Session disconnected, may reconnect
    case disconnected(reason: DisconnectReason)

    /// Session terminated (cannot restart)
    case terminated

    /// Session failed with error
    case failed(EC2ConsoleError)

    /// Reasons for disconnection
    enum DisconnectReason: Equatable, Sendable {
        case userClosed
        case sessionEnded
        case keyExpired
        case connectionLost
    }

    /// Human-readable description for UI
    var statusDescription: String {
        switch self {
        case .initial:
            return String(localized: "Ready to connect", comment: "EC2 console status")
        case .generatingKey:
            return String(localized: "Generating SSH key...", comment: "EC2 console status")
        case .uploadingKey:
            return String(localized: "Authorizing console access...", comment: "EC2 console status")
        case .connectingSSH:
            return String(localized: "Connecting to serial console...", comment: "EC2 console status")
        case .authenticating:
            return String(localized: "Authenticating...", comment: "EC2 console status")
        case .running:
            return String(localized: "Connected", comment: "EC2 console status")
        case .disconnected(let reason):
            switch reason {
            case .userClosed:
                return String(localized: "Disconnected", comment: "EC2 console status")
            case .sessionEnded:
                return String(localized: "Session ended", comment: "EC2 console status")
            case .keyExpired:
                return String(localized: "Key expired", comment: "EC2 console status")
            case .connectionLost:
                return String(localized: "Connection lost", comment: "EC2 console status")
            }
        case .terminated:
            return String(localized: "Terminated", comment: "EC2 console status")
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
        case .generatingKey, .uploadingKey, .connectingSSH, .authenticating:
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

/// Errors specific to EC2 Serial Console operations
enum EC2ConsoleError: LocalizedError, Equatable {
    /// Cloud account not found
    case accountNotFound

    /// Credentials not found in Keychain
    case credentialsNotFound

    /// Instance not found
    case instanceNotFound(String)

    /// Instance is not running
    case instanceNotRunning(String)

    /// Failed to generate ephemeral key
    case keyGenerationFailed

    /// Failed to upload public key to AWS
    case keyUploadFailed(String)

    /// Serial console not enabled for instance/account
    case serialConsoleNotEnabled

    /// Too many active serial console sessions
    case sessionLimitExceeded

    /// Failed to connect SSH
    case connectionFailed(String)

    /// Connection timed out (exceeded 60-second key validity)
    case connectionTimeout

    /// SSH authentication failed
    case authenticationFailed(String)

    /// Network error
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return String(localized: "Cloud account not found", comment: "EC2 console error")
        case .credentialsNotFound:
            return String(localized: "AWS credentials not found in Keychain", comment: "EC2 console error")
        case .instanceNotFound(let id):
            return String(localized: "Instance '\(id)' not found", comment: "EC2 console error")
        case .instanceNotRunning(let label):
            return String(localized: "Instance '\(label)' must be running", comment: "EC2 console error")
        case .keyGenerationFailed:
            return String(localized: "Failed to generate ephemeral SSH key", comment: "EC2 console error")
        case .keyUploadFailed(let detail):
            return String(localized: "Failed to authorize console access: \(detail)", comment: "EC2 console error")
        case .serialConsoleNotEnabled:
            return String(localized: "Serial console is not enabled", comment: "EC2 console error")
        case .sessionLimitExceeded:
            return String(localized: "Too many active console sessions", comment: "EC2 console error")
        case .connectionFailed(let detail):
            return String(localized: "Failed to connect: \(detail)", comment: "EC2 console error")
        case .connectionTimeout:
            return String(localized: "Connection timed out", comment: "EC2 console error")
        case .authenticationFailed(let detail):
            return String(localized: "Authentication failed: \(detail)", comment: "EC2 console error")
        case .networkError(let detail):
            return String(localized: "Network error: \(detail)", comment: "EC2 console error")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .accountNotFound, .credentialsNotFound:
            return String(localized: "Re-authenticate with AWS in Settings", comment: "EC2 console recovery suggestion")
        case .instanceNotRunning:
            return String(localized: "Start the instance before connecting to serial console", comment: "EC2 console recovery suggestion")
        case .serialConsoleNotEnabled:
            return String(localized: "Enable serial console in AWS Console: EC2 > Settings > EC2 Serial Console", comment: "EC2 console recovery suggestion")
        case .sessionLimitExceeded:
            return String(localized: "Close other console sessions to this instance or wait for them to expire", comment: "EC2 console recovery suggestion")
        case .connectionTimeout:
            return String(localized: "The ephemeral key is only valid for 60 seconds. Try connecting again.", comment: "EC2 console recovery suggestion")
        default:
            return nil
        }
    }
}
