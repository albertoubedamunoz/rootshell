//
//  LocalShellSettingsView.swift
//  rootshell
//
//  Settings view for the command launched by local shell tabs
//

import SwiftUI

struct LocalShellSettingsView: View {
    @Setting(Settings.Terminal.localShellCommand) private var command

    /// Custom mode is explicit state rather than "the value isn't a preset":
    /// otherwise typing a preset path by hand would collapse the text field
    /// out from under the keyboard.
    @State private var isCustom = false

    var body: some View {
        Form {
            Section {
                choiceRow(
                    title: String(localized: "Login Shell",
                                  comment: "Local shell option: use the login shell from the passwd database"),
                    isDefault: true,
                    isSelected: !isCustom && command.isEmpty
                ) {
                    isCustom = false
                    command = ""
                }

                ForEach(LocalShellSettings.presets, id: \.self) { preset in
                    choiceRow(title: preset, isDefault: false, isSelected: !isCustom && command == preset) {
                        isCustom = false
                        command = preset
                    }
                }

                Button {
                    isCustom = true
                } label: {
                    HStack {
                        Text("Custom")
                        Spacer()
                        if isCustom {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                if isCustom {
                    TextField("/opt/homebrew/bin/nu --login", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .themedRow()

                    if let warning = LocalShellSettings.warning(for: command) {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                            .themedRow()
                    }
                }
            } header: {
                Text("Shell")
            } footer: {
                Text("Launched for every new local tab. Arguments are supported, and the line is parsed by a shell, so a path containing spaces has to be quoted.")
            }

            Section {
                Text("The command replaces your login shell, so it starts inside the same login environment and SHELL still reports the shell set in your account. Some shells only take login behaviour from an explicit flag, such as --login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()

                Text("Applies to sessions opened from now on. Existing tabs keep the shell they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Local Shell")
        .onAppear {
            isCustom = !command.isEmpty && !LocalShellSettings.presets.contains(command)
        }
    }

    // MARK: - Rows

    /// Checkmark-style list instead of a Picker, matching Terminal Type and Locale.
    private func choiceRow(
        title: String,
        isDefault: Bool,
        isSelected: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button(action: select) {
            HStack {
                Text(title)
                    .font(.system(.body, design: .monospaced))
                if isDefault {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .themedRow()
    }
}
