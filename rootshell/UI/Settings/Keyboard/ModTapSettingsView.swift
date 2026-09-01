//
//  ModTapSettingsView.swift
//  rootshell
//
//  Settings UI for configuring mod-tap key behavior.
//

import SwiftUI

private extension ModTapSourceKey {
    static var selectableCases: [ModTapSourceKey] {
        #if targetEnvironment(macCatalyst)
        return allCases.filter { $0 != .capsLock }
        #else
        return allCases
        #endif
    }

    static func selectableCases(in category: Category) -> [ModTapSourceKey] {
        selectableCases.filter { $0.category == category }
    }
}

// MARK: - Settings Label (for SettingsView row)

struct ModTapSettingsLabel: View {
    var manager = ModTapManager.shared

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: "hand.tap")
            Text("Mod-Tap Keys")
            Spacer()
            let count = manager.activeRuleCount
            Text(count > 0 ? String(localized: "\(count) active", comment: "Mod-tap: number of active rules") : String(localized: "Off", comment: "Mod-tap: no active rules"))
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
    }
}

// MARK: - Main Settings View

struct ModTapSettingsView: View {
    var manager = ModTapManager.shared

    /// First source key not already used by an existing rule
    private var nextAvailableSourceKey: ModTapSourceKey? {
        let usedKeys = Set(manager.rules.map(\.sourceKey))
        return ModTapSourceKey.selectableCases.first { !usedKeys.contains($0) }
    }

