//
//  SelectionManager.swift
//  rootshell
//
//  Manages text selection appearance settings (colors and mode)
//

import Foundation
import os

extension Notification.Name {
    static let selectionConfigChanged = Notification.Name("selectionConfigChanged")
}

enum SelectionAppearanceMode: String, CaseIterable, Codable {
    case rootshell
    case themeDefault
    case invertFgBg
    case custom

    var displayName: String {
        switch self {
        case .rootshell: return String(localized: "rootshell", comment: "Selection mode: rootshell preset")
        case .themeDefault: return String(localized: "Theme Default", comment: "Selection mode: use theme colors")
        case .invertFgBg: return String(localized: "Invert Colors", comment: "Selection mode: swap foreground/background")
        case .custom: return String(localized: "Custom", comment: "Selection mode: user-chosen colors")
        }
    }

    var description: String {
        switch self {
        case .rootshell: return String(localized: "Catppuccin-inspired selection colors that pair well with most themes", comment: "Selection mode description")
        case .themeDefault: return String(localized: "Uses the active theme's selection colors", comment: "Selection mode description")
        case .invertFgBg: return String(localized: "Swaps foreground and background colors for selected text", comment: "Selection mode description")
        case .custom: return String(localized: "Uses custom foreground and background colors for selected text", comment: "Selection mode description")
        }
    }
}

@MainActor
@Observable
class SelectionManager {
    static let shared = SelectionManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "SelectionManager")

    // MARK: - Settings keys

    private static let ownedKeys: Set<String> = [
        Settings.Selection.appearanceMode.name,
        Settings.Selection.foregroundHex.name,
        Settings.Selection.backgroundHex.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    var selectionMode: SelectionAppearanceMode {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.appearanceMode, selectionMode) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customForegroundHex: String {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.foregroundHex, customForegroundHex) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customBackgroundHex: String {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.backgroundHex, customBackgroundHex) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared
        self.selectionMode = store.get(Settings.Selection.appearanceMode)
        self.customForegroundHex = store.get(Settings.Selection.foregroundHex)
        self.customBackgroundHex = store.get(Settings.Selection.backgroundHex)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Selection.appearanceMode.name) { selectionMode = store.get(Settings.Selection.appearanceMode) }
        if keys.contains(Settings.Selection.foregroundHex.name) { customForegroundHex = store.get(Settings.Selection.foregroundHex) }
        if keys.contains(Settings.Selection.backgroundHex.name) { customBackgroundHex = store.get(Settings.Selection.backgroundHex) }
    }

    // MARK: - Config Generation

    /// Generates the Ghostty config lines for the current selection mode
    // MARK: - Preset Colors

    static let rootshellForegroundHex = "1e1e2e"
    static let rootshellBackgroundHex = "f5e0dc"

    // MARK: - Config Generation

    /// Generates the Ghostty config lines for the current selection mode
    func generateSelectionConfigLines() -> [String] {
        switch selectionMode {
        case .rootshell:
            return [
                "selection-foreground = \"#\(Self.rootshellForegroundHex)\"",
                "selection-background = \"#\(Self.rootshellBackgroundHex)\"",
                "selection-invert-fg-bg = false",
            ]

        case .themeDefault:
            // Omit selection-foreground/background entirely so the theme's values take effect
            return []

        case .invertFgBg:
            return ["selection-invert-fg-bg = true"]

        case .custom:
            return [
                "selection-foreground = \"#\(customForegroundHex)\"",
                "selection-background = \"#\(customBackgroundHex)\"",
                "selection-invert-fg-bg = false",
            ]
        }
    }
}
