#if !CHINA_BUILD
//
//  GeminiProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring Google Gemini provider
//

import SwiftUI

struct GeminiProviderDetailView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var saveError: String?
    @State private var saveWarning: String?
    @State private var showDeleteConfirmation = false

    // Temperature state
    @State private var temperature: Double = 0.4
    @State private var isUsingDefaultTemperature = true

    var body: some View {
        List {
            apiKeySection

            if credentialsManager.hasGoogleAPIKey {
                modelsSection
                temperatureSection
                deleteSection
            }
        }
        .themedList()
        .onAppear {
            loadTemperature()
        }
        .navigationTitle("Google")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete API Key", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? credentialsManager.deleteGoogleAPIKey()
                apiKeyInput = ""
            }
        } message: {
            Text("This will remove your Google API key. You'll need to enter it again to use Gemini models.")
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("AIza...", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("AIza...", text: $apiKeyInput)
                        .textContentType(.password)
                }

                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .themedRow()

            if let error = saveError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            if let warning = saveWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .themedRow()
            }

            if !apiKeyInput.isEmpty {
                Button("Save API Key") {
                    saveAPIKey()
                }
                .themedRow()
            }

            if credentialsManager.hasGoogleAPIKey && apiKeyInput.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API key saved in Keychain")
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("Get your API key from ai.google.dev/aistudio. Supports Gemini models with adaptive thinking.")
        }
    }

    private var modelsSection: some View {
        Section("Available Models") {
            ForEach(AIProviderModel.googleModels) { model in
                ModelRow(model: model)
                    .themedRow()
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete API Key")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    private var temperatureSection: some View {
        let defaultTemp = AICredentialsManager.defaultTemperatures[GeminiProvider.providerID] ?? 0.4

        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $temperature, in: 0.0...2.0, step: 0.05)
                    .onChange(of: temperature) { _, newValue in
                        credentialsManager.setTemperature(newValue, for: GeminiProvider.providerID)
                        isUsingDefaultTemperature = false
                    }

                HStack {
                    Text("Deterministic")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Creative")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            if !isUsingDefaultTemperature {
                Button("Reset to Default (\(String(format: "%.1f", defaultTemp)))") {
                    credentialsManager.setTemperature(nil, for: GeminiProvider.providerID)
                    temperature = defaultTemp
                    isUsingDefaultTemperature = true
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("Temperature")
        } footer: {
            Text("Lower values produce more focused responses. Higher values produce more varied, creative responses.")
        }
    }

    // MARK: - Actions

    private func loadTemperature() {
        let defaultTemp = AICredentialsManager.defaultTemperatures[GeminiProvider.providerID] ?? 0.4
        if let savedTemp = credentialsManager.temperature(for: GeminiProvider.providerID) {
            temperature = savedTemp
            isUsingDefaultTemperature = false
        } else {
            temperature = defaultTemp
            isUsingDefaultTemperature = true
        }
    }

    private func saveAPIKey() {
        saveError = nil
        saveWarning = nil

        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            saveError = "API key cannot be empty"
            return
        }

        // Google AI Studio keys historically start with "AIza"; newer keys use "AQ."
        // Warn on unknown prefixes but still allow saving so users can try the key.
        if !trimmedKey.hasPrefix("AIza") && !trimmedKey.hasPrefix("AQ.") {
            saveWarning = "Unrecognized key format. Saving anyway — if calls fail, double-check the key."
        }

        do {
            try credentialsManager.saveGoogleAPIKey(trimmedKey)
            apiKeyInput = ""
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        GeminiProviderDetailView()
    }
}
#endif
