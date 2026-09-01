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
    @State private var mergePreview: SettingsMergePreview?
    @State private var errorMessage: String?

    var body: some View {
        Toggle("Sync Settings", isOn: Binding(
            get: { syncManager.isAppSettingsSyncEnabled },
            set: { setEnabled($0) }
        ))
        .disabled(isBusy)
        .themedRow()
        .sheet(item: $mergePreview) { preview in
            SettingsSyncMergeSheet(preview: preview) { mergePreview = nil }
        }

        if syncManager.isAppSettingsSyncEnabled {
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
        errorMessage = nil
        Task {
            defer { isBusy = false }
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
