//
//  OpenInFolderRecentsStore.swift
//  rootshell
//

import Foundation

/// Persists Open in Folder history and the last placement through the
/// settings registry.
@MainActor
enum OpenInFolderRecentsStore {
    static func recents(for targetKey: String) -> [String] {
        OpenInFolderRecents.decode(SettingsStore.shared.get(Settings.Tabs.openInFolderRecents)).paths(for: targetKey)
    }

    static func record(_ path: String, targetKey: String) {
        var recents = OpenInFolderRecents.decode(SettingsStore.shared.get(Settings.Tabs.openInFolderRecents))
        recents.record(path, target: targetKey)
        SettingsStore.shared.set(Settings.Tabs.openInFolderRecents, recents.encoded())
    }

    static func remove(_ path: String, targetKey: String) {
        var recents = OpenInFolderRecents.decode(SettingsStore.shared.get(Settings.Tabs.openInFolderRecents))
        recents.remove(path, target: targetKey)
        SettingsStore.shared.set(Settings.Tabs.openInFolderRecents, recents.encoded())
    }

    static var placement: OpenInFolderPlacement {
        get { SettingsStore.shared.get(Settings.Tabs.openInFolderPlacement) }
        set { SettingsStore.shared.set(Settings.Tabs.openInFolderPlacement, newValue) }
    }
}
