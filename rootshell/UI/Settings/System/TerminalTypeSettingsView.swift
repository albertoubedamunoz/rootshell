//
//  TerminalTypeSettingsView.swift
//  rootshell
//
//  Settings view for the TERM value used locally and on remote hosts
//

import SwiftUI

struct TerminalTypeSettingsView: View {
    @AppStorage(TerminalTypeSettings.localKey) private var localTerm: String = TerminalTypeSettings.localFallback
    @AppStorage(TerminalTypeSettings.remoteKey) private var remoteTerm: String = TerminalTypeSettings.fallback

    /// Custom mode is explicit state rather than "the value isn't a preset":
    /// otherwise typing a preset name by hand would collapse the text field
    /// out from under the keyboard.
    @State private var localIsCustom = false
    @State private var remoteIsCustom = false

    var body: some View {
        Form {
            scopeSection(
                title: String(localized: "Local Shell", comment: "Terminal type section: local shell"),
                selection: $localTerm,
                isCustom: $localIsCustom,
                placeholder: TerminalTypeSettings.localFallback,
                footer: localFooter
            )

            scopeSection(
                title: String(localized: "Remote Sessions", comment: "Terminal type section: remote sessions"),
                selection: $remoteTerm,
                isCustom: $remoteIsCustom,
                placeholder: TerminalTypeSettings.fallback,
                footer: String(localized: "Sent as TERM to remote servers via SSH, Mosh, and tssh. Most servers don't have an xterm-ghostty terminfo entry unless you install one, which is why this stays on xterm-256color. Individual connections can override it in the profile editor.", comment: "Terminal type footer: remote sessions")
            )

            Section {
                Text("Applies to sessions opened from now on. Existing tabs keep the value they connected with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Terminal Type")
        .onAppear {
            localIsCustom = !TerminalTypeSettings.presets.contains(localTerm)
            remoteIsCustom = !TerminalTypeSettings.presets.contains(remoteTerm)
        }
    }

    /// The local footer differs by platform because only macOS can resolve the
    /// bundled terminfo entry.
    private var localFooter: String {
        #if targetEnvironment(macCatalyst)
        return String(localized: "Used by the local shell. rootshell bundles the xterm-ghostty terminfo entry and points TERMINFO at it, so the local shell gets full Ghostty capabilities without installing anything.", comment: "Terminal type footer: local shell on macOS")
        #else
        return String(localized: "Used by the local shell. iOS has no terminfo database, so tools fall back to built-in terminal descriptions. A name they don't recognize can leave apps like vim without terminal capabilities.", comment: "Terminal type footer: local shell on iOS")
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func scopeSection(
        title: String,
        selection: Binding<String>,
        isCustom: Binding<Bool>,
        placeholder: String,
        footer: String
    ) -> some View {
        Section {
            // Checkmark-style list instead of a Picker, matching Locale settings.
            // The scope's default leads the list and is labeled, since local and
            // remote have different defaults on macOS.
            ForEach(TerminalTypeSettings.presets(preferring: placeholder), id: \.self) { preset in
                Button {
                    isCustom.wrappedValue = false
                    selection.wrappedValue = preset
                } label: {
                    HStack {
                        Text(preset)
                            .font(.system(.body, design: .monospaced))
                        if preset == placeholder {
                            Text("Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isCustom.wrappedValue && selection.wrappedValue == preset {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }

            Button {
                isCustom.wrappedValue = true
            } label: {
                HStack {
                    Text("Custom")
                    Spacer()
                    if isCustom.wrappedValue {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .themedRow()

            if isCustom.wrappedValue {
                TextField(placeholder, text: selection)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .themedRow()

                if let warning = TerminalTypeSettings.warning(for: selection.wrappedValue) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .themedRow()
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }
}
