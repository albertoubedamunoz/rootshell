//
//  CloudSyncSettingsView.swift
//  rootshell
//
//  Settings view for iCloud sync configuration
//

import SwiftUI

struct CloudSyncSettingsView: View {
    @State private var syncManager = CloudKitSyncManager.shared
    @State private var showingEnableAlert = false
    @State private var showingDisableAlert = false
    @State private var isEnabling = false
    @State private var errorMessage: String?
    @State private var capturedError: CloudKitSyncError?

    var body: some View {
        List {
            Section {
                Toggle("Enable iCloud Sync", isOn: Binding(
                    get: { syncManager.isSyncEnabled },
                    set: { newValue in
                        if newValue {
                            showingEnableAlert = true
                        } else {
                            showingDisableAlert = true
                        }
                    }
                ))
                .disabled(isEnabling)
                .themedRow()

                if syncManager.isSyncEnabled {
                    Toggle("Sync SSH History", isOn: Binding(
                        get: { syncManager.isHistorySyncEnabled },
                        set: { syncManager.setHistorySyncEnabled($0) }
                    ))
                    .themedRow()

                    Toggle("Sync Known Hosts", isOn: Binding(
                        get: { syncManager.isKnownHostsSyncEnabled },
                        set: { syncManager.setKnownHostsSyncEnabled($0) }
                    ))
                    .themedRow()

                    Toggle("Sync Connection Profiles", isOn: Binding(
                        get: { syncManager.isProfilesSyncEnabled },
                        set: { syncManager.setProfilesSyncEnabled($0) }
                    ))
                    .themedRow()
                }
            } header: {
                Text("iCloud Sync")
            } footer: {
                Text("Sync your SSH connection history, known hosts, and connection profiles across your devices using iCloud.")
            }

            if syncManager.isSyncEnabled {
                Section("Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        if syncManager.syncState.isActive {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.trailing, 4)
                        }
                        Text(syncManager.syncState.description)
                            .foregroundColor(syncManager.syncState.hasError ? .red : .secondary)
                    }
                    .themedRow()

                    if let lastSync = syncManager.lastSyncDate {
                        HStack {
                            Text("Last Synced")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }

                    if syncManager.pendingChangesCount > 0 {
                        HStack {
                            Text("Pending Changes")
                            Spacer()
                            Text("\(syncManager.pendingChangesCount)")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }

                    Button("Sync Now") {
                        Task {
                            try? await syncManager.syncNow()
                        }
                    }
                    .disabled(syncManager.syncState.isActive)
                    .themedRow()
                }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .themedRow()

                    if let syncError = capturedError, let suggestion = syncError.recoverySuggestion {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }
                }
            }

            Section {
                Text("iCloud sync uses your iCloud account to keep data synchronized across all your devices signed into the same Apple Account.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .themedRow()

                Text("SSH private keys are synced separately using iCloud Keychain and are controlled per-key in SSH Keys settings.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("iCloud Sync")
        .alert("Enable iCloud Sync?", isPresented: $showingEnableAlert) {
            Button("Enable") {
                enableSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your SSH connection history and known hosts will be synced to iCloud and available on your other devices.")
        }
        .alert("Disable iCloud Sync?", isPresented: $showingDisableAlert) {
            Button("Disable", role: .destructive) {
                disableSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Syncing will stop. Your local data will be preserved, but changes will no longer sync across devices.")
        }
    }

    private func enableSync() {
        isEnabling = true
        errorMessage = nil
        capturedError = nil

        Task {
            do {
                try await syncManager.setEnabled(true)
            } catch let error as CloudKitSyncError {
                errorMessage = error.localizedDescription
                capturedError = error
            } catch {
                errorMessage = error.localizedDescription
                capturedError = nil
            }
            isEnabling = false
        }
    }

    private func disableSync() {
        Task {
            try? await syncManager.setEnabled(false)
        }
    }
}

#Preview {
    NavigationView {
        CloudSyncSettingsView()
    }
}
