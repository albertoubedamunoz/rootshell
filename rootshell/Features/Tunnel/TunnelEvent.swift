//
//  TunnelEvent.swift
//  rootshell
//
//  Event logging for background tunnel history
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import SwiftUI

/// Event log entry for tunnel history
struct TunnelEvent: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let tunnelID: UUID  // Profile ID
    let timestamp: Date
    let type: EventType
    let message: String?

    /// Optional forward ID for forward-specific events
    let forwardID: UUID?

    /// Type of tunnel event
    enum EventType: String, Codable, Sendable, CaseIterable {
        case connected
        case disconnected
        case reconnecting
        case reconnected
        case forwardStarted
        case forwardStopped
        case forwardFailed
        case error
        case info

        var displayName: String {
            switch self {
            case .connected: return String(localized: "Connected", comment: "Tunnel event status: connected")
            case .disconnected: return String(localized: "Disconnected", comment: "Tunnel event status: disconnected")
            case .reconnecting: return String(localized: "Reconnecting", comment: "Tunnel event status: reconnecting")
            case .reconnected: return String(localized: "Reconnected", comment: "Tunnel event status: reconnected")
            case .forwardStarted: return String(localized: "Forward Started", comment: "Tunnel event status: forward started")
            case .forwardStopped: return String(localized: "Forward Stopped", comment: "Tunnel event status: forward stopped")
            case .forwardFailed: return String(localized: "Forward Failed", comment: "Tunnel event status: forward failed")
            case .error: return String(localized: "Error", comment: "Tunnel event status: error")
            case .info: return String(localized: "Info", comment: "Tunnel event status: info")
            }
        }

        var iconName: String {
            switch self {
            case .connected, .reconnected: return "checkmark.circle.fill"
            case .disconnected: return "xmark.circle.fill"
            case .reconnecting: return "arrow.clockwise.circle.fill"
            case .forwardStarted: return "arrow.right.circle.fill"
            case .forwardStopped: return "stop.circle.fill"
            case .forwardFailed: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .connected, .reconnected, .forwardStarted: return .green
            case .disconnected, .forwardStopped: return .gray
            case .reconnecting: return .orange
            case .forwardFailed, .error: return .red
            case .info: return .blue
            }
        }

        /// Whether this event type indicates a problem
        var isError: Bool {
            switch self {
            case .forwardFailed, .error: return true
            default: return false
            }
        }

        /// Whether this event type indicates success
        var isSuccess: Bool {
            switch self {
            case .connected, .reconnected, .forwardStarted: return true
            default: return false
            }
        }
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        tunnelID: UUID,
        timestamp: Date = Date(),
        type: EventType,
        message: String? = nil,
        forwardID: UUID? = nil
    ) {
        self.id = id
        self.tunnelID = tunnelID
        self.timestamp = timestamp
        self.type = type
        self.message = message
        self.forwardID = forwardID
    }

    // MARK: - Factory Methods

    /// Create a connected event
    static func connected(tunnelID: UUID, message: String? = nil) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .connected, message: message)
    }

    /// Create a disconnected event
    static func disconnected(tunnelID: UUID, reason: String? = nil) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .disconnected, message: reason)
    }

    /// Create a reconnecting event
    static func reconnecting(tunnelID: UUID, attempt: Int) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .reconnecting, message: "Attempt \(attempt)")
    }

    /// Create a reconnected event
    static func reconnected(tunnelID: UUID) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .reconnected, message: nil)
    }

    /// Create a forward started event
    static func forwardStarted(tunnelID: UUID, forwardID: UUID, description: String) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .forwardStarted, message: description, forwardID: forwardID)
    }

    /// Create a forward stopped event
    static func forwardStopped(tunnelID: UUID, forwardID: UUID, description: String) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .forwardStopped, message: description, forwardID: forwardID)
    }

    /// Create a forward failed event
    static func forwardFailed(tunnelID: UUID, forwardID: UUID, error: String) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .forwardFailed, message: error, forwardID: forwardID)
    }

    /// Create an error event
    static func error(tunnelID: UUID, message: String) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .error, message: message)
    }

    /// Create an info event
    static func info(tunnelID: UUID, message: String) -> TunnelEvent {
        TunnelEvent(tunnelID: tunnelID, type: .info, message: message)
    }

    // MARK: - Computed Properties

    /// Formatted timestamp for display
    var timestampFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }

    /// Relative time string (e.g., "2 minutes ago")
    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    /// Display string combining type and message
    var displayString: String {
        if let message = message {
            return "\(type.displayName): \(message)"
        }
        return type.displayName
    }
}

// MARK: - Comparable

extension TunnelEvent: Comparable {
    static func < (lhs: TunnelEvent, rhs: TunnelEvent) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}

// MARK: - Collection Extensions

extension Array where Element == TunnelEvent {
    /// Filter events by tunnel ID
    func events(for tunnelID: UUID) -> [TunnelEvent] {
        filter { $0.tunnelID == tunnelID }
    }

    /// Filter events by type
    func events(ofType type: TunnelEvent.EventType) -> [TunnelEvent] {
        filter { $0.type == type }
    }

    /// Get only error events
    var errors: [TunnelEvent] {
        filter { $0.type.isError }
    }

    /// Most recent event
    var mostRecent: TunnelEvent? {
        sorted().last
    }

    /// Most recent event for a tunnel
    func mostRecent(for tunnelID: UUID) -> TunnelEvent? {
        events(for: tunnelID).sorted().last
    }
}
