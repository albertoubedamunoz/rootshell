//
//  Settings+Visor.swift
//  rootshell
//
//  Visor (drop-down terminal) keys. Standalone Mac Catalyst only; hotkeys
//  and screen geometry are per machine, so everything starts pinned.
//

import Foundation

#if STANDALONE && targetEnvironment(macCatalyst)

extension VisorPosition: SettingValue {}
extension VisorScreenChoice: SettingValue {}
extension VisorSpaceBehavior: SettingValue {}

nonisolated extension Settings {
    enum Visor {
        static let enabled = SettingKey(
            "visor.enabled", default: false, group: .visor, policy: .localByDefault,
            configKey: "visor-enabled",
            title: String(localized: "Enable Visor", comment: "Setting title"))
        static let position = SettingKey(
            "visor.position", default: VisorPosition.top, group: .visor, policy: .localByDefault,
            configKey: "visor-position",
            title: String(localized: "Visor Edge", comment: "Setting title"))
        static let screen = SettingKey(
            "visor.screen", default: VisorScreenChoice.main, group: .visor, policy: .localByDefault,
            configKey: "visor-screen",
            title: String(localized: "Visor Screen", comment: "Setting title"))
        static let primarySize = SettingKey(
            "visor.primarySize", default: "30%", group: .visor, policy: .localByDefault,
            configKey: "visor-primary-size",
            title: String(localized: "Visor Slide Size", comment: "Setting title"))
        static let secondarySize = SettingKey(
            "visor.secondarySize", default: "", group: .visor, policy: .localByDefault,
            configKey: "visor-secondary-size",
            title: String(localized: "Visor Cross Axis Size", comment: "Setting title"))
        static let animationDurationMs = SettingKey(
            "visor.animationDurationMs", default: 200, group: .visor, policy: .localByDefault,
            configKey: "visor-animation-duration-ms",
            title: String(localized: "Visor Animation Duration", comment: "Setting title"))
        static let autohide = SettingKey(
            "visor.autohide", default: true, group: .visor, policy: .localByDefault,
            configKey: "visor-autohide",
            title: String(localized: "Visor Auto-Hide", comment: "Setting title"))
        static let spaceBehavior = SettingKey(
            "visor.spaceBehavior", default: VisorSpaceBehavior.move, group: .visor, policy: .localByDefault,
            configKey: "visor-space-behavior",
            title: String(localized: "Visor Space Behavior", comment: "Setting title"))
        static let hotkeyKeyCode = SettingKey(
            "visor.hotkeyKeyCode", default: -1, group: .visor, policy: .localByDefault,
            configKey: "visor-hotkey-key-code",
            title: String(localized: "Visor Hotkey", comment: "Setting title"))
        static let hotkeyModifiers = SettingKey(
            "visor.hotkeyModifiers", default: 0, group: .visor, policy: .localByDefault,
            configKey: "visor-hotkey-modifiers",
            title: String(localized: "Visor Hotkey Modifiers", comment: "Setting title"))
        static let useEventTap = SettingKey(
            "visor.useEventTap", default: false, group: .visor, policy: .localByDefault,
            configKey: "visor-use-event-tap",
            title: String(localized: "Visor Event Tap", comment: "Setting title"))
        static let persistentSceneIdentifier = AnySettingDefinition.opaque(
            "visor.persistentSceneIdentifier", group: .visor,
            title: String(localized: "Visor Scene Identifier", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            enabled.erased, position.erased, screen.erased, primarySize.erased,
            secondarySize.erased, animationDurationMs.erased, autohide.erased,
            spaceBehavior.erased, hotkeyKeyCode.erased, hotkeyModifiers.erased,
            useEventTap.erased, persistentSceneIdentifier,
        ]
    }
}

#else

nonisolated extension Settings {
    enum Visor {
        static let all: [AnySettingDefinition] = []
    }
}

#endif
