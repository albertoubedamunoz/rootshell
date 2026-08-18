//
//  VisorSettings.swift
//  rootshell
//
//  User preferences for the Quake/Visor terminal (Standalone Mac Catalyst).
//  Settings are persisted in UserDefaults and observed by VisorController
//  and VisorHotkeyManager via Combine.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import Combine
import SwiftUI

enum VisorPosition: String, CaseIterable, Identifiable, Codable {
    case top, bottom, left, right, center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .left: return "Left"
        case .right: return "Right"
        case .center: return "Center"
        }
    }
}

enum VisorScreenChoice: String, CaseIterable, Identifiable, Codable {
    case main
    case mouse
    case macosMenuBar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: return "Main"
        case .mouse: return "Screen with cursor"
        case .macosMenuBar: return "Screen with menu bar"
        }
    }
}

enum VisorSpaceBehavior: String, CaseIterable, Identifiable, Codable {
    case move
    case remain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: return "Follow active space"
        case .remain: return "Stay in current space"
        }
    }
}

@MainActor
final class VisorSettings: ObservableObject {
    static let shared = VisorSettings()

    private enum Keys {
        static let enabled = "visor.enabled"
        static let position = "visor.position"
        static let screen = "visor.screen"
        static let primarySize = "visor.primarySize"
        static let secondarySize = "visor.secondarySize"
        static let animationDurationMs = "visor.animationDurationMs"
        static let autohide = "visor.autohide"
        static let spaceBehavior = "visor.spaceBehavior"
        static let hotkeyKeyCode = "visor.hotkeyKeyCode"
        static let hotkeyModifiers = "visor.hotkeyModifiers"
        static let useEventTap = "visor.useEventTap"
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    @Published var position: VisorPosition {
        didSet { UserDefaults.standard.set(position.rawValue, forKey: Keys.position) }
    }

    @Published var screen: VisorScreenChoice {
        didSet { UserDefaults.standard.set(screen.rawValue, forKey: Keys.screen) }
    }

    /// Primary-axis size. `"<num>%"` or `"<num>px"`. Empty = default.
    @Published var primarySize: String {
        didSet { UserDefaults.standard.set(primarySize, forKey: Keys.primarySize) }
    }

    /// Secondary-axis size. Empty = fill axis.
    @Published var secondarySize: String {
        didSet { UserDefaults.standard.set(secondarySize, forKey: Keys.secondarySize) }
    }

    @Published var animationDurationMs: Int {
        didSet { UserDefaults.standard.set(animationDurationMs, forKey: Keys.animationDurationMs) }
    }

    @Published var autohide: Bool {
        didSet { UserDefaults.standard.set(autohide, forKey: Keys.autohide) }
    }

    @Published var spaceBehavior: VisorSpaceBehavior {
        didSet { UserDefaults.standard.set(spaceBehavior.rawValue, forKey: Keys.spaceBehavior) }
    }

    /// Carbon virtual key code. -1 means unset.
    @Published var hotkeyKeyCode: Int {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: Keys.hotkeyKeyCode) }
    }

    /// Carbon modifier mask (cmdKey/optionKey/controlKey/shiftKey from HIToolbox).
    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    @Published var useEventTap: Bool {
        didSet { UserDefaults.standard.set(useEventTap, forKey: Keys.useEventTap) }
    }

    var hotkeyConfigured: Bool {
        hotkeyKeyCode >= 0
    }

    var animationDuration: TimeInterval {
        TimeInterval(animationDurationMs) / 1000.0
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        position = VisorPosition(rawValue: d.string(forKey: Keys.position) ?? "") ?? .top
        screen = VisorScreenChoice(rawValue: d.string(forKey: Keys.screen) ?? "") ?? .main
        primarySize = d.string(forKey: Keys.primarySize) ?? "30%"
        secondarySize = d.string(forKey: Keys.secondarySize) ?? ""
        let storedDuration = d.object(forKey: Keys.animationDurationMs) as? Int
        animationDurationMs = storedDuration ?? 200
        let storedAutohide = d.object(forKey: Keys.autohide) as? Bool
        autohide = storedAutohide ?? true
        spaceBehavior = VisorSpaceBehavior(rawValue: d.string(forKey: Keys.spaceBehavior) ?? "") ?? .move
        let storedKey = d.object(forKey: Keys.hotkeyKeyCode) as? Int
        hotkeyKeyCode = storedKey ?? -1
        let storedMods = d.object(forKey: Keys.hotkeyModifiers) as? Int ?? 0
        hotkeyModifiers = UInt32(storedMods)
        useEventTap = d.bool(forKey: Keys.useEventTap)
    }

    /// A combined publisher fired any time a setting changes that the hotkey
    /// manager cares about (key code, modifiers, backend choice, enabled).
    var hotkeyConfigPublisher: AnyPublisher<HotkeyConfig, Never> {
        Publishers.CombineLatest4(
            $enabled,
            $hotkeyKeyCode,
            $hotkeyModifiers,
            $useEventTap
        )
        .map { enabled, code, mods, useTap in
            HotkeyConfig(enabled: enabled, keyCode: code, modifiers: mods, useEventTap: useTap)
        }
        .removeDuplicates()
        .eraseToAnyPublisher()
    }

    struct HotkeyConfig: Equatable {
        var enabled: Bool
        var keyCode: Int
        var modifiers: UInt32
        var useEventTap: Bool
    }
}

#endif
