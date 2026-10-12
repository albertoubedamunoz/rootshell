//
//  JumpHostListSection.swift
//  rootshell
//
//  Ordered ProxyJump hops for the SSH connection form and the profile
//  editor: numbered rows, an editor sheet per hop, and per-hop tssh relays.
//

import SwiftUI

/// Editable form state for one jump hop.
struct JumpHostDraft: Identifiable, Hashable {
    typealias AuthType = SSHConnectionView.AuthType

    var id = UUID()
    var hostname = ""
    var port = "22"
    var username = ""
    var authMethod: AuthType = .key
    var password = ""
    var savePassword = true
    var selectedKeyID: UUID?
    /// The Keychain already holds this hop's password; used while `password` is empty.
    var hasSavedPassword = false
    var tsshRelay: TSSHRelaySettings?

    init(hostname: String = "", port: String = "22", username: String = "",
         authMethod: AuthType = .key, selectedKeyID: UUID? = nil) {
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.selectedKeyID = selectedKeyID
    }

    /// Loads a saved hop. `hints` supplements the hop's own key resolution hints.
    init(config: SSHConfig.JumpHostConfig, hints: [String: KeyResolutionHint]? = nil) {
        self.init(hostname: config.host, port: "\(config.port)", username: config.username)
        tsshRelay = config.tsshRelay
        switch config.authMethod {
        case .password, .savedPassword:
            authMethod = .password
            hasSavedPassword = SSHPasswordManager.shared.hasPassword(
                host: config.host, port: config.port, username: config.username)
        case .key(let keyID):
            authMethod = .key
            let hint = config.keyResolutionHints?[keyID.uuidString] ?? hints?[keyID.uuidString]
            // Keep an unresolved id so the picker can flag the missing key
            selectedKeyID = SSHKeyManager.shared.resolveKey(id: keyID, hint: hint)?.id ?? keyID
        case .keyboardInteractive:
            authMethod = .keyboardInteractive
        case .none, .unknown:
            authMethod = .none
        }
    }

    /// The hop chain recorded on a history entry.
    static func drafts(from entry: SSHConnectionHistoryEntry) -> [JumpHostDraft] {
        guard entry.hasJumpHost, let host = entry.jumpHost else { return [] }
        let first = HistoryJumpHop(host: host, port: entry.jumpPort ?? 22,
                                   username: entry.jumpUsername ?? entry.username,
                                   authType: entry.jumpAuthType, tsshRelay: entry.tsshRelay)
        return ([first] + (entry.extraJumpHops ?? [])).map {
            JumpHostDraft(config: $0.jumpHostConfig(), hints: entry.keyResolutionHints)
        }
    }

    var trimmedHost: String { hostname.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Blank means 22, matching the profile editor.
    var portNumber: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 22 }
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    var displayName: String {
        guard !trimmedHost.isEmpty else { return String(localized: "New Jump Host") }
        let user = trimmedUsername.isEmpty ? "" : "\(trimmedUsername)@"
        let portNumber = portNumber ?? 22
        return portNumber == 22 ? "\(user)\(trimmedHost)" : "\(user)\(trimmedHost):\(portNumber)"
    }

    var authSummary: String {
        switch authMethod {
        case .key:
            return selectedKeyID.flatMap { SSHKeyManager.shared.findKey(id: $0)?.name } ?? String(localized: "SSH Key")
        case .password:
            return password.isEmpty && hasSavedPassword ? String(localized: "Saved password") : String(localized: "Password")
        case .keyboardInteractive:
            return String(localized: "Keyboard-Interactive")
        case .none:
            return String(localized: "No authentication")
        }
    }

    /// How this hop is recorded in history; the password itself never is.
    var historyAuthType: SSHAuthType {
        switch authMethod {
        case .password:
            return savePassword || hasSavedPassword ? .savedPassword : .password
        case .key:
            let keyID = selectedKeyID ?? UUID()
            return .key(keyID, fingerprint: SSHKeyManager.shared.findKey(id: keyID)?.fingerprint)
        case .keyboardInteractive:
            return .keyboardInteractive
        case .none:
            return .none
        }
    }

    /// History form of this hop, used for every hop after the first.
    func historyHop(relays: Bool) -> HistoryJumpHop {
        HistoryJumpHop(host: trimmedHost, port: portNumber ?? 22, username: trimmedUsername,
                       authType: historyAuthType, tsshRelay: relays ? tsshRelay : nil)
    }

    /// Fields that carry over between forms; ids and secrets never do.
    var carriedFields: [String] {
        [hostname, port, username, authMethod.rawValue, selectedKeyID?.uuidString ?? ""]
    }

