//
//  SettingContextMenu.swift
//  rootshell
//
//  Right-click / long-press actions for keeping a setting or a whole group
//  on this device, and for syncing it again. Same shape as HostAddressCopyMenu:
//  content view + gate + modifier + View extension.
//

import SwiftUI

// MARK: - Menu content

struct SettingPinActions: View {
    let definition: AnySettingDefinition
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var overlay = ConfigOverlayManager.shared
    @State private var syncManager = CloudKitSyncManager.shared

    static func hasActions(for definition: AnySettingDefinition) -> Bool {
        guard definition.isSyncable else { return false }
        if CloudKitSyncManager.shared.isAppSettingsSyncEnabled { return true }
        return SettingsSyncCoordinator.shared.pinState(for: definition.name) == .configFile
            || (definition.configKey != nil && ConfigOverlayManager.shared.fileExists)
    }

    var body: some View {
        switch coordinator.pinState(for: definition.name) {
        case .none:
            if syncManager.isAppSettingsSyncEnabled {
                Button {
                    coordinator.setPinned(definition.name, true)
                } label: {
                    Label("Keep on This Device", systemImage: "pin")
                }
            }
            if definition.configKey != nil, overlay.fileExists {
                Button {
                    overlay.addToFile(definition.name)
                } label: {
                    Label("Add to Config File", systemImage: "doc.badge.plus")
                }
            }
        case .key:
            Menu {
                Button {
                    coordinator.setPinned(definition.name, false, resolution: .adoptCloud)
                } label: {
                    Label(adoptTitle, systemImage: "icloud.and.arrow.down")
                }
                Button {
                    coordinator.setPinned(definition.name, false, resolution: .pushLocal)
                } label: {
                    Label("Send This Value to iCloud", systemImage: "icloud.and.arrow.up")
                }
            } label: {
                Label("Sync Again…", systemImage: "icloud")
            }
        case .group:
            Text(String(localized: "Kept with \(definition.group.title)", comment: "Disabled context menu note"))
            Menu {
                Button {
                    coordinator.setPinned(definition.name, false, resolution: .adoptCloud)
                } label: {
                    Label(adoptTitle, systemImage: "icloud.and.arrow.down")
                }
                Button {
                    coordinator.setPinned(definition.name, false, resolution: .pushLocal)
                } label: {
                    Label("Send This Value to iCloud", systemImage: "icloud.and.arrow.up")
                }
            } label: {
                Label("Sync This Setting Again…", systemImage: "icloud")
            }
        case .configFile:
            if let entry = overlay.boundEntries[definition.name] {
                Text(String(localized: "Set in \(entry.file.lastPathComponent):\(entry.line)", comment: "Disabled context menu note"))
            }
            Button {
                overlay.removeFromFile(definition.name)
            } label: {
                Label("Remove from Config File", systemImage: "doc.badge.minus")
            }
        case .deviceOnly:
            EmptyView()
        }
    }

    private var adoptTitle: String {
        if let shadow = coordinator.shadowValue(for: definition.name) {
            return String(localized: "Use iCloud Value (\(definition.display(shadow.payload)))",
                          comment: "Context menu: adopt the iCloud value, showing it")
        }
        return String(localized: "Use iCloud Value", comment: "Context menu: adopt the iCloud value")
    }
}

struct SettingGroupPinActions: View {
    let group: SettingGroup
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var confirmAdopt = false

    /// Whether the group is pinnable at all, independent of the sync switch.
    static func hasSyncableKeys(_ group: SettingGroup) -> Bool {
        SettingsRegistry.shared.keys(in: group).contains(where: \.isSyncable)
    }

    static func hasActions(for group: SettingGroup) -> Bool {
        CloudKitSyncManager.shared.isAppSettingsSyncEnabled && hasSyncableKeys(group)
    }

    var body: some View {
        switch coordinator.pinState(for: group) {
        case .none, .partial:
            Button {
                coordinator.setPinned(group: group, true)
            } label: {
                Label(String(localized: "Keep \(group.title) on This Device", comment: "Group pin action"), systemImage: "pin")
            }
            if case .partial = coordinator.pinState(for: group) {
                Button {
                    coordinator.setPinned(group: group, false, resolution: .adoptCloud)
                } label: {
                    Label(String(localized: "Sync All of \(group.title) Again", comment: "Group unpin action"), systemImage: "icloud")
                }
            }
        case .all:
            Menu {
                Button {
                    coordinator.setPinned(group: group, false, resolution: .adoptCloud)
                } label: {
                    Label("Use iCloud Values", systemImage: "icloud.and.arrow.down")
                }
                Button {
                    coordinator.setPinned(group: group, false, resolution: .pushLocal)
                } label: {
                    Label("Send These Values to iCloud", systemImage: "icloud.and.arrow.up")
                }
            } label: {
                Label(String(localized: "Sync \(group.title) Again…", comment: "Group unpin menu"), systemImage: "icloud")
            }
        }
    }
}

// MARK: - Modifiers

private struct SettingContextMenuModifier: ViewModifier {
    let definition: AnySettingDefinition
    @State private var syncManager = CloudKitSyncManager.shared
    @State private var overlay = ConfigOverlayManager.shared
    @State private var coordinator = SettingsSyncCoordinator.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        // Observed reads so the gate re-evaluates when sync or the file changes.
        let syncOn = syncManager.isAppSettingsSyncEnabled
        let fileBound = coordinator.pinState(for: definition.name) == .configFile
        let fileAvailable = definition.configKey != nil && overlay.fileExists
        if definition.isSyncable, syncOn || fileBound || fileAvailable {
            content.contextMenu { SettingPinActions(definition: definition) }
        } else {
            content
        }
    }
}

private struct SettingGroupContextMenuModifier: ViewModifier {
    let group: SettingGroup
    @State private var syncManager = CloudKitSyncManager.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if syncManager.isAppSettingsSyncEnabled, SettingGroupPinActions.hasActions(for: group) {
            content.contextMenu { SettingGroupPinActions(group: group) }
        } else {
            content
        }
    }
}

extension View {
    /// Pin actions for one setting. Attach to the whole row, after `.themedRow()`.
    func settingContextMenu(_ definition: AnySettingDefinition) -> some View {
        modifier(SettingContextMenuModifier(definition: definition))
    }

    func settingContextMenu<V: SettingValue>(_ key: SettingKey<V>) -> some View {
        modifier(SettingContextMenuModifier(definition: key.erased))
    }

    /// Pin actions for a whole group. Attach to the row that opens the group's screen.
    func settingGroupContextMenu(_ group: SettingGroup) -> some View {
        modifier(SettingGroupContextMenuModifier(group: group))
    }

    /// Label-level convenience: appends the tag and attaches the menu to the label.
    func settingRow<V: SettingValue>(_ key: SettingKey<V>) -> some View {
        HStack(spacing: 6) {
            self
            SettingPinTag(key.erased)
        }
        .modifier(SettingContextMenuModifier(definition: key.erased))
    }
}
