import SwiftUI

/// View for managing the order of default SSH keys
/// Keys are tried in priority order during authentication
struct DefaultKeysOrderView: View {
    @ObservedObject private var sshKeyManager = SSHKeyManager.shared
    @Environment(\.editMode) private var editMode

    var body: some View {
        List {
            // Default keys section (reorderable)
            if !sshKeyManager.defaultKeyIDs.isEmpty {
                Section {
                    ForEach(defaultKeys) { key in
                        DefaultKeyRow(key: key, priority: sshKeyManager.defaultPriority(for: key.id))
                            .themedRow()
                    }
                    .onMove(perform: moveKeys)
                    .onDelete(perform: removeFromDefaults)
                } header: {
                    Text("Default Keys (in priority order)")
                } footer: {
                    defaultKeysFooter
                }
            }

            // Non-default keys section (can be added)
            if !nonDefaultKeys.isEmpty {
                Section {
                    ForEach(nonDefaultKeys) { key in
                        Button {
                            sshKeyManager.addToDefaults(id: key.id)
                        } label: {
                            HStack {
                                NonDefaultKeyRow(key: key)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    Text("Other Keys")
                } footer: {
                    Text("Tap to add a key to the default list")
                }
            }

            // Empty state
            if sshKeyManager.savedKeys.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("No SSH Keys")
                            .font(.headline)

                        Text("Import or generate SSH keys in Settings to use as defaults")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .themedList()
        .navigationTitle("Default Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
    }

    // MARK: - Computed Properties

    /// Keys that are in the default list, in priority order
    private var defaultKeys: [SSHKey] {
        sshKeyManager.defaultKeyIDs.compactMap { id in
            sshKeyManager.findKey(id: id)
        }
    }

    /// Keys that are not in the default list
    private var nonDefaultKeys: [SSHKey] {
        sshKeyManager.savedKeys.filter { key in
            !sshKeyManager.isDefault(id: key.id)
        }
    }

    @ViewBuilder
    private var defaultKeysFooter: some View {
        if sshKeyManager.defaultKeyIDs.count > 6 {
            Label("SSH servers typically allow only 6 key attempts. Some keys may not be tried.", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption)
        } else {
            Text("Drag to reorder. Keys are tried from top to bottom until one succeeds.")
        }
    }

    // MARK: - Actions

    private func moveKeys(from source: IndexSet, to destination: Int) {
        sshKeyManager.moveDefaultKey(from: source, to: destination)
    }

    private func removeFromDefaults(at offsets: IndexSet) {
        for index in offsets {
            let keyID = sshKeyManager.defaultKeyIDs[index]
            sshKeyManager.removeFromDefaults(id: keyID)
        }
    }
}

// MARK: - Default Key Row

private struct DefaultKeyRow: View {
    let key: SSHKey
    let priority: Int?

    var body: some View {
        HStack(spacing: 12) {
            // Priority badge
            if let priority = priority {
                Text("\(priority + 1)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.blue)
                    .clipShape(Circle())
            }

            // Key type badge
            Text(key.keyType.shortName)
                .font(.caption.bold())
                .foregroundStyle(keyTypeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(keyTypeColor.opacity(0.18))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.body)

                Text(key.formattedFingerprint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var keyTypeColor: Color {
        switch key.keyType {
        case .rsa: return .red
        case .ed25519: return .blue
        case .ecdsaP256: return .green
        case .ecdsaP384: return .orange
        case .ecdsaP521: return .purple
        case .yubiKeyPIV: return .yellow
        case .yubiKeyFIDO2: return .cyan
        case .appleFIDO2: return .teal
        case .applePasskey: return .blue
        case .secureEnclaveP256: return .indigo
        case .externalAgent: return .mint
        case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87: return .pink
        }
    }
}

// MARK: - Non-Default Key Row

private struct NonDefaultKeyRow: View {
    let key: SSHKey

    var body: some View {
        HStack(spacing: 12) {
            // Key type badge
            Text(key.keyType.shortName)
                .font(.caption.bold())
                .foregroundStyle(keyTypeColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(keyTypeColor.opacity(0.18))
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(.body)

                Text(key.formattedFingerprint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var keyTypeColor: Color {
        switch key.keyType {
        case .rsa: return .red
        case .ed25519: return .blue
        case .ecdsaP256: return .green
        case .ecdsaP384: return .orange
        case .ecdsaP521: return .purple
        case .yubiKeyPIV: return .yellow
        case .yubiKeyFIDO2: return .cyan
        case .appleFIDO2: return .teal
        case .applePasskey: return .blue
        case .secureEnclaveP256: return .indigo
        case .externalAgent: return .mint
        case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87: return .pink
        }
    }
}

#Preview {
    NavigationView {
        DefaultKeysOrderView()
    }
}
