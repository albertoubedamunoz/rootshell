//
//  GPGKeyImportView.swift
//  rootshell
//
//  Sheet for importing a GPG (OpenPGP) secret key from pasted text or
//  a file. The MVP only accepts *unencrypted* secret-key exports —
//  see ``OpenPGPPacket`` for the rationale. Users are guided to run
//  `gpg --export-secret-keys --armor KEYID` (after removing the
//  passphrase locally) to produce a compatible blob.
//
//  Parallel structure to ``SSHKeyImportView``, minus the encryption
//  passphrase flow (we reject encrypted keys at parse time rather than
//  attempting on-device decryption).
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

struct GPGKeyImportView: View {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "GPGKeyImport"
    )

    @Environment(\.dismiss) private var dismiss
    @StateObject private var keyManager = GPGKeyManager.shared

    @State private var importMethod: ImportMethod = .paste
    @State private var keyName = ""
    @State private var pastedKeyText = ""
    /// Raw bytes loaded from a binary `.gpg` file. Mutually exclusive
    /// with `pastedKeyText`: when the file picker delivers a non-armored
    /// blob we stash it here so `importKey()` can hand the original
    /// bytes to the parser without UTF-8 round-tripping (which would
    /// destroy any byte ≥ 0x80 — i.e. most of a binary OpenPGP packet).
    @State private var pastedKeyData: Data?
    @State private var loadedFileName: String?
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isImporting = false

    @State private var showSecurityOptions = false
    @State private var storageLevel: KeyStorageLevel = .backupOnly
    @State private var authRequirement: KeyAuthRequirement = .none

    enum ImportMethod: String, CaseIterable {
        case paste
        case file

        var displayName: String {
            switch self {
            case .paste: return String(localized: "Paste", comment: "GPG key import method: paste key text")
            case .file: return String(localized: "File", comment: "GPG key import method: import from file")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Import Method", selection: $importMethod) {
                        ForEach(ImportMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                }

                Section {
                    TextField("Key Name", text: $keyName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("A friendly name for this key (e.g., 'Personal GPG', 'Work signing')")
                }

                if importMethod == .paste {
                    Section {
                        TextEditor(text: $pastedKeyText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .themedRow()
                    } header: {
                        Text("Secret Key")
                    } footer: {
                        Text("Paste an unencrypted OpenPGP secret key (ASCII-armored output of `gpg --export-secret-keys --armor KEYID`).")
                    }
                } else {
                    Section {
                        Button {
                            showingFilePicker = true
                        } label: {
                            HStack {
                                Image(systemName: "doc.fill")
                                Text("Select Key File")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()

                        if pastedKeyData != nil || !pastedKeyText.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text(loadedFileName.map { "Loaded: \($0)" } ?? "File loaded")
                                    .foregroundColor(.secondary)
                            }
                            .themedRow()
                        }
                    } header: {
                        Text("Secret Key File")
                    } footer: {
                        Text("Select an exported .asc or .gpg secret key file.")
                    }
                }

                Section {
                    DisclosureGroup("Security Options", isExpanded: $showSecurityOptions) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key Storage")
                                .font(.subheadline.bold())
                            Picker("Key Storage", selection: $storageLevel) {
                                ForEach(KeyStorageLevel.allCases, id: \.self) { level in
                                    Label(level.displayName, systemImage: level.iconName).tag(level)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(storageLevel.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)

                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Require Authentication")
                                .font(.subheadline.bold())
                            Picker("Authentication", selection: $authRequirement) {
                                ForEach(KeyAuthRequirement.allCases, id: \.self) { req in
                                    Label(req.displayName, systemImage: req.iconName).tag(req)
                                }
                            }
                            .pickerStyle(.menu)
                            Text(authRequirement.description)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if storageLevel == .iCloudSync, authRequirement != .none {
                                Text(KeyAuthRequirement.iCloudAuthenticationAdvisory)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .themedRow()
                } footer: {
                    Text("Encrypted secret keys are not supported yet. Export a cleartext copy via `gpg --output mykey.asc --armor --export-secret-keys KEYID` after temporarily removing the passphrase.")
                }
            }
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Import GPG Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        importKey()
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Text("Import").bold()
                        }
                    }
                    .disabled(keyName.trimmingCharacters(in: .whitespaces).isEmpty
                              || (pastedKeyText.isEmpty && pastedKeyData == nil)
                              || isImporting)
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: importMethod) { _, newValue in
                // Switching back to paste must drop any loaded file
                // bytes, otherwise the Import button would use the
                // stale binary blob instead of whatever the user is
                // typing now.
                if newValue == .paste {
                    pastedKeyData = nil
                    loadedFileName = nil
                }
            }
            .alert("Import Failed", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func importKey() {
        // pastedKeyData wins when set — file imports route here for
        // binary `.gpg` blobs that would otherwise be mangled by a
        // UTF-8 round-trip. The text editor's String can always be
        // converted to UTF-8 losslessly because TextEditor only emits
        // valid Unicode.
        let data: Data
        if let fileData = pastedKeyData {
            data = fileData
        } else if let textData = pastedKeyText.data(using: .utf8) {
            data = textData
        } else {
            errorMessage = "Could not convert key text to bytes."
            showingError = true
            return
        }
        isImporting = true
        defer { isImporting = false }

        do {
            _ = try keyManager.importKey(
                name: keyName,
                keyData: data,
                storageLevel: storageLevel,
                authRequirement: authRequirement
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            Self.logger.warning("GPG import failed: \(error.localizedDescription)")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let bytes = try Data(contentsOf: url)
                // ASCII-armored exports start with `-----BEGIN PGP ...-----`
                // and are valid UTF-8 — keep them in the text path so
                // the user can edit if they want. Binary blobs go
                // straight into `pastedKeyData` to preserve every
                // byte; the parser auto-detects either form.
                let isArmored = bytes.starts(with: Data("-----BEGIN PGP".utf8))
                if isArmored, let text = String(data: bytes, encoding: .utf8) {
                    pastedKeyText = text
                    pastedKeyData = nil
                } else {
                    pastedKeyData = bytes
                    pastedKeyText = ""
                }
                loadedFileName = url.lastPathComponent
                if keyName.isEmpty {
                    keyName = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                errorMessage = "Could not read file: \(error.localizedDescription)"
                showingError = true
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}
