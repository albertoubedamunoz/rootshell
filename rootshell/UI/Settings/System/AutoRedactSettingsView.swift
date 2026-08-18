//
//  AutoRedactSettingsView.swift
//  rootshell
//
//  Settings for auto-redact: user strings (names, e-mail addresses) that
//  the terminal renders as bullets so they never appear in screenshots or
//  screen recordings. The list is stored encrypted in the Keychain and is
//  hidden behind a reveal button so opening this screen never shows it.
//

import SwiftUI

struct AutoRedactSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.scenePhase) private var scenePhase
    var manager = RedactionManager.shared

    @State private var newItem: String = ""
    @State private var revealed = false
    @State private var deleteOffsets: IndexSet?

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.isEnabled = $0 }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "eye.slash")
                        Text("Redact Sensitive Text")
                    }
                }
                .themedRow()
            } footer: {
                Text("Matched text is drawn as bullets at the same width, so the layout never shifts. Redaction is display-only: screenshots and recordings are protected while selection and copy still use the real text. Matching ignores letter case. Redaction takes effect once at least one string is added below.")
            }

            if revealed {
                Section {
                    ForEach(manager.items) { item in
                        Text(item.text)
                            .font(.body.monospaced())
                            .themedRow()
                    }
                    .onDelete { offsets in
                        deleteOffsets = offsets
                    }
                } header: {
                    Text("Redacted Strings")
                } footer: {
                    if manager.items.isEmpty {
                        Text("Add the strings that should never show on screen: your name in different spellings, e-mail addresses, hostnames.")
                    }
                }

                Section("Add String") {
                    HStack {
                        TextField("Name or e-mail address", text: $newItem)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { addItem() }

                        Button("Add") {
                            addItem()
                        }
                        .disabled(!RedactionManager.isValidItemText(newItem))
                    }
                    .themedRow()
                }
            } else {
                Section {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "lock")
                        if manager.items.count == 1 {
                            Text("1 redacted string")
                        } else {
                            Text("\(manager.items.count) redacted strings")
                        }
                        Spacer()
                        Button("Reveal") {
                            revealed = true
                        }
                    }
                    .themedRow()
                } footer: {
                    Text("The list stays hidden until revealed, so opening this screen during a screen share never exposes it.")
                }
            }

            Section {
                NavigationLink {
                    KeyboardShortcutsSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "keyboard")
                        Text("Keyboard Shortcuts")
                    }
                }
                .themedRow()
            } footer: {
                Text("Once strings are added, toggle redaction anywhere with ⌃⌘R (customizable), or from the View menu.")
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("Auto-Redact")
        .onAppear {
            // Nothing to protect while the list is empty; start editable.
            if manager.items.isEmpty { revealed = true }
        }
        .onDisappear { revealed = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
        .alert(
            "Remove Redacted String?",
            isPresented: Binding(
                get: { deleteOffsets != nil },
                set: { if !$0 { deleteOffsets = nil } }
            ),
            presenting: deleteOffsets
        ) { offsets in
            Button("Remove", role: .destructive) {
                manager.removeItems(at: offsets)
                deleteOffsets = nil
            }
            Button("Cancel", role: .cancel) {
                deleteOffsets = nil
            }
        } message: { _ in
            Text("The string will no longer be redacted on screen.")
        }
    }

    private var trimmedNewItem: String {
        newItem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addItem() {
        guard manager.addItem(trimmedNewItem) else { return }
        newItem = ""
    }
}
