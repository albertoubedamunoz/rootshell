//
//  TabExposeSettings.swift
//  rootshell
//
//  UserDefaults keys for the tab exposé. Both default to true, so readers
//  must distinguish "unset" from `false`.
//

import Foundation

nonisolated enum TabExposeSettings {
    /// Two-finger / trackpad pull-down above the terminal reveals the exposé.
    static let gestureEnabledKey = "tabExposeGestureEnabled"
    /// Title + badges under each preview.
    static let showsCaptionsKey = "tabExposeShowsCaptions"

    static func gestureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: gestureEnabledKey) as? Bool ?? true
    }

    static func showsCaptions(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsCaptionsKey) as? Bool ?? true
    }
}
