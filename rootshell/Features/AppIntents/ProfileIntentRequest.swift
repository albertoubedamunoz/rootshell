//
//  ProfileIntentRequest.swift
//  rootshell
//
//  Request model for App Intent-triggered profile connections.
//

import Foundation

/// Carries profile connection details from an App Intent to MainView.
struct ProfileIntentRequest: Sendable {
    /// The profile to connect to
    let profileID: UUID

    /// Overrides the profile's own launchCommand when non-nil
    let launchCommandOverride: String?
}

extension Notification.Name {
    /// Posted by VPN intents to navigate to Settings > VPN
    static let vpnIntentReceived = Notification.Name("com.rootshell.vpnIntentReceived")
}
