#if !CHINA_BUILD
//
//  AnthropicProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring Anthropic provider
//

import SwiftUI

struct AnthropicProviderDetailView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var saveError: String?
    @State private var showDeleteConfirmation = false

    // Temperature state
    @State private var temperature: Double = 1.0
    @State private var isUsingDefaultTemperature = true

    var body: some View {
        List {
            apiKeySection

            if credentialsManager.hasAnthropicAPIKey {
                modelsSection
                temperatureSection
                deleteSection
            }
        }
        .themedList()
        .onAppear {
            loadTemperature()
        }
        .navigationTitle("Anthropic")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete API Key", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? credentialsManager.deleteAnthropicAPIKey()
                apiKeyInput = ""
            }
        } message: {
            Text("This will remove your Anthropic API key. You'll need to enter it again to use Claude models.")
        }
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("sk-ant-...", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-ant-...", text: $apiKeyInput)
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

            if !apiKeyInput.isEmpty {
                Button("Save API Key") {
                    saveAPIKey()
                }
                .themedRow()
            }

            if credentialsManager.hasAnthropicAPIKey && apiKeyInput.isEmpty {
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
            Text("Get your API key from console.anthropic.com. Supports Claude models with extended thinking.")
        }
    }

    private var modelsSection: some View {
        Section("Available Models") {
            ForEach(AIProviderModel.anthropicModels) { model in
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
        let defaultTemp = AICredentialsManager.defaultTemperatures[AnthropicProvider.providerID] ?? 1.0

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
                        credentialsManager.setTemperature(newValue, for: AnthropicProvider.providerID)
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
                    credentialsManager.setTemperature(nil, for: AnthropicProvider.providerID)
                    temperature = defaultTemp
                    isUsingDefaultTemperature = true
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("Temperature")
        } footer: {
            Text("Lower values produce more focused responses. Higher values produce more varied, creative responses. Note: Temperature is ignored when extended thinking is enabled.")
        }
    }

    // MARK: - Actions

    private func loadTemperature() {
        let defaultTemp = AICredentialsManager.defaultTemperatures[AnthropicProvider.providerID] ?? 1.0
        if let savedTemp = credentialsManager.temperature(for: AnthropicProvider.providerID) {
            temperature = savedTemp
            isUsingDefaultTemperature = false
        } else {
            temperature = defaultTemp
            isUsingDefaultTemperature = true
        }
    }

    private func saveAPIKey() {
        saveError = nil

        guard !apiKeyInput.isEmpty else {
            saveError = "API key cannot be empty"
            return
        }

        guard apiKeyInput.hasPrefix("sk-ant-") else {
            saveError = "Invalid API key format (should start with sk-ant-)"
            return
        }

        do {
            try credentialsManager.saveAnthropicAPIKey(apiKeyInput)
            apiKeyInput = ""
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        AnthropicProviderDetailView()
    }
}
#endif
