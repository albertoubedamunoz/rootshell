//
//  SSHCopyIDView.swift
//  rootshell
//
//  Sheet-based UI for installing an SSH key on a remote server (ssh-copy-id).
//  Presented from SSHKeyDetailView's "Install on Server" button.
//

import SwiftUI
import os.log

/// A keyboard-interactive challenge awaiting the user's answers.
private struct PendingCopyIDChallenge: Identifiable {
    let id = UUID()
    let challenge: KeyboardInteractiveChallenge
    let continuation: CheckedContinuation<[String]?, Never>
}

/// Tracks whether the sheet is still on screen and able to answer a prompt. Both
/// the host key and keyboard-interactive delegates invoke their callbacks from
/// tasks they spawn on the NIO event loop, so those callbacks inherit neither the
/// install task's cancellation nor the view's lifetime. Sharing this box by
/// reference lets a request that arrives after dismissal fail fast instead of
/// parking until the login timeout.
private final class CopyIDPromptGate {
    var isActive = true
}

struct SSHCopyIDView: View {
    /// How to authenticate the bootstrap connection. Deliberately independent of
    /// the key being installed: this screen exists because that key is *not* on
    /// the server yet, so the first login is normally a password.
    private enum AuthChoice: Hashable {
        case password
        case savedPassword
        case key
    }

    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    /// The key to install
    let key: SSHKey

    // Server configuration
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""

    // Authentication
    @State private var password = ""
    @State private var authChoice: AuthChoice = .password
    /// Set once the user picks a method themselves, so later edits to the server
    /// fields stop re-deriving the default choice under them.
    @State private var authChoiceUserOverridden = false
    /// Key used to authenticate, not the key being installed.
    @State private var selectedAuthKeyID: UUID?
    @State private var pendingChallenge: PendingCopyIDChallenge?
    @State private var promptGate = CopyIDPromptGate()
    @State private var installTask: Task<Void, Never>?

    // Options
    @State private var force = false
    @State private var dryRun = false

    // Operation state
    @State private var isExecuting = false
    @State private var result: SSHCopyIDResult?
    @State private var error: String?
    @State private var logEntries: [String] = []

    // Host key validation
    @State private var showHostKeyAlert = false
    @State private var showHostKeyChangedAlert = false
    @State private var hostKeyMessage = ""
    @State private var hostKeyContinuation: CheckedContinuation<HostKeyValidationResult, Never>?

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHCopyIDView")

