//
//  MoshRoamBannerState.swift
//  rootshell
//
//  Published state for Mosh roam banner SwiftUI overlay
//

import Foundation

/// Published state for Mosh roam banner overlay
///
/// This struct contains the data needed to render the SwiftUI roam banner.
/// The banner appears when the Mosh connection experiences network issues
/// (timeout or explicit message from the notification engine).
struct MoshRoamBannerState: Equatable, Sendable {
    /// The message to display (e.g., "Last contact 15 seconds ago")
    let message: String

    /// Seconds since last server contact (for countdown display)
    let secondsSinceContact: Int

    /// Whether a hole-punch operation is currently in progress
    let holePunchInProgress: Bool

    /// Whether this is a timeout banner vs explicit message
    /// Timeout banners show "Last contact X seconds ago" style messages
    let isTimeoutBanner: Bool

    /// Whether this banner represents a reply timeout vs server contact timeout
    /// Reply timeout means server received our data but we haven't received acknowledgment
    let isReplyTimeout: Bool
}
