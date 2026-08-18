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

    // MARK: - UserDefaults Keys

    private static let selectionModeKey = "selectionAppearanceMode"
    private static let selectionForegroundHexKey = "selectionForegroundHex"
    private static let selectionBackgroundHexKey = "selectionBackgroundHex"

    // MARK: - Defaults

    private static let defaultMode = SelectionAppearanceMode.rootshell
    private static let defaultForegroundHex = "1e1e2e"
    private static let defaultBackgroundHex = "f5e0dc"

    // MARK: - Observable Properties

    var selectionMode: SelectionAppearanceMode {
        didSet {
            UserDefaults.standard.set(selectionMode.rawValue, forKey: Self.selectionModeKey)
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customForegroundHex: String {
        didSet {
            UserDefaults.standard.set(customForegroundHex, forKey: Self.selectionForegroundHexKey)
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customBackgroundHex: String {
        didSet {
            UserDefaults.standard.set(customBackgroundHex, forKey: Self.selectionBackgroundHexKey)
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        if let modeRaw = UserDefaults.standard.string(forKey: Self.selectionModeKey),
           let mode = SelectionAppearanceMode(rawValue: modeRaw) {
            self.selectionMode = mode
        } else {
            self.selectionMode = Self.defaultMode
        }

        self.customForegroundHex = UserDefaults.standard.string(forKey: Self.selectionForegroundHexKey)
            ?? Self.defaultForegroundHex

        self.customBackgroundHex = UserDefaults.standard.string(forKey: Self.selectionBackgroundHexKey)
            ?? Self.defaultBackgroundHex
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
