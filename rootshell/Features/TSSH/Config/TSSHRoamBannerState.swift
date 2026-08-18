//
//  TSSHRoamBannerState.swift
//  rootshell
//
//  Published state for Trzsz roam banner SwiftUI overlay
//

import Foundation

/// Published state for Trzsz roam banner overlay
///
/// This struct contains the data needed to render the SwiftUI roam banner.
/// The banner appears when the Trzsz connection experiences network issues
/// or is reconnecting.
struct TrzszRoamBannerState: Equatable, Sendable {
    /// The message to display (e.g., "Reconnecting..." or "Last contact 15 seconds ago")
    let message: String

    /// Seconds since last server contact (for countdown display)
    let secondsSinceContact: Int

    /// Whether a reconnection is currently in progress
    let reconnecting: Bool

    /// Current reconnection attempt number (0 if not reconnecting)
    let reconnectAttempt: Int

    /// Creates a reconnecting banner state
    static func reconnecting(attempt: Int, secondsSinceContact: Int) -> TrzszRoamBannerState {
        let message = attempt > 1
            ? "Reconnecting (attempt \(attempt))..."
            : "Reconnecting..."
        return TrzszRoamBannerState(
            message: message,
            secondsSinceContact: secondsSinceContact,
            reconnecting: true,
            reconnectAttempt: attempt
        )
    }

    /// Creates a timeout banner state (lost contact but not actively reconnecting yet)
    static func timeout(secondsSinceContact: Int) -> TrzszRoamBannerState {
        let message = "Last contact \(humanReadableDuration(secondsSinceContact)) ago"
        return TrzszRoamBannerState(
            message: message,
            secondsSinceContact: secondsSinceContact,
            reconnecting: false,
            reconnectAttempt: 0
        )
    }

    /// Formats seconds into human-readable duration matching Mosh convention
    /// e.g. "15 seconds", "2:30", "1:02:30"
    private static func humanReadableDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) second\(seconds == 1 ? "" : "s")"
        } else if seconds < 3600 {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        } else {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
    }

    /// Creates a connection lost banner
    static func connectionLost(reason: String) -> TrzszRoamBannerState {
        TrzszRoamBannerState(
            message: "Connection lost: \(reason)",
            secondsSinceContact: 0,
            reconnecting: false,
            reconnectAttempt: 0
        )
    }
}
