//
//  ClipboardManagerSettingsView.swift
//  rootshell
//
//  Settings for the in-app clipboard manager: enable/disable (disabling
//  wipes the encrypted store), biometric gate, retention, and manual clear.
//

import SwiftUI

struct ClipboardManagerSettingsView: View {
    var manager = ClipboardHistoryManager.shared

    @State private var showClearConfirmation = false

    private var biometricTypeName: String { SSHKeyAuthManager.shared.biometricTypeName }

    var body: some View {
        List {
            Section {
                SettingToggle(
                    Settings.Clipboard.managerEnabled,
                    isOn: Binding(
                        get: { manager.isEnabled },
                        set: { manager.isEnabled = $0 }
                    ),
                    title: "Clipboard Manager",
                    icon: "list.clipboard"
                )
                .themedRow()
            } footer: {
                Text("Keeps an encrypted history of copies, pastes, and remote clipboard writes made inside the app. Turning this off deletes all history.")
                    .font(.caption)
            }

            if manager.isEnabled {
                Section {
                    if SSHKeyAuthManager.shared.isBiometricAvailable {
                        SettingToggle(
                            Settings.Clipboard.requireBiometric,
                            isOn: Binding(
                                get: { manager.requireBiometric },
                                set: { manager.requireBiometric = $0 }
                            ),
                            title: "Require \(biometricTypeName) to Open",
                            icon: SSHKeyAuthManager.shared.biometricIconName
                        )
                        .themedRow()
                    }

                    Picker(selection: Binding(
                        get: { manager.retention },
                        set: { manager.retention = $0 }
                    )) {
                        ForEach(ClipboardHistoryManager.Retention.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "clock.arrow.circlepath")
                            Text("Keep History")
                        }
                        .settingRow(Settings.Clipboard.retention)
                    }
                    .themedRow()
                } footer: {
                    Text("Pinned entries are kept regardless of the retention period.")
                        .font(.caption)
                }

                Section {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "number")
                        Text("Entries")
                        Spacer()
                        Text("\(manager.entries.count)")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "trash")
                            Text("Clear History Now")
                        }
                    }
                    .themedRow()
                } footer: {
                    Text("History is encrypted on this device and never synced.")
                        .font(.caption)
                }
            }
        }
        .themedList()
        .navigationTitle("Clipboard Manager")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear all clipboard history?",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All History", role: .destructive) {
                manager.clearAll()
            }
        } message: {
            Text("This deletes every entry, including pinned ones.")
        }
    }
}
