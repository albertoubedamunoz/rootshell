//
//  KeyResolutionSheet.swift
//  rootshell
//
//  Picker UI shown when a synced profile or history entry references
//  an SSH key that doesn't exist on the current device.
//

import SwiftUI

/// Sheet presented when a connection's SSH key can't be resolved locally.
/// Shows the original key's metadata and lets the user pick a local replacement.
struct KeyResolutionSheet: View {
    let unresolvedKeys: [UnresolvedKeyInfo]
    let config: SSHConfig
    let profileID: UUID?
    let connectionIdentity: String?
    let onResolved: (SSHConfig) -> Void
    let onCancel: () -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var targetKeySelection: UUID?
    @State private var jumpKeySelections: [Int: UUID] = [:]
    @State private var saveAsDeviceOverride: Bool = true

    private var keyManager: SSHKeyManager { SSHKeyManager.shared }

    private var targetUnresolved: UnresolvedKeyInfo? {
        unresolvedKeys.first { !$0.isJumpHost }
    }

    private var jumpHostsUnresolved: [UnresolvedKeyInfo] {
        unresolvedKeys.filter(\.isJumpHost)
    }

    private var hopCount: Int { config.jumpChain.count }

    private func jumpKeySelection(_ hopIndex: Int) -> Binding<UUID?> {
        Binding(get: { jumpKeySelections[hopIndex] }, set: { jumpKeySelections[hopIndex] = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header explaining the situation
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SSH Key Not Available")
                                .font(.headline)
                            Text("The key used by this connection isn't available on this device. Select a local key to use instead.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.slash")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                    .themedRow()
                }

                // Target key resolution
                if let info = targetUnresolved {
                    Section {
                        hintInfoView(hint: info.hint)
                            .themedRow()
                        keyPickerView(selection: $targetKeySelection, filterType: info.hint?.keyType)
                            .themedRow()
                    } header: {
                        Text("Target Host Key")
                    }
                }

                // Jump host key resolution, one section per hop
                ForEach(jumpHostsUnresolved, id: \.hopIndexOrZero) { info in
                    Section {
                        hintInfoView(hint: info.hint)
                            .themedRow()
                        keyPickerView(selection: jumpKeySelection(info.hopIndexOrZero), filterType: info.hint?.keyType)
                            .themedRow()
                    } header: {
                        if hopCount > 1 {
                            Text("Jump Host \(info.hopIndexOrZero + 1) Key")
                        } else {
                            Text("Jump Host Key")
                        }
                    }
                }

                // Save option
                Section {
                    Toggle("Always use on this device", isOn: $saveAsDeviceOverride)
                        .themedRow()
                } footer: {
                    Text("Save this key selection so future connections from this device use it automatically.")
                }
            }
            .themedList()
            .navigationTitle("Select Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        applyResolution()
                    }
                    .disabled(!isSelectionComplete)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func hintInfoView(hint: KeyResolutionHint?) -> some View {
        if let hint {
            VStack(alignment: .leading, spacing: 4) {
                if let name = hint.keyName {
                    HStack {
                        Text("Original Key")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(name)
                    }
                }
                if let keyType = hint.keyType {
                    HStack {
                        Text("Type")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(keyType.displayName)
                    }
                }
                if let fingerprint = hint.fingerprint {
                    HStack {
                        Text("Fingerprint")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("SHA256:\(fingerprint.prefix(12))...")
                            .font(.caption)
                            .monospaced()
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func keyPickerView(selection: Binding<UUID?>, filterType: SSHKey.KeyType?) -> some View {
        let availableKeys = keyManager.savedKeys
        if availableKeys.isEmpty {
            Text("No SSH keys available on this device")
                .foregroundStyle(.secondary)
                .italic()
        } else {
            Picker("Key", selection: selection) {
                Text("Select a key...").tag(nil as UUID?)
                ForEach(availableKeys) { key in
                    HStack {
                        Text(key.name)
                        Spacer()
                        Text(key.keyType.shortName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(key.id as UUID?)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Logic

    private var isSelectionComplete: Bool {
        let targetOK = targetUnresolved == nil || targetKeySelection != nil
        let jumpOK = jumpHostsUnresolved.allSatisfy { jumpKeySelections[$0.hopIndexOrZero] != nil }
        return targetOK && jumpOK
    }

    private func applyResolution() {
        var resolved = config

        // Apply target key selection
        if targetUnresolved != nil, let selectedID = targetKeySelection {
            resolved.authMethod = .key(selectedID)
        }

        // Apply jump host key selections
        var chain = resolved.jumpChain
        for info in jumpHostsUnresolved {
            let index = info.hopIndexOrZero
            if chain.indices.contains(index), let selectedID = jumpKeySelections[index] {
                chain[index].authMethod = .key(selectedID)
            }
        }
        resolved.jumpChain = chain

        // Save device override if requested
        if saveAsDeviceOverride {
            let target: OverrideTarget
            if let profileID {
                target = .profile(profileID)
            } else if let connectionIdentity {
                target = .connectionIdentity(connectionIdentity)
            } else {
                // No target to persist override for — just use the key this once
                onResolved(resolved)
                return
            }

            let extraSelections = Dictionary(uniqueKeysWithValues: jumpKeySelections
                .filter { $0.key > 0 }
                .map { (String($0.key), $0.value) })
            let override = DeviceKeyOverride(
                target: target,
                targetKeyID: targetKeySelection,
                jumpHostKeyID: jumpKeySelections[0],
                extraJumpHostKeyIDs: extraSelections.isEmpty ? nil : extraSelections,
                createdAt: Date()
            )
            DeviceKeyOverrideManager.shared.save(override)
        }

        onResolved(resolved)
    }
}

private extension UnresolvedKeyInfo {
    /// Jump keys from older resolvers carry no index; they belong to the first hop.
    var hopIndexOrZero: Int { hopIndex ?? 0 }
}
