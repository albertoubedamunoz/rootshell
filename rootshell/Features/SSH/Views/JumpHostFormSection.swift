//
//  JumpHostFormSection.swift
//  rootshell
//
//  Shared jump-host form fields + config builder, extracted from
//  SSHConnectionView so other connection forms (e.g. Screen Sharing)
//  can offer the same jump-host UX without duplicating it. The SSH
//  forms list several hops through JumpHostListSection; this section
//  is the single-hop toggle + field stack.
//

import SwiftUI

/// The jump-host field stack behind an enable toggle. Renders as a
/// flat run of rows (Form/DisclosureGroup hosts flatten the builder
/// body), so embedding contexts control the surrounding chrome.
struct JumpHostFormSection: View {
    typealias AuthType = SSHConnectionView.AuthType

    @Binding var useJumpHost: Bool
    @Binding var hostname: String
    @Binding var port: String
    @Binding var username: String
    @Binding var authMethod: AuthType
    @Binding var password: String
    @Binding var savePassword: Bool
    @Binding var selectedKeyID: UUID?

    var body: some View {
        Toggle("Connect via Jump Host", isOn: $useJumpHost.animation())

        if useJumpHost {
            JumpHostFieldStack(
                hostname: $hostname,
                port: $port,
                username: $username,
                authMethod: $authMethod,
                password: $password,
                savePassword: $savePassword,
                selectedKeyID: $selectedKeyID
            )
        }
    }
}

/// Hostname/port/username, the auth-method picker, and the password/key
/// sub-fields for one jump hop.
struct JumpHostFieldStack: View {
    typealias AuthType = SSHConnectionView.AuthType

    @Binding var hostname: String
    @Binding var port: String
    @Binding var username: String
    @Binding var authMethod: AuthType
    @Binding var password: String
    @Binding var savePassword: Bool
    @Binding var selectedKeyID: UUID?
    var hasSavedPassword: Binding<Bool> = .constant(false)
    var showsSavePasswordToggle = true
    /// Offers "Remove Saved Password" when set.
    var onForgetSavedPassword: (() -> Void)?

    @ObservedObject private var sshKeyManager = SSHKeyManager.shared
    @State private var isChangingPassword = false

    // Keyboard-interactive is surfaced as a toggle under the Password
    // method rather than a fourth segment (matches the target form's
    // segmented picker).
    private var authMethodPickerCases: [AuthType] {
        AuthType.allCases.filter { $0 != .keyboardInteractive }
    }
    private var methodSelection: Binding<AuthType> {
        Binding(
            get: { authMethod == .keyboardInteractive ? .password : authMethod },
            set: { authMethod = $0 }
        )
    }
    private var usesKeyboardInteractive: Binding<Bool> {
        Binding(
            get: { authMethod == .keyboardInteractive },
            set: { authMethod = $0 ? .keyboardInteractive : .password }
        )
    }

    var body: some View {
        TextField("Jump Host", text: $hostname)
            .autocapitalization(.none)
            .autocorrectionDisabled()
            .keyboardType(.URL)

        HStack {
            Text("Port")
            Spacer()
            TextField("22", text: $port)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
        }

        TextField("Username", text: $username)
            .autocapitalization(.none)
            .autocorrectionDisabled()

        Picker("Method", selection: methodSelection) {
            ForEach(authMethodPickerCases, id: \.self) { type in
                Text(type.displayName).tag(type)
            }
        }
        .pickerStyle(.segmented)

        if authMethod == .password || authMethod == .keyboardInteractive {
            Toggle("Keyboard-Interactive (2FA / OTP)", isOn: usesKeyboardInteractive)
            if authMethod == .keyboardInteractive {
                Text("The jump host will prompt for credentials, such as a one-time code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if hasSavedPassword.wrappedValue && password.isEmpty && !isChangingPassword {
                HStack {
                    Label("Password saved", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("Change") { isChangingPassword = true }
                        .buttonStyle(.borderless)
                }
                if let onForgetSavedPassword {
                    Button("Remove Saved Password", role: .destructive, action: onForgetSavedPassword)
                        .font(.subheadline)
                }
            } else {
                SecureField(hasSavedPassword.wrappedValue ? "New Password" : "Password", text: $password)
                if showsSavePasswordToggle {
                    Toggle("Save Password", isOn: $savePassword)
                }
            }
        } else if authMethod == .key {
            if sshKeyManager.savedKeys.isEmpty {
                SSHKeyEmptyStateView(
                    title: String(localized: "No SSH keys available"),
                    detail: String(localized: "Import a key for the jump host or switch to password auth.")
                )
            } else {
                SSHKeyPickerView(title: String(localized: "SSH Key"), selection: $selectedKeyID)
            }
        }
    }
}

// MARK: - Jump config builder

extension JumpHostFormSection {

    /// Validation failure carrying the exact user-facing message the
    /// form surfaces via its error banner.
    struct BuildError: Error {
        let message: String
    }

    /// Build the ``SSHConfig/JumpHostConfig`` from the single-hop form
    /// fields. Returns nil when the jump host is disabled; throws a
    /// ``BuildError`` on validation failure.
    @MainActor
    static func buildJumpHostConfig(
        useJumpHost: Bool,
        hostname: String,
        port: String,
        username: String,
        authMethod: AuthType,
        password: String,
        selectedKeyID: UUID?,
        sshKeyManager: SSHKeyManager
    ) throws -> SSHConfig.JumpHostConfig? {
        guard useJumpHost else { return nil }
        var draft = JumpHostDraft(hostname: hostname, port: port, username: username,
                                  authMethod: authMethod, selectedKeyID: selectedKeyID)
        draft.password = password
        return try draft.build(sshKeyManager: sshKeyManager)
    }
}

// MARK: - Shared SSH key sub-views

/// Empty-state row shown when key auth is selected but no keys exist.
/// Shared by the target auth section, jump section, and agent forwarding.
struct SSHKeyEmptyStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .foregroundColor(.secondary)
                .font(.subheadline)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            NavigationLink(destination: SSHKeyManagementView()) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Import SSH Key")
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Saved-key picker row shared by the target auth and jump sections.
struct SSHKeyPickerView: View {
    let title: String
    @Binding var selection: UUID?

    @ObservedObject private var sshKeyManager = SSHKeyManager.shared

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(sshKeyManager.savedKeys) { key in
                HStack {
                    Text(key.name)
                    Spacer()
                    Text(key.keyType.shortName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .tag(Optional(key.id))
            }
        }
    }
}
