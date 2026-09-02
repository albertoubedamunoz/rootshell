//
//  SyncedGroupsView.swift
//  rootshell
//
//  One switch per setting group: follow iCloud, or stay on this device.
//  The context menus elsewhere only reach the groups their screens happen to
//  show, so this is the only place that lists every pinnable group.
//

import SwiftUI

/// The groups a pin switch applies to, and how many currently follow iCloud.
enum SyncedGroups {
    static var pinnable: [SettingGroup] {
        SettingsRegistry.shared.groupsInUse.filter { SettingGroupPinActions.hasSyncableKeys($0) }
    }

    static func syncedCount(of groups: [SettingGroup]) -> Int {
        let coordinator = SettingsSyncCoordinator.shared
        return groups.filter { coordinator.pinState(for: $0) != .all }.count
    }
}

struct SyncedGroupsView: View {
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var conflictGroup: SettingGroup?

    private var sections: [(section: SettingsSection, groups: [SettingGroup])] {
        let pinnable = SyncedGroups.pinnable
        return SettingsSection.allCases.compactMap { section in
            let groups = pinnable.filter { $0.section == section }.sorted { $0.title < $1.title }
            return groups.isEmpty ? nil : (section, groups)
        }
    }

    var body: some View {
        let grouped = sections
        let all = grouped.flatMap(\.groups)

        List {
            Section {
                HStack {
                    Text("Following iCloud")
                    Spacer()
                    Text("\(SyncedGroups.syncedCount(of: all)) of \(all.count)")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } footer: {
                Text("Turn a group off to keep its settings on this device. Individual settings can still be pinned from their own rows.")
            }

            if all.isEmpty {
                Section {
                    NoResultsRow(icon: "icloud.slash", message: "No settings groups can sync")
                        .themedRow()
                }
            }

            ForEach(grouped, id: \.section) { entry in
                Section {
                    ForEach(entry.groups, id: \.self) { group in
                        SyncedGroupRow(group: group) { conflictGroup = group }
                    }
                } header: {
                    Text(entry.section.title)
                }
            }
        }
        .themedList()
        .navigationTitle("Synced Groups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu {
                        Button {
                            syncAll(resolution: .adoptCloud)
                        } label: {
                            Label("Use iCloud Values", systemImage: "icloud.and.arrow.down")
                        }
                        Button {
                            syncAll(resolution: .pushLocal)
                        } label: {
                            Label("Send These Values to iCloud", systemImage: "icloud.and.arrow.up")
                        }
                    } label: {
                        Label("Sync All Groups…", systemImage: "icloud")
                    }
                    Button {
                        for group in all { coordinator.setPinned(group: group, true) }
                    } label: {
                        Label("Keep All on This Device", systemImage: "pin")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            Text("Sync This Group Again?"),
            isPresented: Binding(get: { conflictGroup != nil }, set: { if !$0 { conflictGroup = nil } }),
            titleVisibility: .visible,
            presenting: conflictGroup
        ) { group in
            Button {
                coordinator.setPinned(group: group, false, resolution: .adoptCloud)
                conflictGroup = nil
            } label: {
                Text("Use iCloud Values")
            }
            Button {
                coordinator.setPinned(group: group, false, resolution: .pushLocal)
                conflictGroup = nil
            } label: {
                Text("Send These Values to iCloud")
            }
            Button(role: .cancel) { conflictGroup = nil } label: {
                Text("Cancel")
            }
        } message: { group in
            Text(String(localized: "iCloud holds different values for \(group.title). Choose which side wins.",
                        comment: "Unpin conflict dialog message"))
        }
    }

    private func syncAll(resolution: UnpinResolution) {
        for group in SyncedGroups.pinnable where coordinator.pinState(for: group) != .none {
            coordinator.setPinned(group: group, false, resolution: resolution)
        }
    }
}

private struct SyncedGroupRow: View {
    let group: SettingGroup
    /// Called instead of unpinning when iCloud holds values the user must choose between.
    let onConflict: () -> Void

    @State private var coordinator = SettingsSyncCoordinator.shared

    var body: some View {
        let state = coordinator.pinState(for: group)

        Toggle(isOn: Binding(get: { state != .all }, set: { setSyncing($0) })) {
            HStack(spacing: 12) {
                SettingsIcon(systemName: group.systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                    if case .partial(let pinned, let total) = state {
                        Text(String(localized: "\(pinned) of \(total) kept on this device",
                                    comment: "Partially pinned group caption"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                SettingPinTag(group: group)
            }
        }
        .themedRow()
    }

    private func setSyncing(_ syncing: Bool) {
        guard syncing else {
            coordinator.setPinned(group: group, true)
            return
        }
        // Nothing shadowed means no competing iCloud value, so send the local ones up.
        if coordinator.hasCloudShadow(in: group) {
            onConflict()
        } else {
            coordinator.setPinned(group: group, false, resolution: .pushLocal)
        }
    }
}
