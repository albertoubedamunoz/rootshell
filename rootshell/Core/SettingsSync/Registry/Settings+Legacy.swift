//
//  Settings+Legacy.swift
//  rootshell
//
//  Orphaned keys still present on long-lived installs (removed features,
//  pre-rename builds) and keys owned by unmerged branches. Registered so the
//  audit stays clean and sync ignores them; nothing in this tree reads them.
//

import Foundation

nonisolated extension Settings {
    enum Legacy {
        /// Written by removed features; safe to delete from defaults.
        static let orphanedNames: [String] = [
            "ai.agent.displayMode",
            "ai.customEndpoint.apiFormat", "ai.customEndpoint.enabled", "ai.customEndpoint.models",
            "ai.customEndpoint.url", "ai.customEndpoint.useResponsesAPI", "ai.customEndpoint.useStreaming",
            "ai.tabSummaries.enabled", "ai.tabSummaries.model",
            "cloudKitSyncProfileExtensions",
            "customKeyboardSelectedLayoutID",
            "hasSeenConnectionTypeMenuHint",
            "keyboardPreferredMode",
            "live_activity_location_accuracy", "live_activity_terminal_preview",
            "location_diary_always_on",
            "restoration.consecutiveSkips",
            "singleFingerAction",
            "trzszSafeDetachOnBackground",
        ]

        // Owned by unmerged branches; those branches should adopt these definitions on merge.
        static let externalDisplayFontSize = SettingKey(
            "externalDisplayFontSize", default: 0.0, group: .font, policy: .localByDefault,
            configKey: "external-display-font-size",
            title: String(localized: "External Display Font Size", comment: "Setting title"))
        static let topTabAgentDetailMode = SettingKey(
            "topTabAgentDetailMode", default: "off", group: .tabs, configKey: "top-tab-agent-detail-mode",
            title: String(localized: "Agent Detail in Tabs", comment: "Setting title"))

        static let all: [AnySettingDefinition] = orphanedNames.map {
            AnySettingDefinition.opaque($0, title: String(localized: "Removed feature (\($0))", comment: "Setting title for an orphaned key"))
        } + [externalDisplayFontSize.erased, topTabAgentDetailMode.erased]
    }
}