    /// Builds the hop. A saved profile (`forConnecting` false) allows an empty
    /// password, prompted on connect, and a key that lives on another device.
    @MainActor
    func build(sshKeyManager: SSHKeyManager, forConnecting: Bool = true) throws -> SSHConfig.JumpHostConfig {
        guard !trimmedHost.isEmpty else {
            throw JumpHostFormSection.BuildError(message: "Jump hostname is required.")
        }
        guard !trimmedUsername.isEmpty else {
            throw JumpHostFormSection.BuildError(message: "Jump username is required.")
        }
        guard let portNumber else {
            throw JumpHostFormSection.BuildError(message: "Invalid jump host port number.")
        }

        let auth: SSHConfig.AuthMethod
        switch authMethod {
        case .password:
            if !password.isEmpty {
                auth = .password(password)
            } else if hasSavedPassword {
                auth = .savedPassword
            } else if forConnecting {
                throw JumpHostFormSection.BuildError(message: "Please enter jump host password")
            } else {
                auth = .password("")
            }
        case .key:
            guard let keyID = selectedKeyID else {
                throw JumpHostFormSection.BuildError(message: "Please select an SSH key for jump host")
            }
            guard !forConnecting || sshKeyManager.findKey(id: keyID) != nil else {
                throw JumpHostFormSection.BuildError(message: "Selected jump host SSH key not found.")
            }
            auth = .key(keyID)
        case .keyboardInteractive:
            auth = .keyboardInteractive
        case .none:
            auth = .none  // Tailscale/WireGuard pre-authenticated
        }

        let fallbackIDs = auth.keyID.map { id in sshKeyManager.defaultKeyIDs.filter { $0 != id } }
        var config = SSHConfig.JumpHostConfig(
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authMethod: auth,
            fallbackKeyIDs: fallbackIDs?.isEmpty == true ? nil : fallbackIDs
        )
        config.tsshRelay = tsshRelay
        return config
    }

    /// Builds every hop and stamps each relay with the hop it was configured for.
    @MainActor
    static func buildChain(_ drafts: [JumpHostDraft], sshKeyManager: SSHKeyManager,
                           forConnecting: Bool = true, relays: Bool) throws -> [SSHConfig.JumpHostConfig] {
        var chain: [SSHConfig.JumpHostConfig] = []
        for (index, draft) in drafts.enumerated() {
            var hop: SSHConfig.JumpHostConfig
            do {
                hop = try draft.build(sshKeyManager: sshKeyManager, forConnecting: forConnecting)
            } catch let error as JumpHostFormSection.BuildError where drafts.count > 1 {
                throw JumpHostFormSection.BuildError(message: "Jump host \(index + 1): \(error.message)")
            }
            if relays, var relay = hop.tsshRelay {
                relay.boundJump = TSSHRelayIdentity(host: hop.host, port: hop.port, username: hop.username)
                try relay.validate(host: hop.host, port: hop.port, username: hop.username,
                                   defaultPortMin: TrzszConfig.preferredUDPPortMin,
                                   defaultPortMax: TrzszConfig.preferredUDPPortMax)
                hop.tsshRelay = relay
            } else {
                hop.tsshRelay = nil
            }
            chain.append(hop)
        }
        var probe = SSHConfig(host: "", username: "", authMethod: .none)
        probe.jumpChain = chain
        try probe.validateRelayChain()
        return chain
    }

    /// Clears relays after the first hop that doesn't relay; each relay is reached through the previous one.
    static func normalizeRelays(_ drafts: inout [JumpHostDraft]) {
        guard let gap = drafts.firstIndex(where: { $0.tsshRelay == nil }) else { return }
        for index in drafts.indices where index > gap {
            drafts[index].tsshRelay = nil
        }
    }
}

/// Numbered jump hop rows plus an add row. Renders as a flat run of rows, so
/// the embedding Section or DisclosureGroup owns the chrome.
struct JumpHostListSection: View {
    enum Mode {
        /// Quick connect: passwords are required and saving is optional.
        case connection
        /// Saved profile: a typed password is always saved; an empty one is prompted on connect.
        case profile
    }

    @Binding var hops: [JumpHostDraft]
    var mode: Mode
    var showsRelay: Bool
    var targetName: String?
    var defaultDraft: () -> JumpHostDraft

    @State private var editing: EditingHop?

    private struct EditingHop: Identifiable {
        let id = UUID()
        let index: Int?
        let draft: JumpHostDraft
    }

