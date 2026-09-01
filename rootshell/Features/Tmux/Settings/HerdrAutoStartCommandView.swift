//
//  HerdrAutoStartCommandView.swift
//  rootshell
//
//  Configures the herdr command used by per-connection auto-start: the
//  session name, an optional full command override, and a read-only
//  preview of the effective command.
//

import SwiftUI

struct HerdrAutoStartCommandView: View {
    @Setting(Settings.Multiplexer.herdrSessionName) private var sessionName
    @Setting(Settings.Multiplexer.herdrCustomCommand) private var customCommand
    @State private var copied = false
    @FocusState private var isEditorFocused: Bool

    private var hasCustomCommand: Bool {
        !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("default", text: $sessionName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(hasCustomCommand)
                    .foregroundStyle(hasCustomCommand ? .secondary : .primary)
                    .themedRow()
            } header: {
                Text("Session Name")
            } footer: {
                if hasCustomCommand {
                    Text("Ignored when a custom command is set.")
                } else {
                    Text("The herdr session name used by auto-start. Leave empty for herdr's default session. Names may use letters, numbers, '.', '_' and '-' (\".\" and \"..\" alone are reserved).")
                }
            }

            Section {
                TextEditor(text: $customCommand)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isEditorFocused)
                    .frame(minHeight: 80)
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
                Text("Overrides the entire herdr command, including the session name. Leave empty to use the default.")
            }

            Section {
                HStack(alignment: .top) {
                    Text(SSHConfig.herdrExecCommand)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = SSHConfig.herdrExecCommand
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
                Text("This command runs when herdr auto-start is enabled on a connection. herdr attaches to the session if it is running, or starts it.")
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
        HerdrAutoStartCommandView()
    }
}
