//
//  JumpHostFormSection.swift
//  rootshell
//
//  Shared jump-host form fields + config builder, extracted from
//  SSHConnectionView so other connection forms (e.g. Screen Sharing)
//  can offer the same jump-host UX without duplicating it. The SSH
//  form keeps its own DisclosureGroup wrapper and summary label; this
//  section is just the field stack inside it.
//

import SwiftUI

/// The jump-host field stack: enable toggle, hostname/port/username,
/// auth-method picker, and the password/key sub-fields. Renders as a
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

    @ObservedObject private var sshKeyManager = SSHKeyManager.shared

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
        Toggle("Connect via Jump Host", isOn: $useJumpHost.animation())

        if useJumpHost {
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
                } else {
                    SecureField("Password", text: $password)
                    Toggle("Save Password", isOn: $savePassword)
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
}

// MARK: - Jump config builder

extension JumpHostFormSection {

    /// Validation failure carrying the exact user-facing message the
    /// form surfaces via its error banner.
    struct BuildError: Error {
        let message: String
    }

    /// Build the ``SSHConfig/JumpHostConfig`` from the shared jump form
    /// fields. Returns nil when the jump host is disabled; throws a
    /// ``BuildError`` on validation failure. Shared by the SSH connect
    /// flow and any other form embedding this section.
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

        guard let jumpPortNum = Int(port), jumpPortNum > 0 && jumpPortNum <= 65535 else {
            throw BuildError(message: "Invalid jump host port number.")
        }

        let trimmedJumpHost = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJumpUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        let jumpAuth: SSHConfig.AuthMethod
        switch authMethod {
        case .password:
            guard !password.isEmpty else {
                throw BuildError(message: "Please enter jump host password")
            }
            jumpAuth = .password(password)
        case .key:
            guard let keyID = selectedKeyID else {
                throw BuildError(message: "Please select an SSH key for jump host")
            }
            guard sshKeyManager.findKey(id: keyID) != nil else {
                throw BuildError(message: "Selected jump host SSH key not found.")
            }
            jumpAuth = .key(keyID)
        case .keyboardInteractive:
            jumpAuth = .keyboardInteractive
        case .none:
            jumpAuth = .none  // Tailscale/WireGuard pre-authenticated
        }

        // Build fallback keys for jump host (same pattern as target)
        let jumpFallbackIDs: [UUID]?
        if case .key(let keyID) = jumpAuth {
            jumpFallbackIDs = sshKeyManager.defaultKeyIDs.filter { $0 != keyID }
        } else {
            jumpFallbackIDs = nil
        }

        return SSHConfig.JumpHostConfig(
            host: trimmedJumpHost,
            port: jumpPortNum,
            username: trimmedJumpUsername,
            authMethod: jumpAuth,
            fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
        )
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
