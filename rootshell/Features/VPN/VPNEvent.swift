//
//  VPNEvent.swift
//  rootshell
//
//  Event logging for VPN tunnel history
//

import Foundation
import SwiftUI

/// Event log entry for VPN history
struct VPNEvent: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let profileID: UUID
    let timestamp: Date
    let type: EventType
    let message: String?

    enum EventType: String, Codable, Sendable, CaseIterable {
        case connected
        case disconnected
        case reconnecting
        case reconnected
        case error
        case info
        case networkChanged

        var displayName: String {
            switch self {
            case .connected: return String(localized: "Connected", comment: "VPN event status: connected")
            case .disconnected: return String(localized: "Disconnected", comment: "VPN event status: disconnected")
            case .reconnecting: return String(localized: "Reconnecting", comment: "VPN event status: reconnecting")
            case .reconnected: return String(localized: "Reconnected", comment: "VPN event status: reconnected")
            case .error: return String(localized: "Error", comment: "VPN event status: error")
            case .info: return String(localized: "Info", comment: "VPN event status: info")
            case .networkChanged: return String(localized: "Network Changed", comment: "VPN event status: network changed")
            }
        }

        var iconName: String {
            switch self {
            case .connected, .reconnected: return "checkmark.circle.fill"
            case .disconnected: return "xmark.circle.fill"
            case .reconnecting: return "arrow.clockwise.circle.fill"
            case .error: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            case .networkChanged: return "wifi.exclamationmark"
            }
        }

        var iconColor: Color {
            switch self {
            case .connected, .reconnected: return .green
            case .disconnected: return .gray
            case .reconnecting, .networkChanged: return .orange
            case .error: return .red
            case .info: return .blue
            }
        }
    }

    init(
        id: UUID = UUID(),
        profileID: UUID,
        timestamp: Date = Date(),
        type: EventType,
        message: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.timestamp = timestamp
        self.type = type
        self.message = message
    }

    // MARK: - Factory Methods

    static func connected(profileID: UUID, message: String? = nil) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .connected, message: message)
    }

    static func disconnected(profileID: UUID, reason: String? = nil) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .disconnected, message: reason)
    }

    static func reconnecting(profileID: UUID, attempt: Int) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .reconnecting, message: "Attempt \(attempt)")
    }

    static func reconnected(profileID: UUID) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .reconnected)
    }

    static func error(profileID: UUID, message: String) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .error, message: message)
    }

    static func networkChanged(profileID: UUID, newType: String) -> VPNEvent {
        VPNEvent(profileID: profileID, type: .networkChanged, message: newType)
    }

    // MARK: - Display

    var timestampFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: timestamp)
    }

    var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var displayString: String {
        if let message {
            return "\(type.displayName): \(message)"
        }
        return type.displayName
    }
}

extension VPNEvent: Comparable {
    static func < (lhs: VPNEvent, rhs: VPNEvent) -> Bool {
        lhs.timestamp < rhs.timestamp
    }
}
