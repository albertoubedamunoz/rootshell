//
//  SettingsSyncMergeSheet.swift
//  rootshell
//
//  First-enable choice when this device and iCloud both hold settings.
//

import SwiftUI

struct SettingsSyncMergeSheet: View {
    let preview: SettingsMergePreview
    let onDone: () -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        complete(.useCloud)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Use Settings from iCloud", systemImage: "icloud.and.arrow.down")
                                .font(.headline)
                            Text(cloudDetail)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(isWorking)
                    .themedRow()

                    Button {
                        complete(.uploadLocal)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Keep This Device's Settings", systemImage: "icloud.and.arrow.up")
                                .font(.headline)
                            Text("Uploads this device's \(preview.localCount) settings. Other devices adopt them as they sync.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(isWorking)
                    .themedRow()
                } header: {
                    Text("Both Sides Have Settings")
                } footer: {
                    Text("Pinned settings stay as they are on this device either way. Settings only one side knows about are kept.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Sync Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDone() }
                        .disabled(isWorking)
                }
            }
            .overlay {
                if isWorking { ProgressView() }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var cloudDetail: String {
        var parts: [String] = []
        parts.append(String(localized: "\(preview.cloudCount) settings in iCloud", comment: "Merge sheet detail"))
        if preview.overlapping > 0 {
            parts.append(String(localized: "\(preview.overlapping) will change on this device", comment: "Merge sheet detail"))
        }
        if preview.resetCount > 0 {
            parts.append(String(localized: "\(preview.resetCount) will reset to default", comment: "Merge sheet detail"))
        }
        if let date = preview.newestCloudDate {
            parts.append(String(localized: "last updated \(date.formatted(.relative(presentation: .named)))", comment: "Merge sheet detail"))
        }
        return parts.joined(separator: ", ")
    }

    private func complete(_ choice: SettingsMergeChoice) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await CloudKitSyncManager.shared.completeAppSettingsSyncEnable(preview: preview, choice: choice)
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
