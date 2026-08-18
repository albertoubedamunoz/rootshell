//
//  GPGKeyDetailView.swift
//  rootshell
//
//  Per-GPG-key detail screen reachable from GPGKeyManagementView.
//  Surfaces what the row can't fit: full fingerprint, per-subkey
//  algorithms / keygrips, and the actions (rename, export public
//  key, delete).
//
//  Mirrors SSHKeyDetailView's structure so users moving between the
//  two settings screens see the same shape.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

struct GPGKeyDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var keyManager = GPGKeyManager.shared

    let key: GPGKey

    @State private var showingRenameAlert = false
    @State private var newKeyName = ""
    @State private var showingDeleteConfirmation = false
    @State private var showingExportSheet = false
    @State private var fingerprintCopied = false
    @State private var keygripCopied: String?
    @State private var errorMessage: String?
    @State private var showingError = false

    var body: some View {
        List {
            if currentKey.schemaVersion < GPGKey.currentSchemaVersion {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Decryption not enabled", systemImage: "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                        Text("This key was imported before PKDECRYPT support landed. If your original keyring had an encryption subkey, re-import the secret-key block to enable `gpg -d` over the forwarded agent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            }

            Section {
                LabeledRow(label: "Name", value: currentKey.name)
                    .themedRow()
                LabeledRow(label: "Imported", value: formattedDate)
                    .themedRow()
            } header: {
                Text("Identity")
            }

            Section("Primary Fingerprint") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("SHA1")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copyFingerprint) {
                            HStack(spacing: 4) {
                                Image(systemName: fingerprintCopied ? "checkmark" : "doc.on.doc")
                                Text(fingerprintCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy", comment: "Copy button"))
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(fingerprintCopied ? .green : .blue)
                    }

                    Text(currentKey.formattedPrimaryFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            Section {
                ForEach(sortedSubkeys, id: \.fingerprint) { sub in
                    subkeyRow(sub)
                }
                .themedRow()
            } header: {
                Text(subkeyHeader)
            } footer: {
                Text("Keygrips are what the forwarded GPG agent matches on. Tap to copy if you need to reference a specific subkey on the remote.")
                    .font(.caption)
            }

            Section {
                Button {
                    showingExportSheet = true
                } label: {
                    Label("Export OpenPGP Public Key", systemImage: "square.and.arrow.up")
                }
                .themedRow()
            } footer: {
                Text("Generates an ASCII-armored public-key block (with a self-signature) that the remote imports with `gpg --import`. Triggers the key's normal auth prompt.")
                    .font(.caption)
            }

            Section {
                Button {
                    newKeyName = currentKey.name
                    showingRenameAlert = true
                } label: {
                    Label("Rename Key", systemImage: "pencil")
                }
                .themedRow()

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Key", systemImage: "trash")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(currentKey.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingExportSheet) {
            GPGNativeKeyExportSheet(key: currentKey)
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Rename Key", isPresented: $showingRenameAlert) {
            TextField("Key name", text: $newKeyName)
            Button("Cancel", role: .cancel) {
                newKeyName = ""
            }
            Button("Rename") {
                renameKey()
            }
        } message: {
            Text("Enter a new name for this GPG key.")
        }
        .confirmationDialog(
            "Delete GPG Key?",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("Delete '\(currentKey.name)'", role: .destructive) {
                deleteKey()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removing this key disables any active GPG forwarding using it. The key cannot be recovered without re-importing.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Computed

    private var currentKey: GPGKey {
        keyManager.savedKeys.first(where: { $0.id == key.id }) ?? key
    }

    /// Primary first, then everything else ordered by fingerprint for
    /// a stable list across renders.
    private var sortedSubkeys: [GPGSubkeyInfo] {
        let all = Array(currentKey.keygripIndex.values)
        return all.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.fingerprint.lexicographicallyPrecedes(rhs.fingerprint)
        }
    }

    private var subkeyHeader: String {
        let count = currentKey.keygripIndex.count
        return count == 1 ? "Subkey" : "Subkeys (\(count))"
    }

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: currentKey.createdDate)
    }

    // MARK: - Subkey row

    @ViewBuilder
    private func subkeyRow(_ sub: GPGSubkeyInfo) -> some View {
        let keygripHex = (try? sub.keygripHex()) ?? "—"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AlgorithmBadge(name: sub.algorithm.displayName)
                if sub.isPrimary {
                    Text("Primary")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15))
                        .foregroundColor(.purple)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(shortFingerprint(sub))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Button {
                UIPasteboard.general.string = keygripHex
                keygripCopied = keygripHex
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if keygripCopied == keygripHex { keygripCopied = nil }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("keygrip")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(keygripHex)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if keygripCopied == keygripHex {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func shortFingerprint(_ sub: GPGSubkeyInfo) -> String {
        let hex = sub.fingerprint.gpgHexUpper
        return String(hex.suffix(16))
    }

    // MARK: - Actions

    private func copyFingerprint() {
        UIPasteboard.general.string = currentKey.primaryFingerprint.gpgHexUpper
        fingerprintCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            fingerprintCopied = false
        }
    }

    private func renameKey() {
        let trimmed = newKeyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = "Key name cannot be empty"
            showingError = true
            return
        }
        do {
            try keyManager.updateKeyName(id: key.id, newName: trimmed)
            newKeyName = ""
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func deleteKey() {
        do {
            try keyManager.deleteKey(id: key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - Algorithm badge

/// Small capsule used by both the management list rows and the detail
/// subkey rows to identify a key's algorithm at a glance.
struct AlgorithmBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.15))
            .foregroundColor(.blue)
            .clipShape(Capsule())
    }
}

// MARK: - GPGSubkeyInfo keygrip helper

private extension GPGSubkeyInfo {
    /// Resolves the keygrip hex string for display. Searches the
    /// parent key's index because keygrip is the index *key*, not a
    /// stored field on the value.
    func keygripHex() throws -> String {
        for key in GPGKeyManager.shared.savedKeys {
            if let (hex, _) = key.keygripIndex.first(where: { $0.value.fingerprint == self.fingerprint }) {
                return hex
            }
        }
        throw NSError(domain: "GPGKeyDetail", code: -1)
    }
}
