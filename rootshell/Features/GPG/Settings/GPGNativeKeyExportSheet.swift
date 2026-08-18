//
//  GPGNativeKeyExportSheet.swift
//  rootshell
//
//  Sheet UI for exporting an imported native GPG key's public-key
//  block. Parallel to ``SSHKeyGPGExportSheet`` (which is the
//  SSH-keyed variant); the only difference is the underlying export
//  call site — ``OpenPGPPublicKeyExport.export(gpgKey:userID:)``
//  instead of the SSHKey overload.
//
//  Triggers the GPG key's biometric / passcode prompt to compute the
//  self-signature. Output is an ASCII-armored block ready for
//  `gpg --import`.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI
import os.log

struct GPGNativeKeyExportSheet: View {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "GPGNativeKeyExportSheet"
    )

    let key: GPGKey

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var armoredOutput: String = ""
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showingShareSheet = false
    /// The keygrip whose public material we'll emit. Populated in
    /// `onAppear` with the same default ``OpenPGPPublicKeyExport`` would
    /// pick (primary first). When the key has multiple subkeys the
    /// picker lets the user choose which keygrip the remote should
    /// recognise.
    @State private var selectedKeygripHex: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .themedRow()
                    TextField("Email (optional)", text: $email)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .themedRow()
                } header: {
                    Text("User ID")
                } footer: {
                    Text("Appears on the OpenPGP key as `Name <email>` (what the remote shows when verifying signatures).")
                }

                if subkeyChoices.count > 1 {
                    Section {
                        Picker("Subkey", selection: $selectedKeygripHex) {
                            ForEach(subkeyChoices, id: \.keygripHex) { choice in
                                Text(choice.label).tag(choice.keygripHex)
                            }
                        }
                        .themedRow()
                    } header: {
                        Text("Key to Expose")
                    } footer: {
                        Text("Only the chosen subkey's public material ends up in the exported block. The remote's `gpg` can sign with this specific keygrip; pick a different one if you want the forwarded agent to sign as that key instead.")
                    }
                }

                if !armoredOutput.isEmpty {
                    Section {
                        Text(armoredOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(6)
                            .themedRow()

                        HStack {
                            Button(action: copy) {
                                HStack(spacing: 4) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? "Copied" : "Copy")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(copied ? .green : .blue)

                            Button(action: { showingShareSheet = true }) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                        .themedRow()
                    } header: {
                        Text("OpenPGP Public Key")
                    } footer: {
                        Text("On the remote, save this to a file and run `gpg --import <file>`. The fingerprint matches what `Settings → GPG Keys` shows.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .themedRow()
                    }
                }

                Section {
                    Text("Generating the public key produces a self-signature, so the same authentication you use for signing with this key will be required.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            }
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Export Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await runExport() }
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text("Generate").bold()
                        }
                    }
                    .disabled(isExporting || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                GPGKeyExportShareSheet(items: [armoredOutput])
            }
            .onAppear {
                if name.isEmpty { name = key.name }
                if selectedKeygripHex.isEmpty {
                    selectedKeygripHex = defaultKeygripHex
                }
            }
        }
    }

    // MARK: - Derived

    /// One row per *signing-capable* subkey for the picker, primary
    /// first then by short fingerprint. The exported block needs a
    /// signing primary (it self-signs the user ID and binds any
    /// encryption subkey), so encryption-only entries (ECDH cv25519,
    /// ECDH P-256, X25519 native) are filtered out — picking one would
    /// fail at sign-time with no way to recover.
    ///
    /// If the imported keyring had its encryption subkey paired with
    /// a signing primary, the primary still appears here and the
    /// encryption subkey gets emitted alongside it by the export
    /// path; the user doesn't need to (and can't) pick the encryption
    /// subkey directly.
    private var subkeyChoices: [(keygripHex: String, label: String)] {
        key.keygripIndex
            .filter { $0.value.capability.canSign }
            .sorted { lhs, rhs in
                if lhs.value.isPrimary != rhs.value.isPrimary { return lhs.value.isPrimary }
                return lhs.key < rhs.key
            }
            .map { (keygripHex, info) in
                let short = String(info.fingerprint.gpgHexUpper.suffix(16))
                let suffix = info.isPrimary ? " (primary)" : ""
                return (keygripHex, "\(info.algorithm.displayName)\(suffix) · \(short)")
            }
    }

    /// Default selection: first entry in the picker (which already
    /// puts the primary at the top, then sorts by keygrip). Using the
    /// picker's own ordering keeps the default highlight visually
    /// consistent with whatever the picker shows — and avoids
    /// `Dictionary.first` whose iteration order is undefined.
    private var defaultKeygripHex: String {
        subkeyChoices.first?.keygripHex ?? ""
    }

    // MARK: - Actions

    @MainActor
    private func runExport() async {
        errorMessage = nil
        armoredOutput = ""
        isExporting = true
        defer { isExporting = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID = trimmedEmail.isEmpty ? trimmedName : "\(trimmedName) <\(trimmedEmail)>"

        do {
            armoredOutput = try await OpenPGPPublicKeyExport.export(
                gpgKey: key,
                userID: userID,
                selectedKeygripHex: selectedKeygripHex.isEmpty ? nil : selectedKeygripHex
            )
        } catch {
            Self.logger.warning("GPG public export failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func copy() {
        UIPasteboard.general.string = armoredOutput
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

private struct GPGKeyExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
