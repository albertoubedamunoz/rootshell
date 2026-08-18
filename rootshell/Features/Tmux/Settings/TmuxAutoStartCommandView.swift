//
//  TmuxAutoStartCommandView.swift
//  rootshell
//
//  Configures the tmux command used by per-connection auto-start: the
//  session name, an optional full command override, and a read-only
//  preview of the effective command.
//

import SwiftUI

struct TmuxAutoStartCommandView: View {
    @AppStorage("tmuxSessionName") private var sessionName = ""
    @AppStorage("tmuxCustomCommand") private var customCommand = ""
    @State private var copied = false
    @FocusState private var isEditorFocused: Bool

    private var hasCustomCommand: Bool {
        !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("main", text: $sessionName)
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
                    Text("The tmux session name used by auto-start. Defaults to \"main\" if empty.")
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
                Text("Overrides the entire tmux command, including the session name. Leave empty to use the default.")
            }

            Section {
                HStack(alignment: .top) {
                    Text(SSHConfig.tmuxExecCommand)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = SSHConfig.tmuxExecCommand
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
                Text("This command runs when tmux auto-start is enabled on a connection.")
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
        TmuxAutoStartCommandView()
    }
}
