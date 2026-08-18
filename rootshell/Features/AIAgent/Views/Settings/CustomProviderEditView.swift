#if !CHINA_BUILD
//
//  CustomProviderEditView.swift
//  rootshell
//
//  Add/edit sheet for custom AI providers
//

import SwiftUI

struct CustomProviderEditView: View {
    enum Mode {
        case add
        case edit(CustomProviderConfig)
    }

    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var name: String = ""
    @State private var endpointURL: String = ""
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var apiFormat: AIAPIFormat = .openAIResponses
    @State private var useStreaming: Bool = true
    @State private var saveError: String?
    @State private var showSaveError = false
    @State private var isDiscovering = false
    @State private var discoveryError: String?

    /// Models found while adding, carried into the new config on save.
    @State private var pendingModels: [AIProviderModel] = []

    // For auto-refresh debouncing
    @State private var autoDiscoveryTask: Task<Void, Never>?

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var existingProvider: CustomProviderConfig? {
        if case .edit(let provider) = mode { return provider }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                authenticationSection
                apiSettingsSection

                if let error = saveError {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .themedRow()
                    }
                }

                if isDiscovering {
                    Section {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Discovering models...")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle(isEditing ? "Edit Provider" : "Add Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || endpointURL.isEmpty || !isURLValid)
                }
            }
            .onAppear {
                if let existing = existingProvider {
                    name = existing.name
                    endpointURL = existing.endpointURL
                    apiFormat = existing.apiFormat
                    useStreaming = existing.useStreaming
                    // Prefilled so the field is the whole truth: what you see is what gets saved,
                    // and clearing it removes the key.
                    apiKey = credentialsManager.loadAPIKey(for: existing) ?? ""
                }
            }
            .onDisappear {
                autoDiscoveryTask?.cancel()
            }
            .alert("Couldn't Save Provider", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                // Keychain error text, not ours to translate.
                Text(verbatim: saveError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var isURLValid: Bool {
        endpointURL.isEmpty || CustomProviderConfig.validateEndpointURL(endpointURL)
    }

    /// Whatever the user typed resolves to a single API root, so show the URL that will actually
    /// be requested. A wrong path is otherwise invisible until the request 404s.
    /// Redacted: an endpoint may legitimately carry proxy credentials, which should not sit on
    /// screen ready to be screenshotted into a bug report.
    private var resolvedRequestURL: String {
        CustomProviderConfig.redactedURL(
            CustomProviderConfig.requestURL(for: endpointURL, format: apiFormat))
    }

    private var resolvedModelsURL: String {
        CustomProviderConfig.redactedURL(
            CustomProviderConfig.modelsURL(for: endpointURL, format: apiFormat))
    }

    private var detailsSection: some View {
        Section {
            TextField("Display Name", text: $name)
                .themedRow()
            TextField("Endpoint URL", text: $endpointURL)
                .textContentType(.URL)
                .autocapitalization(.none)
                .keyboardType(.URL)
                .onChange(of: endpointURL) { _, _ in
                    triggerAutoDiscovery()
                }
                .themedRow()
        } header: {
            Text("Provider Details")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !isURLValid {
                    Label("Invalid URL format. Example: http://localhost:8000/v1", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                } else if !endpointURL.isEmpty {
                    Text("Requests go to \(resolvedRequestURL)")
                    Text("Models: \(resolvedModelsURL)")
                        .foregroundColor(.secondary)
                }
                if name.isEmpty {
                    Text("A display name is required to save.")
                        .foregroundColor(.secondary)
                }
                if let discoveryError {
                    // Server-supplied text, not ours to translate.
                    Text(verbatim: discoveryError)
                        .foregroundColor(.orange)
                }
            }
            .font(.caption)
        }
    }

    private var authenticationSection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("API Key", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("API Key", text: $apiKey)
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .onChange(of: apiKey) { _, _ in
                triggerAutoDiscovery()
            }
            .themedRow()
        } header: {
            Text("Authentication")
        } footer: {
            // The field is prefilled with the saved key, so it means exactly what it shows:
            // clearing it removes the key rather than silently keeping the old one.
            Text("Leave blank for a server that needs no authentication.")
                .font(.caption)
        }
    }

    private var apiSettingsSection: some View {
        Section {
            Picker("API Format", selection: $apiFormat) {
                ForEach(AIAPIFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .onChange(of: apiFormat) { _, _ in
                // The format decides the API root and the auth headers, so re-probe.
                triggerAutoDiscovery()
            }
            .themedRow()

            Toggle("Enable Streaming", isOn: $useStreaming)
                .themedRow()
        } header: {
            Text("API Settings")
        } footer: {
            Text(apiFormat.description)
        }
    }

    // MARK: - Actions

    private func save() {
        saveError = nil
        // Trim whitespace and newlines that may have been copied with the key
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if let existing = existingProvider {
                var updated = existing
                updated.name = name
                updated.endpointURL = CustomProviderConfig.normalizeEndpointURL(endpointURL)
                updated.apiFormat = apiFormat
                updated.useStreaming = useStreaming
                let endpointChanged = updated.endpointURL != existing.endpointURL
                    || updated.apiFormat != existing.apiFormat
                if !pendingModels.isEmpty {
                    updated.discoveredModels = pendingModels
                } else if endpointChanged {
                    // The saved list describes the endpoint that was just replaced, so keeping it
                    // would advertise another server's models in the picker. Manual entries are
                    // the user's own and survive; the post-save refresh repopulates the rest.
                    updated.discoveredModels = []
                }

                // Key first: a keychain failure must not leave a half-applied edit behind.
                // The field was prefilled from the keychain, so an empty one means the user
                // cleared it and wants the provider to authenticate with nothing.
                if cleanedKey.isEmpty {
                    if credentialsManager.hasAPIKey(for: updated) {
                        try credentialsManager.deleteAPIKey(for: updated.keychainAccount)
                    }
                } else {
                    try credentialsManager.saveAPIKey(for: updated, apiKey: cleanedKey)
                }
                credentialsManager.updateCustomProvider(updated)
                credentialsManager.refreshDiscoveredModels(for: updated.id)
            } else {
                let newProvider = CustomProviderConfig(
                    name: name,
                    endpointURL: endpointURL,
                    apiFormat: apiFormat,
                    useStreaming: useStreaming,
                    discoveredModels: pendingModels
                )

                // Key first: nothing is persisted if the keychain write fails, so a retry cannot
                // collide with a half-created provider.
                if !cleanedKey.isEmpty {
                    try credentialsManager.saveAPIKey(for: newProvider, apiKey: cleanedKey)
                }
                credentialsManager.addCustomProvider(newProvider)
                // Owned by the manager so it outlives this sheet.
                credentialsManager.refreshDiscoveredModels(for: newProvider.id)
            }
        } catch {
            saveError = error.localizedDescription
            showSaveError = true
            return
        }

        dismiss()
    }

    private func triggerAutoDiscovery() {
        autoDiscoveryTask?.cancel()
        // Staged models describe the inputs that produced them, so they die with those inputs.
        // Otherwise a success against one endpoint would be saved under a later, different one
        // whose probe failed or had not finished when Save was tapped.
        pendingModels = []
        guard !endpointURL.isEmpty, isURLValid else { return }

        // Runs before the provider exists and without a key: local servers are routinely
        // unauthenticated, and add mode is exactly when the user needs to know the URL is right.
        let url = endpointURL
        let format = apiFormat
        // The field carries the whole truth in both modes, so probe with exactly what it holds.
        let typedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String? = typedKey.isEmpty ? nil : typedKey

        autoDiscoveryTask = Task {
            // Debounce: wait 1 second after last change
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }

            isDiscovering = true
            defer { isDiscovering = false }

            do {
                let models = try await CustomProviderModelDiscovery.discoverModels(
                    endpointURL: url,
                    apiFormat: format,
                    apiKey: key
                )
                // Only adopt the result if the inputs it was probed with are still the ones on
                // screen; cancellation alone can lose a race with a fast-returning server.
                guard !Task.isCancelled, url == endpointURL, format == apiFormat else { return }
                discoveryError = nil
                // Staged, never written straight through: these models come from the URL and
                // format currently typed, which Cancel must be able to discard.
                pendingModels = models
            } catch {
                guard !Task.isCancelled else { return }
                discoveryError = error.localizedDescription
            }
        }
    }
}

#Preview("Add") {
    CustomProviderEditView(mode: .add)
}

#Preview("Edit") {
    CustomProviderEditView(mode: .edit(CustomProviderConfig(
        name: "Ollama Local",
        endpointURL: "http://localhost:11434/v1"
    )))
}
#endif
