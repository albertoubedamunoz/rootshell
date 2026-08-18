//
//  HolePunchState.swift
//  rootshell
//
//  State machine for UDP hole-punch lifecycle
//

import Foundation

/// State machine for UDP hole-punch lifecycle
///
/// Tracks the progress of hole-punching for UI display and internal logic.
/// The lifecycle is:
/// 1. idle -> discoveringNAT (STUN discovery)
/// 2. discoveringNAT -> natDiscovered (got public IP:port)
/// 3. natDiscovered -> punchingHole (executing SSH command on server)
/// 4. punchingHole -> established (hole is open, return traffic allowed)
/// 5. established -> refreshing (periodic re-punch to maintain hole)
/// 6. refreshing -> established (refresh succeeded)
enum HolePunchState: Equatable, Sendable {
    /// Initial state, no hole-punch in progress
    case idle

    /// Discovering NAT mapping via STUN
    case discoveringNAT

    /// NAT mapping discovered
    /// - publicIP: The client's public IP address as seen by STUN server
    /// - publicPort: The client's public UDP port
    /// - localPort: The local port bound for this mapping
    case natDiscovered(publicIP: String, publicPort: UInt16, localPort: UInt16)

    /// Sending hole-punch packet from server
    /// - attempt: Current attempt number (1-based)
    case punchingHole(attempt: Int)

    /// Hole-punch established and active
    /// - expiresAt: Estimated expiration time of the conntrack entry
    case established(expiresAt: Date)

    /// Refreshing the hole-punch before expiration
    case refreshing

    /// Hole-punch failed
    /// - reason: Human-readable failure reason
    case failed(reason: String)

    /// Hole-punch not needed (direct UDP connectivity works)
    case notNeeded

    // MARK: - Human-Readable Status

    /// Human-readable description for UI/logging
    var statusDescription: String {
        switch self {
        case .idle:
            return "Ready"
        case .discoveringNAT:
            return "Discovering NAT mapping..."
        case .natDiscovered(let ip, let port, _):
            return "NAT discovered: \(ip):\(port)"
        case .punchingHole(let attempt):
            return "Punching hole (attempt \(attempt))..."
        case .established(let expiresAt):
            let remaining = max(0, Int(expiresAt.timeIntervalSinceNow))
            return "Hole established (expires in \(remaining)s)"
        case .refreshing:
            return "Refreshing hole..."
        case .failed(let reason):
            return "Hole-punch failed: \(reason)"
        case .notNeeded:
            return "Direct connectivity (no hole-punch needed)"
        }
    }

    // MARK: - State Queries

    /// Whether the hole-punch is currently active and usable
    var isActive: Bool {
        switch self {
        case .established, .refreshing:
            return true
        default:
            return false
        }
    }

    /// Whether hole-punch is in progress (not idle, not terminal)
    var isInProgress: Bool {
        switch self {
        case .discoveringNAT, .natDiscovered, .punchingHole, .refreshing:
            return true
        default:
            return false
        }
    }

    /// Whether the hole-punch has completed (successfully or not)
    var isTerminal: Bool {
        switch self {
        case .established, .failed, .notNeeded:
            return true
        default:
            return false
        }
    }

    /// Whether the hole-punch failed
    var hasFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    // MARK: - Derived Values

    /// The public IP if NAT has been discovered
    var publicIP: String? {
        switch self {
        case .natDiscovered(let ip, _, _):
            return ip
        default:
            return nil
        }
    }

    /// The public port if NAT has been discovered
    var publicPort: UInt16? {
        switch self {
        case .natDiscovered(_, let port, _):
            return port
        default:
            return nil
        }
    }

    /// The local port bound for hole-punch
    var localPort: UInt16? {
        switch self {
        case .natDiscovered(_, _, let port):
            return port
        default:
            return nil
        }
    }
}

// MARK: - State Transitions

extension HolePunchState {
    /// Validates a state transition and returns the new state if valid
    /// Returns nil if the transition is invalid
    func transition(to newState: HolePunchState) -> HolePunchState? {
        switch (self, newState) {
        // From idle
        case (.idle, .discoveringNAT),
             (.idle, .notNeeded),
             (.idle, .failed):
            return newState

        // From discoveringNAT
        case (.discoveringNAT, .natDiscovered),
             (.discoveringNAT, .failed):
            return newState

        // From natDiscovered
        case (.natDiscovered, .punchingHole),
             (.natDiscovered, .failed):
            return newState

        // From punchingHole
        case (.punchingHole, .punchingHole),  // Retry
             (.punchingHole, .established),
             (.punchingHole, .failed):
            return newState

        // From established
        case (.established, .refreshing),
             (.established, .failed),
             (.established, .idle):  // Manual reset
            return newState

        // From refreshing
        case (.refreshing, .established),
             (.refreshing, .failed):
            return newState

        // From failed - can retry from beginning
        case (.failed, .idle),
             (.failed, .discoveringNAT):
            return newState

        // From notNeeded - can transition back to idle for retry
        case (.notNeeded, .idle):
            return newState

        // Invalid transition
        default:
            return nil
        }
    }
}