    var body: some View {
        NavigationStack {
            Form {
                // Server section
                Section("Server") {
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("hostname or IP", text: $host)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                    }
                    .themedRow()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("22", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    .themedRow()
                    HStack {
                        Text("Username")
                        Spacer()
                        TextField("user", text: $username)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                    }
                    .themedRow()
                }

                // Authentication section
                Section {
                    Picker("Method", selection: authChoiceBinding) {
                        Text("Password").tag(AuthChoice.password)
                        if savedPasswordAvailable {
                            Text("Saved Password").tag(AuthChoice.savedPassword)
                        }
                        if !SSHKeyManager.shared.savedKeys.isEmpty {
                            Text("SSH Key").tag(AuthChoice.key)
                        }
                    }
                    .themedRow()

                    switch authChoice {
                    case .password:
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .themedRow()

                    case .savedPassword:
                        HStack {
                            Text("Saved for")
                            Spacer()
                            Text(verbatim: "\(effectiveUsername)@\(host)")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()

                    case .key:
                        Picker("Key", selection: $selectedAuthKeyID) {
                            ForEach(SSHKeyManager.shared.savedKeys) { savedKey in
                                Text(savedKey.name).tag(Optional(savedKey.id))
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(authFooterText)
                }

                // Key to install
                Section("Key to Install") {
                    HStack {
                        Label(key.name, systemImage: "key")
                        Spacer()
                        Text(key.keyType.shortName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                            .cornerRadius(4)
                    }
                    .themedRow()
                }

                // Options
                Section("Options") {
                    Toggle("Force (skip duplicate check)", isOn: $force)
                        .themedRow()
                    Toggle("Dry Run (preview only)", isOn: $dryRun)
                        .themedRow()
                }

                // Action button
                Section {
                    Button(action: executeInstall) {
                        HStack {
                            Spacer()
                            if isExecuting {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Installing...")
                            } else {
                                Image(systemName: dryRun ? "eye" : "arrow.up.doc")
                                    .padding(.trailing, 4)
                                Text(dryRun ? String(localized: "Preview Installation", comment: "SSH copy ID: dry run button") : String(localized: "Install Key", comment: "SSH copy ID: install button"))
                            }
                            Spacer()
                        }
                    }
                    .disabled(host.isEmpty || isExecuting || (authChoice == .key && selectedAuthKeyID == nil))
                    .themedRow()
                }

                // Result section
                if let result {
                    Section("Result") {
                        if !result.installedKeys.isEmpty {
                            ForEach(result.installedKeys, id: \.self) { name in
                                Label(name, systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .themedRow()
                            }
                        }
                        if !result.skippedKeys.isEmpty {
                            ForEach(result.skippedKeys, id: \.self) { name in
                                Label("\(name) (already installed)", systemImage: "minus.circle")
                                    .foregroundColor(.secondary)
                                    .themedRow()
                            }
                        }
                    }
                }

                // Error section
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .themedRow()
                    }
                }

                // Log section
                if !logEntries.isEmpty {
                    Section("Operation Log") {
                        ForEach(Array(logEntries.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .themedRow()
                        }
                    }
                }
            }
            .themedList()
            .navigationTitle("Install Key on Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelInstall()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if result != nil && error == nil {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .alert("New SSH Host", isPresented: $showHostKeyAlert) {
                Button("Accept") { respondToHostKey(.accept) }
                Button("Accept Once") { respondToHostKey(.acceptOnce) }
                Button("Reject", role: .cancel) { respondToHostKey(.reject) }
            } message: {
                Text(hostKeyMessage)
            }
            .alert("Host Key Changed", isPresented: $showHostKeyChangedAlert) {
                Button("Accept Anyway", role: .destructive) { respondToHostKey(.accept) }
                Button("Reject", role: .cancel) { respondToHostKey(.reject) }
            } message: {
                Text(hostKeyMessage)
            }
            .sheet(item: $pendingChallenge) { entry in
                KeyboardInteractivePromptView(
                    challenge: entry.challenge,
                    sessionLabel: entry.challenge.sessionName.isEmpty
                        ? "\(effectiveUsername)@\(host)"
                        : entry.challenge.sessionName,
                    onSubmit: { respondToChallenge($0) },
                    onCancel: { respondToChallenge(nil) }
                )
                // A swipe-dismiss must still resume the continuation, so force
                // an explicit Submit/Cancel.
                .interactiveDismissDisabled()
                .themedSubSheet(sheetThemeColors)
            }
            .onChange(of: host) { _, _ in syncDefaultAuthChoice() }
            .onChange(of: port) { _, _ in syncDefaultAuthChoice() }
            .onChange(of: username) { _, _ in syncDefaultAuthChoice() }
            .onAppear {
                // Pre-fill username from NSUserName
                if username.isEmpty {
                    username = UserPreferences.effectiveUsername
                }
                if selectedAuthKeyID == nil {
                    selectedAuthKeyID = SSHKeyManager.shared.primaryDefaultKeyID
                        ?? SSHKeyManager.shared.savedKeys.first?.id
                }
                syncDefaultAuthChoice()
            }
        }
        // While connecting, Cancel must be the only way out: a swipe-dismiss
        // would leave the operation running with nothing to answer a host key or
        // keyboard-interactive prompt.
        .interactiveDismissDisabled(isExecuting)
    }

    // MARK: - Computed Properties

    private var effectiveUsername: String {
        username.isEmpty ? UserPreferences.effectiveUsername : username
    }

    /// Whether a password is saved for this exact host/port/user. Unlike a
    /// default key, this is evidence that the app already knows this server.
    private var savedPasswordAvailable: Bool {
        guard !host.isEmpty else { return false }
        return SSHPasswordManager.shared.hasPassword(
            host: host,
            port: Int(port) ?? 22,
            username: effectiveUsername
        )
    }

    /// Wraps the picker so a programmatic default is never mistaken for a
    /// deliberate choice by the user.
    private var authChoiceBinding: Binding<AuthChoice> {
        Binding(
            get: { authChoice },
            set: {
                authChoice = $0
                authChoiceUserOverridden = true
            }
        )
    }

    private var authFooterText: String {
        switch authChoice {
        case .password:
            return String(localized: "Password for the first login. The key being installed is not on the server yet.", comment: "SSH copy ID: password auth footer")
        case .savedPassword:
            return String(localized: "Using the password saved for this server.", comment: "SSH copy ID: saved password auth footer")
        case .key:
            return String(localized: "Authenticate with a key the server already accepts, then install the new key.", comment: "SSH copy ID: key auth footer")
        }
    }

    // MARK: - Actions

    /// Re-derive the default method after a server field changes. Never selects
    /// a key: a default key says nothing about whether *this* host accepts it.
    private func syncDefaultAuthChoice() {
        // A saved password that no longer matches the edited server must not
        // stick, even if the user chose it explicitly.
        if authChoice == .savedPassword && !savedPasswordAvailable {
            authChoice = .password
            return
        }
        guard !authChoiceUserOverridden else { return }
        authChoice = savedPasswordAvailable ? .savedPassword : .password
    }

    /// Resume the displayed keyboard-interactive challenge. nil = cancelled.
    private func respondToChallenge(_ responses: [String]?) {
        pendingChallenge?.continuation.resume(returning: responses)
        pendingChallenge = nil
    }

    /// Resume the displayed host key prompt.
    private func respondToHostKey(_ result: HostKeyValidationResult) {
        hostKeyContinuation?.resume(returning: result)
        hostKeyContinuation = nil
    }

    /// Tear down an in-flight install before the sheet goes away: answer every
    /// on-screen prompt, then close the gate so a request still in flight is
    /// refused rather than left waiting on a view that no longer exists.
    private func cancelInstall() {
        respondToChallenge(nil)
        respondToHostKey(.reject)
        showHostKeyAlert = false
        showHostKeyChangedAlert = false
        promptGate.isActive = false
        installTask?.cancel()
        installTask = nil
    }

    private func handleKeyboardInteractiveChallenge(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        guard promptGate.isActive else { return nil }
        return await withCheckedContinuation { continuation in
            pendingChallenge = PendingCopyIDChallenge(challenge: challenge, continuation: continuation)
        }
    }

    private func executeInstall() {
        guard !host.isEmpty else { return }

        isExecuting = true
        error = nil
        result = nil
        logEntries = []

        let portNum = Int(port) ?? 22
        let user = username.isEmpty ? UserPreferences.effectiveUsername : username

        promptGate.isActive = true
        installTask = Task { @MainActor in
            do {
                // Build SSH config for connection authentication
                let sshConfig = buildSSHConfig(host: host, port: portNum, username: user)

                // Resolve saved password if needed
                let resolvedConfig: SSHConfig
                do {
                    resolvedConfig = try await sshConfig.resolvedConfig()
                } catch {
                    self.error = "Authentication error: \(error.localizedDescription)"
                    isExecuting = false
                    installTask = nil
                    return
                }

                // Build the command
                let command = SSHCopyIDParsedCommand(
                    keyIDs: [key.id],
                    force: force,
                    dryRun: dryRun
                )

                // Create and execute
                let copyID = SSHCopyID(command: command, config: resolvedConfig)

                copyID.onProgress = { [self] message in
                    self.logEntries.append(message)
                }

                copyID.onLog = { [self] message in
                    self.logEntries.append(message)
                }

                copyID.onHostKeyValidation = { [self] request in
                    await self.handleHostKeyValidation(request)
                }

                copyID.onKeyboardInteractiveChallenge = { [self] challenge in
                    await self.handleKeyboardInteractiveChallenge(challenge)
                }

                let copyResult = try await copyID.execute()
                self.result = copyResult
                self.logEntries = copyResult.log

            } catch let copyError as SSHCopyIDError where copyError.isAuthenticationRelated {
                self.error = copyError.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }

            isExecuting = false
            installTask = nil
        }
    }

    private func buildSSHConfig(host: String, port: Int, username: String) -> SSHConfig {
        switch authChoice {
        case .savedPassword:
            return SSHConfig(
                host: host,
                port: port,
                username: username,
                authMethod: .savedPassword
            )

        case .key:
            if let keyID = selectedAuthKeyID {
                return SSHConfig(
                    host: host,
                    port: port,
                    username: username,
                    keyID: keyID
                )
            }
            return SSHConfig(
                host: host,
                port: port,
                username: username,
                password: password
            )

        case .password:
            return SSHConfig(
                host: host,
                port: port,
                username: username,
                password: password
            )
        }
    }

    private func handleHostKeyValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        // The delegate calls this from a task it spawns, so the sheet may already
        // be gone. Refuse rather than prompting with no UI to answer.
        guard promptGate.isActive else { return .reject }
        return await withCheckedContinuation { continuation in
            hostKeyMessage = request.message
            hostKeyContinuation = continuation

            if request.isKeyChanged {
                showHostKeyChangedAlert = true
            } else {
                showHostKeyAlert = true
            }
        }
    }
}