    var body: some View {
        ForEach(Array(hops.enumerated()), id: \.element.id) { index, hop in
            Button {
                editing = EditingHop(index: index, draft: hop)
            } label: {
                row(index: index, hop: hop)
            }
            .foregroundStyle(.primary)
            .contextMenu {
                Button("Move Up", systemImage: "arrow.up") { move(index, by: -1) }
                    .disabled(index == 0)
                Button("Move Down", systemImage: "arrow.down") { move(index, by: 1) }
                    .disabled(index == hops.count - 1)
                Button("Remove", systemImage: "trash", role: .destructive) { remove(at: IndexSet(integer: index)) }
            }
            .themedRow()
        }
        .onMove { source, destination in
            hops.move(fromOffsets: source, toOffset: destination)
            normalize()
        }
        .onDelete(perform: remove)

        Button {
            editing = EditingHop(index: nil, draft: defaultDraft())
        } label: {
            Label(hops.isEmpty ? "Add Jump Host" : "Add Another Jump Host", systemImage: "plus.circle.fill")
        }
        .themedRow()
        .sheet(item: $editing) { item in
            let index = item.index ?? hops.count
            JumpHostEditorSheet(
                draft: item.draft,
                hopNumber: index + 1,
                mode: mode,
                showsRelay: showsRelay,
                canRelay: index == 0 || (hops.indices.contains(index - 1) && hops[index - 1].tsshRelay != nil)
            ) { saved in
                if let existing = item.index, hops.indices.contains(existing) {
                    hops[existing] = saved
                } else {
                    hops.append(saved)
                }
                normalize()
            }
        }

        if !hops.isEmpty {
            Text(orderSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .themedRow()
        }
    }

    private func row(index: Int, hop: JumpHostDraft) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(hop.displayName)
                    .lineLimit(1)
                Text(detail(for: hop))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func detail(for hop: JumpHostDraft) -> String {
        guard showsRelay, hop.tsshRelay != nil else { return hop.authSummary }
        return String(localized: "\(hop.authSummary) · UDP relay")
    }

    private var orderSummary: String {
        let names = hops.map { $0.trimmedHost.isEmpty ? $0.displayName : $0.trimmedHost }
            + [targetName].compactMap { $0?.isEmpty == false ? $0 : nil }
        let order = names.joined(separator: " → ")
        return String(localized: "Connects in order: \(order)")
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard hops.indices.contains(index), hops.indices.contains(destination) else { return }
        hops.swapAt(index, destination)
        normalize()
    }

    private func remove(at offsets: IndexSet) {
        hops.remove(atOffsets: offsets)
        normalize()
    }

    private func normalize() {
        if showsRelay { JumpHostDraft.normalizeRelays(&hops) }
    }
}

/// Edits one jump hop; changes apply only on Done.
struct JumpHostEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sshKeyManager = SSHKeyManager.shared

    @State private var draft: JumpHostDraft
    @State private var errorMessage: String?
    let hopNumber: Int
    let mode: JumpHostListSection.Mode
    let showsRelay: Bool
    let canRelay: Bool
    let onSave: (JumpHostDraft) -> Void

    init(draft: JumpHostDraft, hopNumber: Int, mode: JumpHostListSection.Mode,
         showsRelay: Bool, canRelay: Bool, onSave: @escaping (JumpHostDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.hopNumber = hopNumber
        self.mode = mode
        self.showsRelay = showsRelay
        self.canRelay = canRelay
        self.onSave = onSave
    }

    private var forgetAction: (() -> Void)? {
        guard mode == .profile else { return nil }
        return { forgetSavedPassword() }
    }

    private var fieldsSection: some View {
        Section {
            JumpHostFieldStack(
                hostname: $draft.hostname,
                port: $draft.port,
                username: $draft.username,
                authMethod: $draft.authMethod,
                password: $draft.password,
                savePassword: $draft.savePassword,
                selectedKeyID: $draft.selectedKeyID,
                hasSavedPassword: $draft.hasSavedPassword,
                showsSavePasswordToggle: mode == .connection,
                onForgetSavedPassword: forgetAction
            )
        } footer: {
            if mode == .profile && draft.authMethod == .password {
                if draft.hasSavedPassword {
                    Text("Jump host password stored securely in Keychain.")
                } else {
                    Text("A password entered here is saved in the Keychain. Leave it empty to be prompted on connect.")
                }
            }
        }
    }

    private var relaySection: some View {
        Section {
            TSSHRelayForm(settings: $draft.tsshRelay)
                .disabled(!canRelay)
            if canRelay {
                TSSHRelayAdvancedForm(settings: $draft.tsshRelay)
            }
        } header: {
            Text("tssh Relay")
        } footer: {
            if !canRelay {
                Text("Relay through this jump host by first relaying through jump host \(hopNumber - 1).")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                fieldsSection

                if showsRelay {
                    relaySection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Jump Host \(hopNumber)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                }
            }
        }
    }

    private func save() {
        if !canRelay { draft.tsshRelay = nil }
        do {
            let hop = try draft.build(sshKeyManager: sshKeyManager, forConnecting: mode == .connection)
            if showsRelay, var relay = draft.tsshRelay {
                // The user is editing this hop, so it rebinds the relay like a save does.
                relay.boundJump = TSSHRelayIdentity(host: hop.host, port: hop.port, username: hop.username)
                try relay.validate(host: hop.host, port: hop.port, username: hop.username,
                                   defaultPortMin: TrzszConfig.preferredUDPPortMin,
                                   defaultPortMax: TrzszConfig.preferredUDPPortMax)
            }
        } catch {
            errorMessage = (error as? JumpHostFormSection.BuildError)?.message ?? error.localizedDescription
            return
        }
        onSave(draft)
        dismiss()
    }

    private func forgetSavedPassword() {
        guard let port = draft.portNumber else { return }
        let key = SSHSavedPassword.makeConnectionKey(host: draft.trimmedHost, port: port, username: draft.trimmedUsername)
        try? SSHPasswordManager.shared.deletePassword(connectionKey: key)
        draft.hasSavedPassword = false
    }
}