    var body: some View {
        List {
            if manager.rules.isEmpty {
                Section {
                    #if !targetEnvironment(macCatalyst)
                    Button {
                        manager.rules.append(.capsLockEscCtrl)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Caps Lock \u{2192} Esc / Ctrl")
                                .font(.body)
                            Text("Tap for Escape, hold for Control")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .themedRow()
                    #endif

                    Button {
                        manager.rules.append(.escapeEscCtrl)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Escape \u{2192} Esc / Ctrl")
                                .font(.body)
                            Text("For users who remapped Caps Lock to Escape at the OS level")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Quick Setup")
                } footer: {
                    Text("Mod-tap keys perform one action on tap and another on hold. Choose a preset or add a custom rule.")
                }
            } else {
                Section {
                    ForEach(manager.rules) { rule in
                        NavigationLink {
                            ModTapRuleDetailView(ruleID: rule.id, manager: manager)
                        } label: {
                            ModTapRuleRow(rule: rule)
                        }
                        .themedRow()
                    }
                    .onDelete { indexSet in
                        manager.rules.remove(atOffsets: indexSet)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Rules")
                        SettingPinTag(Settings.Keybinds.modTapRules.erased)
                    }
                }

                if let sourceKey = nextAvailableSourceKey {
                    Section {
                        Button {
                            manager.rules.append(ModTapRule(
                                sourceKey: sourceKey,
                                tapAction: sourceKey.defaultTapAction,
                                holdAction: .control
                            ))
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                        .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Mod-Tap Keys")
        .toolbar { SettingsScreenPinMenu(groups: [.keybinds]) }
    }
}

// MARK: - Rule Row

struct ModTapRuleRow: View {
    let rule: ModTapRule

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.sourceKey.displayName)
                    .font(.body)
                HStack(spacing: 12) {
                    Label(rule.tapAction.displayName, systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(rule.holdAction.displayName, systemImage: "hand.point.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !rule.isEnabled {
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Rule Detail View

/// Uses a local @State copy instead of @Binding into the array.
/// This avoids stale-index crashes when the rule is deleted while the
/// detail view is still on the navigation stack (e.g., during dismiss animation).
struct ModTapRuleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let ruleID: UUID
    var manager: ModTapManager
    @State private var rule: ModTapRule

    init(ruleID: UUID, manager: ModTapManager) {
        self.ruleID = ruleID
        self.manager = manager
        let fallbackSourceKey: ModTapSourceKey = {
            #if targetEnvironment(macCatalyst)
            return .escape
            #else
            return .capsLock
            #endif
        }()
        let initial = manager.rules.first { $0.id == ruleID }
            ?? ModTapRule(sourceKey: fallbackSourceKey, tapAction: .sendKey(.escape), holdAction: .control)
        self._rule = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $rule.isEnabled)
                    .themedRow()
            }

            Section {
                NavigationLink {
                    ModTapSourceKeyPickerView(
                        selection: $rule.sourceKey,
                        unavailableKeys: usedByOtherRules
                    )
                } label: {
                    HStack {
                        Text("Key")
                        Spacer()
                        Text(rule.sourceKey.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            } header: {
                Text("Source Key")
            }

            Section {
                NavigationLink {
                    ModTapActionPickerView(selection: $rule.tapAction)
                } label: {
                    HStack {
                        Text("Action")
                        Spacer()
                        Text(rule.tapAction.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            } header: {
                Text("Tap Action")
            }

            Section {
                Picker("Modifier", selection: $rule.holdAction) {
                    ForEach(ModTapModifier.allCases, id: \.self) { mod in
                        Text(mod.displayName).tag(mod)
                    }
                }
                .pickerStyle(.menu)
                .themedRow()
            } header: {
                Text("Hold Action")
            }

            Section {
                Picker("Threshold", selection: $rule.holdThresholdMs) {
                    Text("Fast (150ms)").tag(150)
                    Text("Default (200ms)").tag(200)
                    Text("Relaxed (250ms)").tag(250)
                    Text("Slow (300ms)").tag(300)
                }
                .pickerStyle(.menu)
                .themedRow()
            } header: {
                Text("Hold Threshold")
            } footer: {
                Text("How long to hold before the modifier activates. Lower values feel faster but may trigger on normal typing.")
            }

            if rule.sourceKey == .capsLock {
                Section {
                    Label("Caps Lock LED", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .themedRow()
                } footer: {
                    Text("The Caps Lock keyboard light will still toggle when pressed. To avoid this, remap Caps Lock to another key (e.g. Escape) in Settings \u{2192} Keyboard \u{2192} Hardware Keyboard \u{2192} Modifier Keys, then create a mod-tap rule for that key instead.")
                }
            }

            Section {
                Button(role: .destructive) {
                    dismiss()
                    manager.rules.removeAll { $0.id == ruleID }
                } label: {
                    Text("Delete Rule")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(rule.sourceKey.displayName)
        .onChange(of: rule) { _, newValue in
            // Sync local edits back to the manager's array
            if let index = manager.rules.firstIndex(where: { $0.id == ruleID }) {
                manager.rules[index] = newValue
            }
        }
    }

    /// Source keys used by other rules (for filtering in the picker)
    private var usedByOtherRules: Set<ModTapSourceKey> {
        Set(manager.rules.filter { $0.id != ruleID }.map(\.sourceKey))
    }
}

// MARK: - Source Key Picker

struct ModTapSourceKeyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ModTapSourceKey
    let unavailableKeys: Set<ModTapSourceKey>

    var body: some View {
        List {
            ForEach(ModTapSourceKey.Category.allCases, id: \.self) { category in
                let keys = ModTapSourceKey.selectableCases(in: category)
                if !keys.isEmpty {
                    Section(category.displayName) {
                        ForEach(keys, id: \.self) { key in
                            let isUnavailable = unavailableKeys.contains(key)
                            Button {
                                selection = key
                                dismiss()
                            } label: {
                                HStack {
                                    Text(key.displayName)
                                        .foregroundStyle(isUnavailable ? .tertiary : .primary)
                                    Spacer()
                                    if selection == key {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .disabled(isUnavailable)
                            .themedRow()
                        }
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Source Key")
    }
}

// MARK: - Tap Action Picker

struct ModTapActionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ModTapAction

    var body: some View {
        List {
            Section {
                row(action: .none, icon: "minus.circle", label: "None")
            }

            ForEach(ModTapKeyAction.Category.allCases, id: \.self) { category in
                Section(category.displayName) {
                    ForEach(ModTapKeyAction.cases(in: category), id: \.self) { key in
                        row(action: .sendKey(key), icon: key.symbolName, label: key.displayName)
                    }
                }
            }

            Section("Advanced") {
                NavigationLink {
                    CustomSequenceEditView(selection: $selection)
                } label: {
                    Label("Custom Sequence\u{2026}", systemImage: "character.cursor.ibeam")
                }
                .themedRow()

                NavigationLink {
                    InputSourcePickerView(selection: $selection)
                } label: {
                    HStack {
                        Label("Switch Input Source\u{2026}", systemImage: "globe")
                        Spacer()
                        if case .switchInputSource = selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Tap Action")
    }

    private func row(action: ModTapAction, icon: String, label: String) -> some View {
        Button {
            selection = action
            dismiss()
        } label: {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == action {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .themedRow()
    }
}

// MARK: - Custom Sequence Editor

struct CustomSequenceEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: ModTapAction
    @State private var text: String = ""
    @State private var didExplicitSave = false

    var body: some View {
        Form {
            Section {
                TextField("Sequence", text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(saveAndDismiss)
                    .themedRow()
            } footer: {
                Text("Enter the text to send when the key is tapped. For example, type a single character or a short string.")
            }

            Section {
                Button("Save", action: saveAndDismiss)
                    .disabled(text.isEmpty)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Custom Sequence")
        .onAppear {
            if case .sendSequence(let seq) = selection {
                text = seq
            }
        }
        .onDisappear {
            // Back navigation should preserve edits, but should not trigger extra pops.
            if !didExplicitSave {
                commitDraft()
            }
        }
    }

    private func saveAndDismiss() {
        guard !text.isEmpty else { return }
        didExplicitSave = true
        commitDraft()
        // Pop only this editor to avoid skipping two navigation levels.
        dismiss()
    }

    private func commitDraft() {
        guard !text.isEmpty else { return }
        selection = .sendSequence(text)
    }
}
