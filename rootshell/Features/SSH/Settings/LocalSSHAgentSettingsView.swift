#if targetEnvironment(macCatalyst) && STANDALONE

import SwiftUI
import UIKit

struct LocalSSHAgentSettingsView: View {
    @State private var manager = LocalSSHAgentManager.shared
    @State private var policyStore = LocalAgentPolicyStore.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared
    @State private var copiedExport = false

    var body: some View {
        let ephemeralIdentities = manager.exposedEphemeralIdentities

        List {
            Section {
                Toggle(isOn: configBinding(\.enabled)) {
                    Text(String(localized: "Enable Local SSH Agent", comment: "Local SSH agent settings enable toggle"))
                }
                .themedRow()

                if let socketPath = manager.socketPath {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Socket", comment: "Local SSH agent settings socket path label"))
                            .font(.headline)
                        Text(socketPath)
                            .font(.caption.monospaced())
                        Button {
                            copyExport(socketPath)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: copiedExport ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                                    .symbolEffect(.bounce, value: copiedExport)
                                Text(
                                    copiedExport
                                        ? String(localized: "Copied", comment: "Local SSH agent export copied button")
                                        : String(localized: "Copy export SSH_AUTH_SOCK", comment: "Local SSH agent copy export button")
                                )
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(copiedExport ? .green : .secondary)
                        .help(String(localized: "Copy export SSH_AUTH_SOCK", comment: "Local SSH agent copy export help"))
                    }
                    .themedRow()
                }
            } header: {
                Text(String(localized: "Agent", comment: "Local SSH agent settings section header"))
            }

            Section {
                Picker(
                    String(localized: "Signature Approval", comment: "Local SSH agent signature approval picker"),
                    selection: approvalModeBinding
                ) {
                    ForEach(SSHAgentConfig.ApprovalMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .themedRow()

                keyExposurePicker
            } header: {
                Text(String(localized: "Keys", comment: "Local SSH agent keys section header"))
            }

            Section {
                if policyStore.rules.isEmpty {
                    Text(String(localized: "No client rules yet.", comment: "Local SSH agent empty client rules text"))
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(policyStore.rules) { rule in
                        NavigationLink {
                            LocalAgentClientRuleView(rule: rule)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.displayName)
                                Text(rule.policy.displayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                }

                Button(String(localized: "Reset Session Approvals", comment: "Local SSH agent reset session approvals button")) {
                    manager.resetSessionApprovals()
                }
                .themedRow()
            } header: {
                Text(String(localized: "Clients", comment: "Local SSH agent clients section header"))
            }

            Section {
                if ephemeralIdentities.isEmpty {
                    Text(String(localized: "No ephemeral identities.", comment: "Local SSH agent empty ephemeral identities text"))
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(ephemeralIdentities, id: \.self) { identity in
                        Label(identity, systemImage: "clock")
                            .themedRow()
                    }
                }
            } header: {
                Text(String(localized: "ssh-add Identities", comment: "Local SSH agent ephemeral identities section header"))
            }

            Section {
                NavigationLink {
                    LocalAgentAuditLogView()
                } label: {
                    HStack {
                        Label(
                            String(localized: "Audit Log", comment: "Local SSH agent audit log navigation label"),
                            systemImage: "list.bullet.rectangle"
                        )
                        Spacer()
                        Text("\(LocalAgentAuditLog.shared.events.count)")
                            .foregroundColor(.secondary)
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Local SSH Agent", comment: "Local SSH agent settings title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var keyExposurePicker: some View {
        Toggle(isOn: exposeAllKeysBinding) {
            Text(String(localized: "Expose All SSH Keys", comment: "Local SSH agent expose all keys toggle"))
        }
        .themedRow()

        if !policyStore.config.exposedKeyIDs.isEmpty {
            ForEach(keyManager.savedKeys) { key in
                Toggle(isOn: exposedKeyBinding(key.id)) {
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
    }

    private var approvalModeBinding: Binding<SSHAgentConfig.ApprovalMode> {
        Binding(
            get: { policyStore.config.signatureApprovalMode },
            set: { newValue in
                var config = policyStore.config
                config.signatureApprovalMode = newValue
                policyStore.config = config
            }
        )
    }

    private var exposeAllKeysBinding: Binding<Bool> {
        Binding(
            get: { policyStore.config.exposedKeyIDs.isEmpty },
            set: { exposeAll in
                var config = policyStore.config
                config.exposedKeyIDs = exposeAll ? [] : Set(keyManager.savedKeys.map(\.id))
                policyStore.config = config
            }
        )
    }

    private func exposedKeyBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { policyStore.config.exposedKeyIDs.contains(id) },
            set: { enabled in
                var config = policyStore.config
                if enabled {
                    config.exposedKeyIDs.insert(id)
                } else {
                    config.exposedKeyIDs.remove(id)
                }
                policyStore.config = config
            }
        )
    }

    private func configBinding(_ keyPath: WritableKeyPath<LocalAgentConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { policyStore.config[keyPath: keyPath] },
            set: { newValue in
                var config = policyStore.config
                config[keyPath: keyPath] = newValue
                policyStore.config = config
            }
        )
    }

    private func copyExport(_ socketPath: String) {
        let export = "export SSH_AUTH_SOCK=\(socketPath)"
        UIPasteboard.general.string = export
        withAnimation(.snappy(duration: 0.2)) {
            copiedExport = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy(duration: 0.2)) {
                copiedExport = false
            }
        }
    }
}

#endif
