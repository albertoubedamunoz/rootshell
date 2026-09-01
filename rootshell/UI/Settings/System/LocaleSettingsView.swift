//
//  LocaleSettingsView.swift
//  rootshell
//
//  Settings view for configuring locale forwarding to remote servers
//

import SwiftUI

struct LocaleSettingsView: View {
    @Setting(Settings.Locale.mode) private var localeMode
    @Setting(Settings.Locale.custom) private var customLocale
    @FocusState private var isTextFieldFocused: Bool

    private var mode: LocaleHelper.LocaleMode { localeMode }

    var body: some View {
        Form {
            Section {
                // Checkmark-style list instead of Picker to avoid the "Mode" label
                Button {
                    localeMode = .auto
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Automatic")
                            Text(LocaleHelper.posixLocale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == .auto {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                Button {
                    localeMode = .none
                } label: {
                    HStack {
                        Text("Don't Send")
                        Spacer()
                        if mode == .none {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                Button {
                    localeMode = .custom
                } label: {
                    HStack {
                        Text("Custom")
                        Spacer()
                        if mode == .custom {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            } footer: {
                switch mode {
                case .auto:
                    if let devicePair = LocaleHelper.unsupportedDevicePair {
                        Text("Uses your device's language and region settings. Sent as LANG to remote servers via SSH, Mosh, and tssh. Your device reports \(devicePair), which servers don't support, so \(LocaleHelper.posixLocale) will be sent instead.")
                    } else {
                        Text("Uses your device's language and region settings. Sent as LANG to remote servers via SSH, Mosh, and tssh.")
                    }
                case .none:
                    Text("No locale will be sent. Remote servers will use their own default locale.")
                case .custom:
                    Text("The specified locale will be sent as LANG to remote servers. Make sure the locale is installed on the server.")
                }
            }

            if mode == .custom {
                Section {
                    HStack(spacing: 6) {
                        TextField("en_US.UTF-8", text: $customLocale)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .focused($isTextFieldFocused)
                        SettingPinTag(Settings.Locale.custom.erased)
                    }
                    .themedRow()
                } footer: {
                    if let warning = LocaleHelper.validate(customLocale).warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
            #if !targetEnvironment(macCatalyst)
            Section {
                SettingToggle(Settings.Keyboard.forceASCIIKeyboard, title: "Force ASCII Keyboard") { _ in
                    NotificationCenter.default.post(name: .forceASCIIKeyboardChanged, object: nil)
                }
                .themedRow()
            } footer: {
                Text("Restricts the software keyboard to ASCII layout, preventing input methods from substituting terminal characters like | and ~.")
            }
            #endif
        }
        .themedList()
        .navigationTitle("Locale")
        .toolbar { SettingsScreenPinMenu(groups: [.locale]) }
    }
}
