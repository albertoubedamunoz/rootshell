//
//  ZmxAutoStartCommandView.swift
//  rootshell
//

import SwiftUI

struct ZmxAutoStartCommandView: View {
    @Setting(Settings.Multiplexer.zmxSessionName) private var sessionName
    @Setting(Settings.Multiplexer.zmxCustomCommand) private var customCommand
    @State private var copied = false
    @FocusState private var isEditorFocused: Bool

    private var hasCustomCommand: Bool {
        !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                // Placeholder is a real session name, not "default": zmx has no
                // unnamed default session, so an empty field means "main".
                TextField(SSHConfig.zmxDefaultSessionName, text: $sessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(hasCustomCommand)
                    .foregroundStyle(hasCustomCommand ? .secondary : .primary)
                    .settingRow(Settings.Multiplexer.zmxSessionName)
                    .themedRow()
            } header: {
                Text("Session Name")
            } footer: {
                if hasCustomCommand {
                    Text("Ignored when a custom command is set.")
                } else {
                    Text("The zmx session name used by auto-start. Defaults to \"main\" if empty.")
                }
            }

            Section {
                TextEditor(text: $customCommand)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isEditorFocused)
                    .frame(minHeight: 80)
                    .settingRow(Settings.Multiplexer.zmxCustomCommand)
                    .themedRow()

                if hasCustomCommand {
                    Button("Clear Custom Command", role: .destructive) {
                        customCommand = ""
                    }
                    .themedRow()
                }
            } header: {
                Text("Custom Command")
            } footer: {
                Text("Overrides the entire zmx command, including the session name. Leave empty to use the default.")
            }

            Section {
                HStack(alignment: .top) {
                    Text(SSHConfig.zmxExecCommand)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = SSHConfig.zmxExecCommand
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                }
                .themedRow()
            } header: {
                Text("Effective Command")
            } footer: {
                Text("This command runs when zmx auto-start is enabled on a connection. zmx attaches to the session if it is running, or starts it.")
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("Auto-Start Command")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        ZmxAutoStartCommandView()
    }
}
