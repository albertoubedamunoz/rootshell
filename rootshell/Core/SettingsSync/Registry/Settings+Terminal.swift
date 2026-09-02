//
//  Settings+Terminal.swift
//  rootshell
//
//  Terminal behavior, scrollback and gestures, prompt, locale, and session restore keys.
//

import Foundation

#if !targetEnvironment(macCatalyst)
extension StarshipTheme: SettingValue {}
#endif
extension LocaleHelper.LocaleMode: SettingValue {}
extension UserPreferences.ClockFormat: SettingValue {}

nonisolated extension Settings {
    enum Terminal {
        static let terminalTypeLocal = SettingKey(
            "terminalTypeLocal", default: TerminalTypeSettings.localFallback, group: .terminal, policy: .localByDefault,
            configKey: "terminal-type-local",
            title: String(localized: "Terminal Type (Local)", comment: "Setting title"))
        static let terminalTypeRemote = SettingKey(
            "terminalTypeRemote", default: TerminalTypeSettings.fallback, group: .terminal,
            configKey: "terminal-type-remote",
            title: String(localized: "Terminal Type (Remote)", comment: "Setting title"))
        static let localShellCommand = SettingKey(
            "localShellCommand", default: "", group: .terminal, policy: .localByDefault,
            configKey: "local-shell-command",
            title: String(localized: "Local Shell", comment: "Setting title"))
        static let paddingXOverride = SettingKey<Int?>(
            "windowPaddingXOverride", default: nil, group: .terminal, policy: .localByDefault,
            configKey: "window-padding-x",
            title: String(localized: "Horizontal Padding", comment: "Setting title"))
        static let paddingYOverride = SettingKey<Int?>(
            "windowPaddingYOverride", default: nil, group: .terminal, policy: .localByDefault,
            configKey: "window-padding-y",
            title: String(localized: "Vertical Padding", comment: "Setting title"))
        static let rcfileInProgress = SettingKey(
            "rcfile.inProgress", default: false, group: .terminal, policy: .deviceOnly,
            title: String(localized: "RC File Load in Progress", comment: "Setting title"))
        static let rcfileConsecutiveFailures = SettingKey(
            "rcfile.consecutiveFailures", default: 0, group: .terminal, policy: .deviceOnly,
            title: String(localized: "RC File Consecutive Failures", comment: "Setting title"))
        static let rcfileLastFailureTimestamp = SettingKey(
            "rcfile.lastFailureTimestamp", default: 0.0, group: .terminal, policy: .deviceOnly,
            title: String(localized: "RC File Last Failure", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            terminalTypeLocal.erased, terminalTypeRemote.erased, localShellCommand.erased,
            paddingXOverride.erased, paddingYOverride.erased,
            rcfileInProgress.erased, rcfileConsecutiveFailures.erased, rcfileLastFailureTimestamp.erased,
        ]
    }

    enum Gestures {
        static let scrollMode = SettingKey(
            "scrollModeEnabled", default: true, group: .gestures, policy: .localByDefault,
            configKey: "scroll-mode-enabled",
            title: String(localized: "Scroll Mode", comment: "Setting title"))
        static let lineScrollback = SettingKey(
            "lineScrollbackEnabled", default: false, group: .gestures, policy: .localByDefault,
            configKey: "line-scrollback-enabled",
            title: String(localized: "Use Line Scrolling", comment: "Setting title"))
        static let rubberBandScrollback = SettingKey(
            "rubberBandScrollbackEnabled", default: true, group: .gestures, policy: .localByDefault,
            configKey: "rubber-band-scrollback-enabled",
            title: String(localized: "Rubber Band Scrolling", comment: "Setting title"))
        static let twoFingerLongPressDuration = SettingKey(
            "twoFingerLongPressDuration", default: 0.5, group: .gestures,
            configKey: "two-finger-long-press-duration",
            title: String(localized: "Two-Finger Long Press", comment: "Setting title"))
        static let tabExposeGesture = SettingKey(
            "tabExposeGestureEnabled", default: true, group: .gestures,
            configKey: "tab-expose-gesture-enabled",
            title: String(localized: "Pull Down for Tab Exposé", comment: "Setting title"))
        static let swipeBindings = SettingKey<Data?>(
            "swipeGestureBindings", default: nil, group: .gestures,
            title: String(localized: "Swipe Gestures", comment: "Setting title"))
        static let touchScrollModeLegacy = AnySettingDefinition.opaque(
            "touchScrollMode", group: .gestures,
            title: String(localized: "Touch Scroll Mode (legacy)", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            scrollMode.erased, lineScrollback.erased, rubberBandScrollback.erased,
            twoFingerLongPressDuration.erased, tabExposeGesture.erased, swipeBindings.erased,
            touchScrollModeLegacy,
        ]
    }

    enum Prompt {
        static let useStarship = SettingKey(
            "useStarshipPrompt", default: true, group: .prompt, configKey: "use-starship-prompt",
            title: String(localized: "Starship-style Prompt", comment: "Setting title"))
        #if !targetEnvironment(macCatalyst)
        static let starshipTheme = SettingKey(
            "starshipTheme", default: StarshipTheme.catppuccin, group: .prompt, configKey: "starship-theme",
            title: String(localized: "Prompt Theme", comment: "Setting title"))
        #else
        // iOS-only enum; Catalyst keeps the raw value so the key stays registered.
        static let starshipTheme = SettingKey(
            "starshipTheme", default: "catppuccin", group: .prompt, configKey: "starship-theme",
            title: String(localized: "Prompt Theme", comment: "Setting title"))
        #endif
        static let useRightPrompt = SettingKey(
            "useRightPrompt", default: false, group: .prompt, configKey: "use-right-prompt",
            title: String(localized: "Right Prompt", comment: "Setting title"))
        static let useTransientPrompt = SettingKey(
            "useTransientPrompt", default: false, group: .prompt, configKey: "use-transient-prompt",
            title: String(localized: "Transient Prompt", comment: "Setting title"))
        static let addNewline = SettingKey(
            "promptAddNewline", default: true, group: .prompt, configKey: "prompt-add-newline",
            title: String(localized: "Blank Line Before Prompt", comment: "Setting title"))
        static let showGit = SettingKey(
            "showGitInPrompt", default: true, group: .prompt, configKey: "show-git-in-prompt",
            title: String(localized: "Show Git Status", comment: "Setting title"))
        static let customUsername = SettingKey(
            "customUsername", default: "", group: .prompt, configKey: "custom-username",
            title: String(localized: "Username", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            useStarship.erased, starshipTheme.erased, useRightPrompt.erased, useTransientPrompt.erased,
            addNewline.erased, showGit.erased, customUsername.erased,
        ]
    }

    enum Locale {
        static let mode = SettingKey(
            "localeMode", default: LocaleHelper.LocaleMode.auto, group: .locale, configKey: "locale-mode",
            title: String(localized: "Locale", comment: "Setting title"))
        static let custom = SettingKey(
            "customLocale", default: "en_US.UTF-8", group: .locale, configKey: "custom-locale",
            title: String(localized: "Custom Locale", comment: "Setting title"))
        static let clockFormat = SettingKey(
            "clockFormat", default: UserPreferences.ClockFormat.system, group: .locale, configKey: "clock-format",
            title: String(localized: "Clock Format", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [mode.erased, custom.erased, clockFormat.erased]
    }

    enum SessionRestore {
        static let sessionPersistence = SettingKey(
            "sessionPersistenceEnabled", default: true, group: .sessionRestore,
            configKey: "session-persistence-enabled",
            title: String(localized: "Restore Sessions on Launch", comment: "Setting title"))
        static let scrollbackPersistence = SettingKey(
            "scrollbackPersistenceEnabled", default: true, group: .sessionRestore,
            configKey: "scrollback-persistence-enabled",
            title: String(localized: "Persist Scrollback History", comment: "Setting title"))
        static let restorationInProgress = SettingKey(
            "restoration.inProgress", default: false, group: .sessionRestore, policy: .deviceOnly,
            title: String(localized: "Restoration in Progress", comment: "Setting title"))
        static let restorationConsecutiveFailures = SettingKey(
            "restoration.consecutiveFailures", default: 0, group: .sessionRestore, policy: .deviceOnly,
            title: String(localized: "Restoration Consecutive Failures", comment: "Setting title"))
        static let restorationLastFailureTimestamp = SettingKey(
            "restoration.lastFailureTimestamp", default: 0.0, group: .sessionRestore, policy: .deviceOnly,
            title: String(localized: "Restoration Last Failure", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            sessionPersistence.erased, scrollbackPersistence.erased, restorationInProgress.erased,
            restorationConsecutiveFailures.erased, restorationLastFailureTimestamp.erased,
        ]
    }
}
