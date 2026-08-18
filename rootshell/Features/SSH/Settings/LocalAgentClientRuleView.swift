#if targetEnvironment(macCatalyst) && STANDALONE

import SwiftUI

struct LocalAgentClientRuleView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var policyStore = LocalAgentPolicyStore.shared
    @State private var auditLog = LocalAgentAuditLog.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared
    @State private var rule: LocalAgentClientRule
    @State private var manualFingerprint = ""

    init(rule: LocalAgentClientRule) {
        _rule = State(initialValue: rule)
    }

    var body: some View {
        List {
            Section {
                Picker(
                    String(localized: "Policy", comment: "Local SSH agent client rule policy picker"),
                    selection: policyBinding
                ) {
                    ForEach(LocalAgentClientRule.Policy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .themedRow()

                Toggle(isOn: allExposedKeysBinding) {
                    Text(String(localized: "All Exposed Keys", comment: "Local SSH agent client rule all keys toggle"))
                }
                .themedRow()

                if rule.allowedKeyIDs != nil {
                    ForEach(keyManager.savedKeys) { key in
                        Toggle(isOn: allowedKeyBinding(key.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name)
                                Text(key.formattedFingerprint)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                }
            } header: {
                Text(String(localized: "Access", comment: "Local SSH agent client rule access section"))
            }

            Section {
                Toggle(isOn: requireSessionBindBinding) {
                    Text(String(localized: "Require Destination Binding", comment: "Local SSH agent client rule require session-bind toggle"))
                }
                .themedRow()

                if rule.pinnedHostKeyFingerprints.isEmpty {
                    Text(String(localized: "No pinned destinations.", comment: "Local SSH agent client rule no pinned destinations text"))
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(Array(rule.pinnedHostKeyFingerprints).sorted(), id: \.self) { fingerprint in
                        HStack {
                            Text(fingerprint)
                                .font(.caption.monospaced())
                            Spacer()
                            Button(role: .destructive) {
                                rule.pinnedHostKeyFingerprints.remove(fingerprint)
                                saveRule()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .themedRow()
                    }
                }

                if !auditLog.seenDestinationFingerprints.isEmpty {
                    Menu {
                        ForEach(auditLog.seenDestinationFingerprints, id: \.self) { fingerprint in
                            Button(fingerprint) {
                                rule.pinnedHostKeyFingerprints.insert(fingerprint)
                                saveRule()
                            }
                        }
                    } label: {
                        Label(
                            String(localized: "Add Seen Destination", comment: "Local SSH agent client rule add seen destination menu"),
                            systemImage: "plus"
                        )
                    }
                    .themedRow()
                }

                HStack {
                    TextField(
                        String(localized: "SHA256 fingerprint", comment: "Local SSH agent client rule manual destination fingerprint placeholder"),
                        text: $manualFingerprint
                    )
                    Button {
                        let value = manualFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        rule.pinnedHostKeyFingerprints.insert(value)
                        manualFingerprint = ""
                        saveRule()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .themedRow()
            } header: {
                Text(String(localized: "Destinations", comment: "Local SSH agent client rule destinations section"))
            }

            Section {
                LabeledContent(String(localized: "Name", comment: "Local SSH agent client rule identity name label"), value: rule.displayName)
                    .themedRow()
                LabeledContent(String(localized: "Path", comment: "Local SSH agent client rule identity path label"), value: rule.lastPath)
                    .themedRow()
                LabeledContent(String(localized: "Identity", comment: "Local SSH agent client rule identity key label"), value: rule.key.description)
                    .themedRow()
                if let lastUsed = rule.lastUsedAt {
                    LabeledContent(
                        String(localized: "Last Used", comment: "Local SSH agent client rule last used label"),
                        value: lastUsed.formatted(date: .abbreviated, time: .shortened)
                    )
                    .themedRow()
                }
            } header: {
                Text(String(localized: "Client", comment: "Local SSH agent client rule identity section"))
            }

            Section {
                Button(role: .destructive) {
                    policyStore.deleteRule(id: rule.id)
                    dismiss()
                } label: {
                    Text(String(localized: "Delete Rule", comment: "Local SSH agent client rule delete button"))
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(rule.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var policyBinding: Binding<LocalAgentClientRule.Policy> {
        Binding(
            get: { rule.policy },
            set: { newValue in
                rule.policy = newValue
                saveRule()
            }
        )
    }

    private var requireSessionBindBinding: Binding<Bool> {
        Binding(
            get: { rule.requireSessionBind },
            set: { newValue in
                rule.requireSessionBind = newValue
                saveRule()
            }
        )
    }

    private var allExposedKeysBinding: Binding<Bool> {
        Binding(
            get: { rule.allowedKeyIDs == nil },
            set: { allKeys in
                rule.allowedKeyIDs = allKeys ? nil : Set(keyManager.savedKeys.map(\.id))
                saveRule()
            }
        )
    }

    private func allowedKeyBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { rule.allowedKeyIDs?.contains(id) ?? true },
            set: { enabled in
                var ids = rule.allowedKeyIDs ?? Set(keyManager.savedKeys.map(\.id))
                if enabled {
                    ids.insert(id)
                } else {
                    ids.remove(id)
                }
                rule.allowedKeyIDs = ids
                saveRule()
            }
        )
    }

    private func saveRule() {
        policyStore.updateRule(rule)
    }
}

#endif
