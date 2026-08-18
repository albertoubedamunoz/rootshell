//
//  ExternalSSHAgentsView.swift
//  rootshell (Catalyst, Standalone)
//
//  Manage external OpenSSH agents (1Password, Secretive, ssh-agent) and
//  import their identities as tracked SSH keys. Discovery offers the
//  1Password well-known socket, IdentityAgent entries from ~/.ssh/config,
//  and $SSH_AUTH_SOCK so the user rarely has to type a path.
//

#if targetEnvironment(macCatalyst) && STANDALONE

import SwiftUI
import Crypto

struct ExternalSSHAgentsView: View {
    @State private var registry = ExternalSSHAgentRegistry.shared
    @State private var discovered: [(agent: ExternalSSHAgent, reachable: Bool)] = []
    @State private var isDiscovering = false
    @State private var manualPath = ""
    @State private var manualPathError: String?

    var body: some View {
        List {
            configuredSection
            discoveredSection
            manualSection
        }
        .themedList()
        .navigationTitle(String(localized: "SSH Agents", comment: "External SSH agents settings title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isDiscovering = true
        await registry.refreshReachability()
        discovered = await registry.discoverCandidates()
        isDiscovering = false
    }

    // MARK: - Configured agents

    @ViewBuilder
    private var configuredSection: some View {
        Section {
            if registry.agents.isEmpty {
                Text(String(localized: "No agents configured.", comment: "External SSH agents empty list text"))
                    .foregroundColor(.secondary)
                    .themedRow()
            } else {
                ForEach(registry.agents) { agent in
                    NavigationLink {
                        ExternalAgentIdentitiesView(agent: agent)
                    } label: {
                        agentRow(agent)
                    }
                    .themedRow()
                }
                .onDelete { offsets in
                    for offset in offsets {
                        registry.remove(id: registry.agents[offset].id)
                    }
                }
            }
        } header: {
            Text(String(localized: "Agents", comment: "External SSH agents configured section header"))
        } footer: {
            Text(String(
                localized: "Keys imported from an agent stay on this Mac and never leave the agent. The agent may ask you to approve each signature.",
                comment: "External SSH agents section footer"
            ))
        }
    }

    private func agentRow(_ agent: ExternalSSHAgent) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(reachabilityColor(agent))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                Text(agent.socketPath)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(agent.source.label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func reachabilityColor(_ agent: ExternalSSHAgent) -> Color {
        switch registry.reachability[agent.id] {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    // MARK: - Discovered candidates

    @ViewBuilder
    private var discoveredSection: some View {
        Section {
            if isDiscovering {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "Looking for agents…", comment: "External SSH agents discovery in progress"))
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } else if discovered.isEmpty {
                Text(String(localized: "No new agents found.", comment: "External SSH agents discovery empty text"))
                    .foregroundColor(.secondary)
                    .themedRow()
            } else {
                ForEach(discovered, id: \.agent.id) { candidate in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(candidate.reachable ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.agent.name)
                            Text(candidate.agent.socketPath)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(String(localized: "Add", comment: "External SSH agents add discovered agent button")) {
                            registry.add(candidate.agent)
                            Task { await refresh() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .themedRow()
                }
            }
        } header: {
            Text(String(localized: "Discovered", comment: "External SSH agents discovered section header"))
        } footer: {
            Text(String(
                localized: "Found via 1Password, IdentityAgent entries in ~/.ssh/config, and SSH_AUTH_SOCK.",
                comment: "External SSH agents discovered section footer"
            ))
        }
    }

    // MARK: - Manual entry

    @ViewBuilder
    private var manualSection: some View {
        Section {
            TextField(
                String(localized: "/path/to/agent.sock", comment: "External SSH agents manual path placeholder"),
                text: $manualPath
            )
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .themedRow()

            if let manualPathError {
                Text(manualPathError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            Button(String(localized: "Add Agent", comment: "External SSH agents manual add button")) {
                addManualAgent()
            }
            .disabled(manualPath.trimmingCharacters(in: .whitespaces).isEmpty)
            .themedRow()
        } header: {
            Text(String(localized: "Add Manually", comment: "External SSH agents manual section header"))
        }
    }

    private func addManualAgent() {
        let path = (manualPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        manualPathError = nil

        // Validate by doing a real list round-trip so typos fail here, not
        // at connect time.
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                do {
                    _ = try ExternalSSHAgentClient(socketPath: path).listIdentities()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let error {
                manualPathError = error
                return
            }
            registry.add(ExternalSSHAgent(
                name: (path as NSString).lastPathComponent,
                socketPath: path,
                source: .manual
            ))
            manualPath = ""
            await refresh()
        }
    }
}

// MARK: - Identities

struct ExternalAgentIdentitiesView: View {
    let agent: ExternalSSHAgent

    @ObservedObject private var keyManager = SSHKeyManager.shared
    @State private var identities: [ExternalAgentIdentity] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var importError: String?

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(String(localized: "Asking the agent for identities…", comment: "External agent identities loading text"))
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                } else if let loadError {
                    Text(loadError)
                        .foregroundColor(.red)
                        .themedRow()
                } else if identities.isEmpty {
                    Text(String(localized: "The agent has no identities.", comment: "External agent identities empty text"))
                        .foregroundColor(.secondary)
                        .themedRow()
                } else {
                    ForEach(identities) { identity in
                        identityRow(identity)
                            .themedRow()
                    }
                }
            } header: {
                Text(agent.name)
            } footer: {
                if let importError {
                    Text(importError).foregroundColor(.red)
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Agent Identities", comment: "External agent identities title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadIdentities()
        }
    }

    private func loadIdentities() async {
        isLoading = true
        loadError = nil
        let socketPath = agent.socketPath
        do {
            identities = try await Task.detached(priority: .userInitiated) {
                try ExternalSSHAgentClient(socketPath: socketPath).listIdentities()
            }.value
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    @ViewBuilder
    private func identityRow(_ identity: ExternalAgentIdentity) -> some View {
        let unsupportedReason = unsupportedReason(for: identity)
        let alreadyImported = isImported(identity)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.comment.isEmpty
                    ? String(localized: "Unnamed key", comment: "External agent identity with no comment")
                    : identity.comment)
                Text(identity.algorithm)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("SHA256:\(fingerprintHex(identity.publicKeyBlob).prefix(16))…")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let unsupportedReason {
                Text(unsupportedReason)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if alreadyImported {
                Label(
                    String(localized: "Imported", comment: "External agent identity already imported"),
                    systemImage: "checkmark.circle.fill"
                )
                .labelStyle(.iconOnly)
                .foregroundColor(.green)
            } else {
                Button(String(localized: "Import", comment: "External agent identity import button")) {
                    importIdentity(identity)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func unsupportedReason(for identity: ExternalAgentIdentity) -> String? {
        if identity.isCertificate {
            return String(localized: "Certificates aren't supported yet", comment: "External agent identity unsupported: certificate")
        }
        if identity.isSecurityKey {
            return String(localized: "Security keys aren't supported yet", comment: "External agent identity unsupported: sk- key")
        }
        switch identity.algorithm {
        case "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa":
            return nil
        default:
            return String(localized: "Unsupported key type", comment: "External agent identity unsupported: unknown algorithm")
        }
    }

    private func isImported(_ identity: ExternalAgentIdentity) -> Bool {
        keyManager.savedKeys.contains { $0.publicKeyBlob == identity.publicKeyBlob }
    }

    private func importIdentity(_ identity: ExternalAgentIdentity) {
        importError = nil
        var key = SSHKey(
            name: identity.comment.isEmpty ? "\(agent.name) key" : identity.comment,
            keyType: .externalAgent,
            fingerprint: fingerprintHex(identity.publicKeyBlob),
            storageLevel: .deviceOnly
        )
        key.publicKeyBlob = identity.publicKeyBlob
        key.externalAgentInfo = ExternalAgentKeyInfo(
            agentID: agent.id,
            socketPath: agent.socketPath,
            comment: identity.comment,
            algorithm: identity.algorithm,
            addedDate: Date()
        )
        do {
            try keyManager.saveExternalAgentReference(key)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func fingerprintHex(_ blob: Data) -> String {
        SHA256.hash(data: blob).compactMap { String(format: "%02x", $0) }.joined()
    }
}

#endif
