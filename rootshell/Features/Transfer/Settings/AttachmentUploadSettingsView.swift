//
//  AttachmentUploadSettingsView.swift
//  rootshell
//
//  Defaults for images and PDFs pasted or dropped into remote sessions.
//

import SwiftUI

struct AttachmentUploadSettingsView: View {
    @Setting(Settings.Transfer.attachmentUploadConfirm) private var confirm
    @Setting(Settings.Transfer.attachmentUploadFormat) private var format
    @Setting(Settings.Transfer.attachmentUploadDirectory) private var directory
    @State private var remembered: [AttachmentUploadPreferences.RememberedDestination] = []

    var body: some View {
        List {
            Section {
                Toggle(isOn: $confirm) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "questionmark.bubble")
                        Text("Ask Before Uploading")
                    }
                    .settingRow(Settings.Transfer.attachmentUploadConfirm)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Prompt", group: .transfer)
            } footer: {
                if confirm {
                    Text("Shows the upload sheet each time you paste or drop an image or PDF into a remote session. The sheet starts with the settings below.")
                } else {
                    Text("Pasted or dropped images and PDFs upload immediately, using the directory and format below.")
                }
            }

            Section {
                Picker(selection: $format) {
                    ForEach(PasteInsertFormat.allCases, id: \.rawValue) { format in
                        Text(format.displayName).tag(format)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "text.insert")
                        Text("Insert As")
                    }
                    .settingRow(Settings.Transfer.attachmentUploadFormat)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Format", group: .transfer)
            } footer: {
                Text(format.detail)
            }

            Section {
                TextField(Settings.Transfer.attachmentUploadDirectory.defaultValue, text: $directory)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .settingRow(Settings.Transfer.attachmentUploadDirectory)
                    .themedRow()
            } header: {
                SettingGroupHeader("Default Directory", group: .transfer)
            } footer: {
                Text("Used on hosts without a remembered directory. Created on the host if it doesn't exist.")
            }

            if !remembered.isEmpty {
                Section {
                    ForEach(remembered) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.host)
                            Text(entry.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .themedRow()
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            AttachmentUploadPreferences.forget(host: remembered[index].host)
                        }
                        reloadRemembered()
                    }

                    Button("Forget All", role: .destructive) {
                        AttachmentUploadPreferences.forgetAll()
                        reloadRemembered()
                    }
                    .themedRow()
                } header: {
                    Text("Remembered Directories")
                } footer: {
                    Text("The last directory used on each host takes priority over the default. Swipe to forget one.")
                }
            }
        }
        .themedList()
        .navigationTitle("Uploads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadRemembered)
    }

    private func reloadRemembered() {
        remembered = AttachmentUploadPreferences.rememberedDestinations()
    }
}
