import SwiftUI

/// Edit SSH credentials for radio scanning on a WiFi AP account
struct WiFiAPSSHConfigView: View {
    let accountID: UUID

    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var accountManager = WiFiAPAccountManager.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared

    @State private var sshUsername = ""
    @State private var selectedKeyID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("SSH Username", text: $sshUsername)
                    .textContentType(.username)
                    .autocapitalization(.none)
                    .themedRow()

                Picker("SSH Key", selection: $selectedKeyID) {
                    Text("None").tag(UUID?.none)
                    ForEach(keyManager.savedKeys) { key in
                        Text(key.name).tag(UUID?.some(key.id))
                    }
                }
                .themedRow()
            } header: {
                Text("SSH Credentials")
            } footer: {
                Text("Configure SSH access to scan AP radios for band information. Requires SSH access to your UniFi devices.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("SSH Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save") { save() }
                    .disabled(isSaving)
            }
        }
        .onAppear { loadExisting() }
    }

    // MARK: - Actions

    private func loadExisting() {
        guard let credentials = try? accountManager.getCredentials(for: accountID) else { return }
        sshUsername = credentials.sshUsername ?? ""
        selectedKeyID = credentials.sshKeyID
    }

    private func save() {
        isSaving = true
        errorMessage = nil

        do {
            var credentials = try accountManager.getCredentials(for: accountID)
            credentials.sshUsername = sshUsername.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : sshUsername.trimmingCharacters(in: .whitespaces)
            credentials.sshKeyID = selectedKeyID

            try accountManager.updateCredentials(credentials)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
