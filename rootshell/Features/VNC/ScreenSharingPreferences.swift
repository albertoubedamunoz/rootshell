//
//  ScreenSharingPreferences.swift
//  rootshell
//
//  Global defaults for newly created Screen Sharing panes.
//

import Foundation

enum ScreenSharingClipboardSyncDefault: String, CaseIterable, Sendable {
    case automatic
    case off
    case alwaysOn

    static let storageKey = "screenSharingClipboardSyncDefault"
    static let defaultValue = Self.automatic

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return defaultValue
        }
        return Self(rawValue: rawValue) ?? defaultValue
    }

    var displayName: String {
        switch self {
        case .automatic:
            return String(localized: "Auto", comment: "Screen Sharing clipboard sync default")
        case .off:
            return String(localized: "Off", comment: "Screen Sharing clipboard sync default")
        case .alwaysOn:
            return String(localized: "Always On", comment: "Screen Sharing clipboard sync default")
        }
    }
}

enum ScreenSharingPanningDefault: String, CaseIterable, Sendable {
    case edge
    case continuous

    static let storageKey = "screenSharingPanningDefault"
    static let defaultValue = Self.edge

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey) else {
            return defaultValue
        }
        return Self(rawValue: rawValue) ?? defaultValue
    }

    var displayName: String {
        switch self {
        case .edge:
            return String(
                localized: "When Pointer Reaches Edge",
                comment: "Screen Sharing panning default"
            )
        case .continuous:
            return String(
                localized: "Continuously with Pointer",
                comment: "Screen Sharing panning default"
            )
        }
    }
}
