//
//  SettingsSyncRows.swift
//  rootshell
//
//  "Sync Settings" toggle and its sub-rows inside the iCloud Sync screen.
//

import SwiftUI

struct SettingsSyncRows: View {
    @State private var syncManager = CloudKitSyncManager.shared
    @State private var coordinator = SettingsSyncCoordinator.shared
    @State private var isBusy = false
    /// What the switch shows while the enable/disable is in flight.
    @State private var pendingValue: Bool?
    @State private var mergePreview: SettingsMergePreview?
    @State private var errorMessage: String?

    var body: some View {
        // Read in body so observation re-renders this row when the manager flips the flag.
        let isEnabled = syncManager.isAppSettingsSyncEnabled
        let shown = pendingValue ?? isEnabled

        Toggle(isOn: Binding(get: { shown }, set: { setEnabled($0) })) {
            HStack(spacing: 8) {
                Text("Sync Settings")
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking iCloud…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .disabled(isBusy)
        .themedRow()
        .sheet(item: $mergePreview) { preview in
            SettingsSyncMergeSheet(preview: preview) { mergePreview = nil }
        }

        if isEnabled {
            let pinnable = SyncedGroups.pinnable
            NavigationLink {
                SyncedGroupsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "square.grid.2x2")
                    Text("Synced Groups")
                    Spacer()
                    Text("\(SyncedGroups.syncedCount(of: pinnable)) of \(pinnable.count)")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
            .themedRow()

            NavigationLink {
                PinnedSettingsView()
            } label: {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "pin")
                    Text("Pinned Settings")
                    Spacer()
                    Text("\(coordinator.pinnedDefinitions().count)")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
            .themedRow()
        }

        if syncManager.settingsSyncPausedForAccountChange {
            Text("Settings sync was paused because the Apple Account changed. Turn it on again to choose which settings to keep.")
                .font(.footnote)
                .foregroundColor(.orange)
                .themedRow()
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(.red)
                .themedRow()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        isBusy = true
        pendingValue = enabled
        errorMessage = nil
        Task {
            defer {
                isBusy = false
                pendingValue = nil
            }
            do {
                switch try await syncManager.setAppSettingsSyncEnabled(enabled) {
                case .enabled:
                    break
                case .needsMergeChoice(let preview):
                    mergePreview = preview
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension SettingsMergePreview: Identifiable {
    var id: String { "\(cloudCount)-\(localCount)-\(newestCloudDate?.timeIntervalSince1970 ?? 0)" }
}
