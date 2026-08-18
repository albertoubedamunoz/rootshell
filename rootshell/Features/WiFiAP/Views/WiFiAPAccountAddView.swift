import SwiftUI

// MARK: - Add WiFi AP Account View

struct WiFiAPAccountAddView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var accountManager = WiFiAPAccountManager.shared
    @ObservedObject private var cacheManager = WiFiAPCacheManager.shared

    @ObservedObject private var keyManager = SSHKeyManager.shared

    @State private var selectedProvider: String = UbiquitiProvider.providerID
    @State private var accountLabel = ""
    @State private var apiKey = ""

    @State private var sshUsername = ""
    @State private var selectedSSHKeyID: UUID?

    @State private var isValidating = false
    @State private var validationError: String?
    @State private var showValidationError = false

    var body: some View {
        Form {
            providerSection
            credentialsSection
            sshSection
            helpSection
        }
        .themedList()
        .navigationTitle("Add WiFi AP Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Add") { addAccount() }
                    .disabled(!isFormValid || isValidating)
            }
        }
        .alert("Validation Failed", isPresented: $showValidationError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? "Unable to validate credentials")
        }
    }

    // MARK: - Form Sections

    private var providerSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: UbiquitiProvider.iconName)
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(UbiquitiProvider.displayName)
                        .font(.body)
                    Text("UniFi management API")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
            .themedRow()
        } header: {
            Text("Provider")
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Account Label", text: $accountLabel)
                .textContentType(.nickname)
                .themedRow()

            SecureField("API Key", text: $apiKey)
                .textContentType(.password)
                .autocapitalization(.none)
                .themedRow()

            if isValidating {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Validating credentials...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Enter the API key from your UniFi management dashboard.")
        }
    }

    private var sshSection: some View {
        Section {
            TextField("SSH Username", text: $sshUsername)
                .textContentType(.username)
                .autocapitalization(.none)
                .themedRow()

            Picker("SSH Key", selection: $selectedSSHKeyID) {
                Text("None").tag(UUID?.none)
                ForEach(keyManager.savedKeys) { key in
                    Text(key.name).tag(UUID?.some(key.id))
                }
            }
            .themedRow()
        } header: {
            Text("SSH Radio Scanning (Optional)")
        } footer: {
            Text("Configure SSH to scan AP radios for band information. Requires SSH access to your UniFi devices.")
        }
    }

    private var helpSection: some View {
        Section {
            Link(destination: UbiquitiProvider.apiKeyHelpURL) {
                HStack {
                    Image(systemName: "questionmark.circle")
                    Text("How to generate an API key")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()
        }
    }

    // MARK: - Validation

    private var isFormValid: Bool {
        !accountLabel.trimmingCharacters(in: .whitespaces).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    private func addAccount() {
        isValidating = true
        validationError = nil

        let accountID = UUID()
        let trimmedSSHUsername = sshUsername.trimmingCharacters(in: .whitespaces)
        let credentials = WiFiAPCredentials.apiKeyWithSSH(
            accountID: accountID,
            providerID: selectedProvider,
            key: apiKey.trimmingCharacters(in: .whitespaces),
            sshUsername: trimmedSSHUsername.isEmpty ? nil : trimmedSSHUsername,
            sshKeyID: selectedSSHKeyID
        )

        Task {
            do {
                let client = UbiquitiProvider.createAPIClient(credentials: credentials)
                let isValid = try await client.validateCredentials()

                guard isValid else {
                    validationError = "Invalid API key"
                    showValidationError = true
                    isValidating = false
                    return
                }

                try accountManager.addAccount(
                    providerID: selectedProvider,
                    label: accountLabel.trimmingCharacters(in: .whitespaces),
                    authMethod: .apiKey,
                    credentials: credentials
                )

                // Trigger initial sync
                await cacheManager.syncAccount(accountID)

                isValidating = false
                dismiss()
            } catch {
                validationError = error.localizedDescription
                showValidationError = true
                isValidating = false
            }
        }
    }
}
