//
//  TSSHSessionState.swift
//  rootshell
//
//  State machine for trzsz-ssh session lifecycle
//

import Foundation

/// State machine for trzsz-ssh session lifecycle
/// Used for progress indicator and UI status display
enum TrzszSessionState: Equatable, Sendable {
    /// Initial state before starting
    case initial

    /// Connecting to SSH server (or jump host if configured)
    case connectingSSH(host: String, isJumpHost: Bool)

    /// Authenticating with SSH server
    case authenticatingSSH(host: String, isJumpHost: Bool)

    /// Connected to jump host, now connecting to target
    case connectingToTarget(host: String)

    /// Authenticating with target through SSH tunnel
    case authenticatingTarget(host: String)

    /// Spawning tsshd server on remote host
    case spawningServer

    /// Parsing JSON ServerInfo from tsshd output
    case parsingServerInfo

    /// Establishing QUIC connection
    /// - host: The host being connected to
    /// - port: The UDP port
    case establishingQUIC(host: String, port: Int)

    /// Establishing KCP connection
    /// - host: The host being connected to
    /// - port: The UDP port
    case establishingKCP(host: String, port: Int)

    /// Authenticating proxy connection (for reconnection)
    case authenticatingProxy

    /// Session is running and ready for input
    /// - latencyMs: Current network latency in milliseconds (nil if unknown)
    case running(latencyMs: Int?)

    /// Network path changed, re-establishing connection
    /// - previousNetwork: Description of previous network path
    case roaming(previousNetwork: String)

    /// Session disconnected (network loss or unexpected)
    case disconnected

    /// Server sent clean shutdown signal (user typed exit)
    case serverShutdown

    /// Session failed with error
    case failed

    /// Resuming a persisted session (no SSH spawn)
    /// - host: The host being reconnected to
    /// - port: The UDP port being reconnected to
    case resumingSession(host: String, port: Int)

    /// Resume failed, falling back to SSH spawn
    /// - reason: Why the resume failed
    case resumeFallback(reason: String)

    // MARK: - Human-Readable Status

    /// Human-readable description for UI status line
    var statusDescription: String {
        switch self {
        case .initial:
            return "Ready"
        case .connectingSSH(let host, let isJumpHost):
            return isJumpHost ? "Connecting to jump host \(host)..." : "Connecting via SSH to \(host)..."
        case .authenticatingSSH(_, let isJumpHost):
            return isJumpHost ? "Authenticating with jump host..." : "Authenticating..."
        case .connectingToTarget(let host):
            return "Connecting to \(host)..."
        case .authenticatingTarget:
            return "Authenticating with target..."
        case .spawningServer:
            return "Starting tsshd server..."
        case .parsingServerInfo:
            return "Parsing server info..."
        case .establishingQUIC(let host, let port):
            return "Establishing QUIC to \(host):\(port)..."
        case .establishingKCP(let host, let port):
            return "Establishing KCP to \(host):\(port)..."
        case .authenticatingProxy:
            return "Authenticating session..."
        case .running(let latencyMs):
            if let ms = latencyMs {
                return "Connected (\(ms)ms)"
            }
            return "Connected"
        case .roaming(let previousNetwork):
            return "Roaming from \(previousNetwork)..."
        case .disconnected:
            return "Disconnected"
        case .serverShutdown:
            return "Session ended"
        case .failed:
            return "Connection failed"
        case .resumingSession(let host, let port):
            return "Reconnecting to \(host):\(port)..."
        case .resumeFallback(let reason):
            return "Resuming via SSH (\(reason))..."
        }
    }

    /// Color style for spinner animation based on current state
    var spinnerColorStyle: SpinnerAnimator.ColorStyle {
        switch self {
        case .connectingSSH, .connectingToTarget, .establishingQUIC, .establishingKCP:
            return .connecting
        case .authenticatingSSH, .authenticatingTarget, .spawningServer, .parsingServerInfo, .authenticatingProxy:
            return .authenticating
        case .running:
            return .success
        case .roaming:
            return .reconnecting
        case .failed:
            return .error
        case .resumingSession:
            return .reconnecting
        case .resumeFallback:
            return .connecting
        default:
            return .connecting
        }
    }

    /// Joke category for trzsz connections (uses SSH jokes since it's SSH-based)
    var jokeCategory: ConnectionJokeCategory {
        return .ssh
    }

    // MARK: - State Queries

    /// Whether the session is currently connected and usable
    var isConnected: Bool {
        if case .running = self { return true }
        return false
    }

    /// Whether the session is in a connecting/establishing state
    var isConnecting: Bool {
        switch self {
        case .connectingSSH, .authenticatingSSH, .connectingToTarget,
             .authenticatingTarget, .spawningServer, .parsingServerInfo,
             .establishingQUIC, .establishingKCP, .authenticatingProxy,
             .resumingSession, .resumeFallback:
            return true
        default:
            return false
        }
    }

    /// Whether the session has failed or is in an error state
    var hasFailed: Bool {
        switch self {
        case .failed:
            return true
        default:
            return false
        }
    }

    /// Whether the session supports user input
    var acceptsInput: Bool {
        switch self {
        case .running, .roaming:
            return true
        default:
            return false
        }
    }
}
