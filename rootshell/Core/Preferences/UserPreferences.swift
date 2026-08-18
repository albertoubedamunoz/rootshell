//
//  UserPreferences.swift
//  rootshell
//
//  User-configurable display name and clock format preferences
//

import Foundation

/// Namespace for user preferences that affect prompts and SSH defaults
nonisolated enum UserPreferences {

    // MARK: - Tab Bar

    static let showTabScopeMenuKey = "showTabScopeMenu"

    // MARK: - Background Keepalive

    static let backgroundSessionKeepaliveEnabledKey = "backgroundSessionKeepaliveEnabled"

    /// Whether eligible TCP SSH sessions, active local tasks and live Screen
    /// Sharing panes should request a short UIKit background grace task when
    /// the app backgrounds.
    static var backgroundSessionKeepaliveEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: backgroundSessionKeepaliveEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: backgroundSessionKeepaliveEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: backgroundSessionKeepaliveEnabledKey)
        }
    }

    // MARK: - Username

    private static let customUsernameKey = "customUsername"

    /// Returns the custom username if set, otherwise falls back to NSUserName()
    static var effectiveUsername: String {
        if let custom = UserDefaults.standard.string(forKey: customUsernameKey),
           !custom.isEmpty {
            return custom
        }
        return NSUserName()
    }

    // MARK: - Clock Format

    /// Clock display format for prompt themes
    enum ClockFormat: String, CaseIterable {
        case system = "system"
        case twelveHour = "twelveHour"
        case twentyFourHour = "twentyFourHour"

        var displayName: String {
            switch self {
            case .system: return String(localized: "System Default", comment: "Clock format: system default")
            case .twelveHour: return String(localized: "12-Hour", comment: "Clock format: 12-hour")
            case .twentyFourHour: return String(localized: "24-Hour", comment: "Clock format: 24-hour")
            }
        }
    }

    private static let clockFormatKey = "clockFormat"

    /// Current clock format preference
    static var clockFormat: ClockFormat {
        get {
            guard let raw = UserDefaults.standard.string(forKey: clockFormatKey),
                  let format = ClockFormat(rawValue: raw) else {
                return .system
            }
            return format
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: clockFormatKey)
        }
    }

    /// Formats current time according to the user's clock format preference
    static func formattedTime() -> String {
        let formatter = DateFormatter()
        switch clockFormat {
        case .system:
            formatter.timeStyle = .short
        case .twelveHour:
            formatter.dateFormat = "h:mm a"
        case .twentyFourHour:
            formatter.dateFormat = "HH:mm"
        }
        return formatter.string(from: Date())
    }
}
