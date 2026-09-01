//
//  SettingPolicy.swift
//  rootshell
//
//  Sync policy and grouping metadata for registered settings.
//

import Foundation

/// How a setting participates in iCloud settings sync.
nonisolated enum SyncPolicy: String, Codable, Sendable {
    /// Synced unless the user pins it to this device.
    case synced
    /// Syncable, but starts pinned: device-shape or platform specific.
    case localByDefault
    /// Never leaves the device and has no pin UI.
    case deviceOnly
}

/// Pin granularity. Roughly one group per settings screen or sub-section.
nonisolated enum SettingGroup: String, Codable, CaseIterable, Sendable {
    case theme, font, cursor, selection, transparency, palette, shaders
    case tabs, sidebar, window, visor
    case terminal, scrollback, prompt, locale, sessionRestore
    case keyboard, keyboardToolbar, keybinds, gestures
    case connections, multiplexer, sshAgent, hostTrust, roam, screenSharing, transfer
    case ai, codingAgents, notifications, privacy, sounds, power, liveActivity, clipboard
    case system

    var title: String {
        switch self {
        case .theme: String(localized: "Theme", comment: "Setting group title")
        case .font: String(localized: "Font", comment: "Setting group title")
        case .cursor: String(localized: "Cursor", comment: "Setting group title")
        case .selection: String(localized: "Selection", comment: "Setting group title")
        case .transparency: String(localized: "Transparency", comment: "Setting group title")
        case .palette: String(localized: "Colors", comment: "Setting group title")
        case .shaders: String(localized: "Shaders & Effects", comment: "Setting group title")
        case .tabs: String(localized: "Tabs", comment: "Setting group title")
        case .sidebar: String(localized: "Sidebar", comment: "Setting group title")
        case .window: String(localized: "Window", comment: "Setting group title")
        case .visor: String(localized: "Visor", comment: "Setting group title")
        case .terminal: String(localized: "Terminal", comment: "Setting group title")
        case .scrollback: String(localized: "Scrollback", comment: "Setting group title")
        case .prompt: String(localized: "Prompt", comment: "Setting group title")
        case .locale: String(localized: "Locale", comment: "Setting group title")
        case .sessionRestore: String(localized: "Session", comment: "Setting group title")
        case .keyboard: String(localized: "Keyboard", comment: "Setting group title")
        case .keyboardToolbar: String(localized: "Toolbar Keys", comment: "Setting group title")
        case .keybinds: String(localized: "Keyboard Shortcuts", comment: "Setting group title")
        case .gestures: String(localized: "Gestures", comment: "Setting group title")
        case .connections: String(localized: "Connections", comment: "Setting group title")
        case .multiplexer: String(localized: "Multiplexers", comment: "Setting group title")
        case .sshAgent: String(localized: "SSH Agent", comment: "Setting group title")
        case .hostTrust: String(localized: "Host Trust", comment: "Setting group title")
        case .roam: String(localized: "Roam", comment: "Setting group title")
        case .screenSharing: String(localized: "Screen Sharing", comment: "Setting group title")
        case .transfer: String(localized: "File Transfer", comment: "Setting group title")
        case .ai: String(localized: "AI Assistant", comment: "Setting group title")
        case .codingAgents: String(localized: "Coding Agents", comment: "Setting group title")
        case .notifications: String(localized: "Notifications", comment: "Setting group title")
        case .privacy: String(localized: "Privacy", comment: "Setting group title")
        case .sounds: String(localized: "Sounds", comment: "Setting group title")
        case .power: String(localized: "Battery & Display", comment: "Setting group title")
        case .liveActivity: String(localized: "Live Activity", comment: "Setting group title")
        case .clipboard: String(localized: "Clipboard", comment: "Setting group title")
        case .system: String(localized: "System", comment: "Setting group title")
        }
    }

    var systemImage: String {
        switch self {
        case .theme: "paintpalette"
        case .font: "textformat"
        case .cursor: "cursorarrow"
        case .selection: "selection.pin.in.out"
        case .transparency: "circle.lefthalf.filled"
        case .palette: "swatchpalette"
        case .shaders: "sparkles.rectangle.stack"
        case .tabs: "rectangle.topthird.inset.filled"
        case .sidebar: "sidebar.leading"
        case .window: "macwindow"
        case .visor: "menubar.arrow.down.rectangle"
        case .terminal: "terminal"
        case .scrollback: "arrow.up.and.down.text.horizontal"
        case .prompt: "chevron.right"
        case .locale: "globe"
        case .sessionRestore: "arrow.counterclockwise"
        case .keyboard: "keyboard"
        case .keyboardToolbar: "keyboard.badge.ellipsis"
        case .keybinds: "command"
        case .gestures: "hand.draw"
        case .connections: "network"
        case .multiplexer: "square.split.2x2"
        case .sshAgent: "key"
        case .hostTrust: "checkmark.shield"
        case .roam: "antenna.radiowaves.left.and.right"
        case .screenSharing: "display"
        case .transfer: "arrow.up.arrow.down"
        case .ai: "sparkles"
        case .codingAgents: "terminal.fill"
        case .notifications: "bell"
        case .privacy: "hand.raised"
        case .sounds: "speaker.wave.2"
        case .power: "battery.75percent"
        case .liveActivity: "timer"
        case .clipboard: "doc.on.clipboard"
        case .system: "gearshape"
        }
    }

    /// Top-level settings section this group is edited from.
    var section: SettingsSection {
        switch self {
        case .theme, .font, .cursor, .selection, .transparency, .palette, .shaders,
             .tabs, .sidebar, .window, .visor, .power:
            .appearance
        case .terminal, .scrollback, .prompt, .locale, .sessionRestore,
             .keyboard, .keyboardToolbar, .keybinds, .gestures, .codingAgents:
            .terminal
        case .connections, .multiplexer, .sshAgent, .hostTrust, .roam, .screenSharing, .transfer:
            .connections
        case .ai:
            .aiAssistant
        case .privacy, .clipboard, .system:
            .privacyData
        case .notifications, .sounds, .liveActivity:
            .notifications
        }
    }
}
