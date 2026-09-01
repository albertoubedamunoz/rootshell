//
//  PinnedSettingsView.swift
//  rootshell
//
//  Settings kept on this device, grouped by pin group, with unpin actions.
//

import SwiftUI

struct PinnedSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var store = SettingsStore.shared

    private let registry = SettingsRegistry.shared

    private var pinnedByGroup: [(group: SettingGroup, keys: [AnySettingDefinition])] {
        let pinned = coordinator.pinnedDefinitions()
        return SettingGroup.allCases.compactMap { group in
            let keys = pinned.filter { $0.group == group }.sorted { $0.title < $1.title }
            return keys.isEmpty ? nil : (group, keys)
        }
    }

    var body: some View {
        List {
            let sections = pinnedByGroup
            if sections.isEmpty {
                Section {
                    NoResultsRow(icon: "pin.slash", message: "No settings are pinned to this device")
                        .themedRow()
                } footer: {
                    Text("Touch and hold a setting (right-click on Mac) and choose Keep on This Device to stop it from following iCloud.")
                }
            }
            ForEach(sections, id: \.group) { section in
                Section {
                    ForEach(section.keys) { def in
                        PinnedSettingRow(definition: def)
                    }
                } header: {
                    HStack {
                        Text(section.group.title)
                        SettingPinTag(group: section.group)
                    }
                } footer: {
                    if coordinator.pinState(for: section.group) == .all {
                        Text("The whole group is pinned. Swipe or use the context menu to sync a setting again.")
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Pinned Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PinnedSettingRow: View {
    let definition: AnySettingDefinition
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: definition.group.systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.title)
                Text(definition.display(store.codableValue(definition.name)))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            SettingPinTag(definition)
        }
        .themedRow()
        .settingContextMenu(definition)
        .swipeActions(edge: .trailing) {
            if coordinator.pinState(for: definition.name) == .key {
                Button {
                    coordinator.setPinned(definition.name, false, resolution: .adoptCloud)
                } label: {
                    Label("Sync Again", systemImage: "icloud")
                }
                .tint(.blue)
            }
        }
    }
}
