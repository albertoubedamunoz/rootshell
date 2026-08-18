//
//  GPGKeyManagementView.swift
//  rootshell
//
//  Lists imported GPG (OpenPGP) secret keys and provides entry points
//  for importing new ones. Parallel structure to
//  ``SSHKeyManagementView`` but simpler because we don't have GPG-side
//  equivalents of YubiKey / FIDO2 key types yet — every GPG key is a
//  software key backed by the Keychain.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

struct GPGKeyManagementView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var keyManager = GPGKeyManager.shared

    @State private var showingImportSheet = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: GPGKey?
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        List {
            if keyManager.savedKeys.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.top, 20)

                        Text("No GPG Keys")
                            .font(.headline)

                        Text("Import an OpenPGP secret key to enable GPG agent forwarding for SSH sessions")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(keyManager.savedKeys) { key in
                        NavigationLink {
                            GPGKeyDetailView(key: key)
                        } label: {
                            GPGKeyRow(key: key)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                keyToDelete = key
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .themedRow()
                }
            }

            Section {
                Text("GPG keys are stored in the system Keychain. Imported keys are exposed to forwarded agents for both signing (PKSIGN) and decryption (PKDECRYPT) based on each subkey's key-flag capabilities. SSH keys configured under Settings → SSH Keys are also bridged to the GPG agent — RSA / ECDSA P-256 keys cover both sign and decrypt with one keygrip; Ed25519 exposes its signing key and a paired cv25519 keygrip for decryption.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .refreshable {
            await keyManager.refreshKeysAsync()
        }
        .navigationTitle("GPG Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingImportSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingImportSheet) {
            GPGKeyImportView()
                .themedSubSheet(sheetThemeColors)
        }
        .confirmationDialog(
            "Delete GPG Key?",
            isPresented: $showingDeleteConfirmation,
            presenting: keyToDelete
        ) { key in
            Button("Delete '\(key.name)'", role: .destructive) {
                do {
                    try keyManager.deleteKey(id: key.id)
                } catch {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
                keyToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                keyToDelete = nil
            }
        } message: { _ in
            Text("Removing this key disables any active GPG forwarding using it. The key cannot be recovered without re-importing.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

// MARK: - Row

private struct GPGKeyRow: View {
    let key: GPGKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.purple)
                Text(key.name)
                    .font(.headline)
                Spacer()
                if key.keygripIndex.count > 1 {
                    Text("\(key.keygripIndex.count) subkeys")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(algorithms, id: \.self) { algo in
                    AlgorithmBadge(name: algo)
                }
                Text(key.shortPrimaryFingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var algorithms: [String] {
        Array(Set(key.signingSubkeys.map { $0.algorithm.displayName })).sorted()
    }
}
