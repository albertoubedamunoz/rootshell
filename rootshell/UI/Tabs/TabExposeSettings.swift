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
    /// On a tab attached to herdr / tmux / zellij, open on that session's tabs.
    static let multiplexerEnabledKey = "tabExposeMultiplexerEnabled"

    static func gestureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: gestureEnabledKey) as? Bool ?? true
    }

    static func multiplexerEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: multiplexerEnabledKey) as? Bool ?? true
    }

    static func showsCaptions(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsCaptionsKey) as? Bool ?? true
    }

    /// Pinch-set preview scale; 1 = the auto-fit grid.
    static let zoomRange: ClosedRange<CGFloat> = 0.4...3.0

    static func zoom() -> CGFloat {
        clampZoom(CGFloat(SettingsStore.shared.value(Settings.Tabs.exposeZoom)))
    }

    @MainActor
    static func setZoom(_ zoom: CGFloat) {
        SettingsStore.shared.set(Settings.Tabs.exposeZoom, Double(clampZoom(zoom)))
    }

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
