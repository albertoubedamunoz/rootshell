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

    private typealias Keys = Settings.Visor

    @Published var enabled: Bool {
        didSet { store(Keys.enabled, enabled) }
    }

    @Published var position: VisorPosition {
        didSet { store(Keys.position, position) }
    }

    @Published var screen: VisorScreenChoice {
        didSet { store(Keys.screen, screen) }
    }

    /// Primary-axis size. `"<num>%"` or `"<num>px"`. Empty = default.
    @Published var primarySize: String {
        didSet { store(Keys.primarySize, primarySize) }
    }

    /// Secondary-axis size. Empty = fill axis.
    @Published var secondarySize: String {
        didSet { store(Keys.secondarySize, secondarySize) }
    }

    @Published var animationDurationMs: Int {
        didSet { store(Keys.animationDurationMs, animationDurationMs) }
    }

    @Published var autohide: Bool {
        didSet { store(Keys.autohide, autohide) }
    }

    @Published var spaceBehavior: VisorSpaceBehavior {
        didSet { store(Keys.spaceBehavior, spaceBehavior) }
    }

    /// Carbon virtual key code. -1 means unset.
    @Published var hotkeyKeyCode: Int {
        didSet { store(Keys.hotkeyKeyCode, hotkeyKeyCode) }
    }

    /// Carbon modifier mask (cmdKey/optionKey/controlKey/shiftKey from HIToolbox).
    @Published var hotkeyModifiers: UInt32 {
        didSet { store(Keys.hotkeyModifiers, Int(hotkeyModifiers)) }
    }

    @Published var useEventTap: Bool {
        didSet { store(Keys.useEventTap, useEventTap) }
    }

    private var isReloading = false

    private func store<V: SettingValue>(_ key: SettingKey<V>, _ value: V) {
        guard !isReloading else { return }
        SettingsStore.shared.set(key, value)
    }

    var hotkeyConfigured: Bool {
        hotkeyKeyCode >= 0
    }

    var animationDuration: TimeInterval {
        TimeInterval(animationDurationMs) / 1000.0
    }

    private init() {
        let s = SettingsStore.shared
        enabled = s.get(Keys.enabled)
        position = s.get(Keys.position)
        screen = s.get(Keys.screen)
        primarySize = s.get(Keys.primarySize)
        secondarySize = s.get(Keys.secondarySize)
        animationDurationMs = s.get(Keys.animationDurationMs)
        autohide = s.get(Keys.autohide)
        spaceBehavior = s.get(Keys.spaceBehavior)
        hotkeyKeyCode = s.get(Keys.hotkeyKeyCode)
        hotkeyModifiers = UInt32(s.get(Keys.hotkeyModifiers))
        useEventTap = s.get(Keys.useEventTap)
        SettingsRefreshHub.shared.register(keys: [
            Keys.enabled.name, Keys.position.name, Keys.screen.name, Keys.primarySize.name,
            Keys.secondarySize.name, Keys.animationDurationMs.name, Keys.autohide.name,
            Keys.spaceBehavior.name, Keys.hotkeyKeyCode.name, Keys.hotkeyModifiers.name, Keys.useEventTap.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let s = SettingsStore.shared
        if keys.contains(Keys.enabled.name) { enabled = s.get(Keys.enabled) }
        if keys.contains(Keys.position.name) { position = s.get(Keys.position) }
        if keys.contains(Keys.screen.name) { screen = s.get(Keys.screen) }
        if keys.contains(Keys.primarySize.name) { primarySize = s.get(Keys.primarySize) }
        if keys.contains(Keys.secondarySize.name) { secondarySize = s.get(Keys.secondarySize) }
        if keys.contains(Keys.animationDurationMs.name) { animationDurationMs = s.get(Keys.animationDurationMs) }
        if keys.contains(Keys.autohide.name) { autohide = s.get(Keys.autohide) }
        if keys.contains(Keys.spaceBehavior.name) { spaceBehavior = s.get(Keys.spaceBehavior) }
        if keys.contains(Keys.hotkeyKeyCode.name) { hotkeyKeyCode = s.get(Keys.hotkeyKeyCode) }
        if keys.contains(Keys.hotkeyModifiers.name) { hotkeyModifiers = UInt32(s.get(Keys.hotkeyModifiers)) }
        if keys.contains(Keys.useEventTap.name) { useEventTap = s.get(Keys.useEventTap) }
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
