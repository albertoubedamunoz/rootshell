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

    @State private var overlay = ConfigOverlayManager.shared
    @State private var showDeviceOnly = false

    private var pinnedByGroup: [(group: SettingGroup, keys: [AnySettingDefinition])] {
        let pinned = coordinator.pinnedDefinitions().filter { coordinator.pinState(for: $0.name) != .configFile }
        return SettingGroup.allCases.compactMap { group in
            let keys = pinned.filter { $0.group == group }.sorted { $0.title < $1.title }
            return keys.isEmpty ? nil : (group, keys)
        }
    }

    private var fileBound: [AnySettingDefinition] {
        coordinator.configFileKeys.compactMap { registry.definition(for: $0) }.sorted { $0.title < $1.title }
    }

    private var deviceOnly: [AnySettingDefinition] {
        registry.definitions.values.filter { $0.policy == .deviceOnly }.sorted { $0.title < $1.title }
    }

    var body: some View {
        List {
            let sections = pinnedByGroup
            let file = fileBound
            Section {
                HStack {
                    Text("Pinned on this device")
                    Spacer()
                    Text("\(sections.reduce(0) { $0 + $1.keys.count })")
                        .foregroundColor(.secondary)
                }
                .themedRow()
                if !file.isEmpty {
                    HStack {
                        Text("From config file")
                        Spacer()
                        Text("\(file.count)")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
            } footer: {
                Text("Touch and hold a setting (right-click on Mac) and choose Keep on This Device to stop it from following iCloud.")
            }
            if sections.isEmpty && file.isEmpty {
                Section {
                    NoResultsRow(icon: "pin.slash", message: "No settings are pinned to this device")
                        .themedRow()
                }
            }
            if !file.isEmpty {
                Section {
                    ForEach(file) { def in
                        NavigationLink {
                            ConfigFileSettingsView()
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(systemName: "doc.text")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(def.title)
                                    Text(def.display(store.codableValue(def.name)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                SettingPinTag(def)
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("From Config File")
                } footer: {
                    Text("Remove a line from \(overlay.shellDisplayPath) and the setting follows iCloud again.")
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
            Section {
                DisclosureGroup("Always on this device (\(deviceOnly.count))", isExpanded: $showDeviceOnly) {
                    ForEach(deviceOnly) { def in
                        HStack {
                            Text(def.title)
                                .font(.footnote)
                            Spacer()
                            Image(systemName: "icloud.slash")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()
            } footer: {
                Text("Window positions, sync state, caches, and other device-specific values never sync.")
            }
        }
        .themedList()
        .navigationTitle("Pinned Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pinnedByGroup.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            for def in coordinator.pinnedDefinitions() where coordinator.pinState(for: def.name) != .configFile {
                                coordinator.setPinned(def.name, false, resolution: .adoptCloud)
                            }
                        } label: {
                            Label("Use iCloud Values for All", systemImage: "icloud.and.arrow.down")
                        }
                        Button {
                            for def in coordinator.pinnedDefinitions() where coordinator.pinState(for: def.name) != .configFile {
                                coordinator.setPinned(def.name, false, resolution: .pushLocal)
                            }
                        } label: {
                            Label("Send All to iCloud", systemImage: "icloud.and.arrow.up")
                        }
                    } label: {
                        Label("Sync Everything Again", systemImage: "icloud")
                    }
                }
            }
        }
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
