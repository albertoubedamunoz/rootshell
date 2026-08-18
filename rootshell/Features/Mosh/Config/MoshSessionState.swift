//
//  MoshSessionState.swift
//  rootshell
//
//  State machine for Mosh session lifecycle
//

import Foundation

/// State machine for Mosh session lifecycle
/// Used for progress indicator and UI status display
enum MoshSessionState: Equatable, Sendable {
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

    /// Spawning mosh-server on remote host
    case spawningServer

    /// Trying direct UDP connection (reactive hole-punch: direct-first strategy)
    /// - host: The host being connected to
    /// - family: The address family being tried
    case tryingDirectUDP(host: String, family: AddressFamily)

    /// Direct UDP connection timed out, will try hole-punch
    case directUDPTimeout

    /// Performing UDP hole-punch to traverse firewall
    /// - publicIP: The client's public IP discovered via STUN
    /// - publicPort: The client's public UDP port
    case holePunching(publicIP: String, publicPort: UInt16)

    /// Hole-punching for specific address family (reactive flow)
    /// - family: The address family being punched (ipv4 or ipv6)
    case holePunchingFamily(family: AddressFamily)

    /// Reactive hole-punch during active session (heartbeat timeout recovery)
    /// - family: The address family being re-punched
    case reactiveHolePunch(family: AddressFamily)

    /// Connecting UDP transport to mosh-server
    case connectingUDP(host: String, port: Int)

    /// Synchronizing initial terminal state
    case synchronizing

    /// Session is running and ready for input
    /// latencyMs: Current network latency in milliseconds (nil if unknown)
    case running(latencyMs: Int?)

    /// Network path changed, re-establishing connection
    /// previousNetwork: Description of previous network path
    case roaming(previousNetwork: String)

    /// Session disconnected (network loss or unexpected)
    case disconnected

    /// Server sent clean shutdown signal (user typed exit)
    case serverShutdown

    /// Session failed with error
    case failed

    /// Waiting to reconnect after connection loss
    /// attempt: Current reconnection attempt number
    /// delaySeconds: Seconds until next reconnection attempt
    case waitingToReconnect(attempt: Int, delaySeconds: Int)

    /// Actively attempting to reconnect
    /// attempt: Current reconnection attempt number
    case reconnecting(attempt: Int)

    /// Reconnection failed after max attempts or permanent error
    /// reason: Human-readable failure reason
    case reconnectionFailed(reason: String)

    /// Resuming a persisted session via UDP (no SSH spawn)
    /// host: The host being reconnected to
    /// port: The UDP port being reconnected to
    case resumingSession(host: String, port: Int)

    /// Resume failed, falling back to SSH spawn
    /// reason: Why the resume failed (e.g., "Server not responding", "Session key expired")
    case resumeFallback(reason: String)

    /// Hole-punching during resume (NAT hole expired while backgrounded)
    /// - publicIP: The client's public IP discovered via STUN
    /// - publicPort: The client's public UDP port
    case resumeHolePunching(publicIP: String, publicPort: UInt16)

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
            return "Teaching server to roam free..."
        case .tryingDirectUDP(let host, let family):
            return "Trying direct connection to \(host) (\(family.rawValue))..."
        case .directUDPTimeout:
            return "Direct connection timed out, trying hole-punch..."
        case .holePunching(let publicIP, let publicPort):
            return "Punching through firewall (\(publicIP):\(publicPort))..."
        case .holePunchingFamily(let family):
            return "Hole-punching (\(family.rawValue))..."
        case .reactiveHolePunch(let family):
            return "Re-establishing connection (\(family.rawValue))..."
        case .connectingUDP(let host, let port):
            return "Connecting UDP to \(host):\(port)..."
        case .synchronizing:
            return "Synchronizing..."
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
        case .waitingToReconnect(let attempt, let delay):
            return "Reconnecting in \(delay)s (attempt \(attempt))..."
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))..."
        case .reconnectionFailed(let reason):
            return "Reconnection failed: \(reason)"
        case .resumingSession(let host, let port):
            return "Reconnecting to \(host):\(port)..."
        case .resumeFallback(let reason):
            return "Resuming via SSH (\(reason))..."
        case .resumeHolePunching(let publicIP, let publicPort):
            return "Re-establishing connection (\(publicIP):\(publicPort))..."
        }
    }

    /// Color style for spinner animation based on current state
    var spinnerColorStyle: SpinnerAnimator.ColorStyle {
        switch self {
        case .connectingSSH, .connectingToTarget, .connectingUDP:
            return .connecting
        case .authenticatingSSH, .authenticatingTarget, .spawningServer, .holePunching, .holePunchingFamily:
            return .authenticating
        case .tryingDirectUDP, .directUDPTimeout:
            return .connecting
        case .synchronizing:
            return .connecting
        case .running:
            return .success
        case .roaming, .reactiveHolePunch, .resumeHolePunching:
            return .reconnecting
        case .failed, .reconnectionFailed:
            return .error
        case .waitingToReconnect, .reconnecting:
            return .reconnecting
        case .resumingSession:
            return .reconnecting
        case .resumeFallback:
            return .connecting
        default:
            return .connecting
        }
    }

    /// Joke category for Mosh connections (uses SSH jokes since mosh is SSH-based)
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
             .authenticatingTarget, .spawningServer, .holePunching,
             .holePunchingFamily, .tryingDirectUDP, .directUDPTimeout,
             .connectingUDP, .synchronizing, .resumingSession, .resumeFallback,
             .reactiveHolePunch, .resumeHolePunching:
            return true
        default:
            return false
        }
    }

    /// Whether the session has failed or is in an error state
    var hasFailed: Bool {
        switch self {
        case .failed, .reconnectionFailed:
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

