#if !CHINA_BUILD
//
//  CustomProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring a custom AI provider
//

import SwiftUI

struct CustomProviderDetailView: View {
    let providerId: UUID

    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var isDiscoveringModels = false
    @State private var discoveryError: String?
    @State private var showEditSheet = false
    @State private var showAddModelSheet = false
    @State private var showDeleteConfirmation = false
    @State private var editingModel: AIProviderModel?
    @Environment(\.dismiss) private var dismiss

    // Temperature state
    @State private var temperature: Double = 0.4
    @State private var isUsingDefaultTemperature = true

    private var provider: CustomProviderConfig? {
        credentialsManager.customProvider(id: providerId)
    }

    var body: some View {
        Group {
            if let provider = provider {
                providerContent(provider)
            } else {
                ContentUnavailableView("Provider Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(provider?.name ?? "Custom Provider")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    showEditSheet = true
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let provider = provider {
                CustomProviderEditView(mode: .edit(provider))
                    .themedSubSheet(sheetThemeColors)
            }
        }
        .sheet(isPresented: $showAddModelSheet) {
            AddModelSheet(providerId: providerId)
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(item: $editingModel) { model in
            EditModelSheet(providerId: providerId, model: model)
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Delete Provider", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? credentialsManager.deleteCustomProvider(id: providerId)
                dismiss()
            }
        } message: {
            Text("This will delete the provider and its API key. This cannot be undone.")
        }
        .refreshable {
            await discoverModels()
        }
        .onAppear {
            loadTemperature()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func providerContent(_ provider: CustomProviderConfig) -> some View {
        List {
            configurationSection(provider)
            authenticationSection(provider)
            temperatureSection
            modelsSection(provider)
            deleteSection
        }
        .themedList()
    }

    private func configurationSection(_ provider: CustomProviderConfig) -> some View {
        Section("Configuration") {
            LabeledContent("Endpoint", value: provider.endpointURL)
                .themedRow()
            LabeledContent("API Format", value: provider.apiFormat.displayName)
                .themedRow()
            LabeledContent("Streaming", value: provider.useStreaming ? "Enabled" : "Disabled")
                .themedRow()

            Toggle("Enabled", isOn: Binding(
                get: { provider.isEnabled },
                set: { newValue in
                    var updated = provider
                    updated.isEnabled = newValue
                    credentialsManager.updateCustomProvider(updated)
                }
            ))
            .themedRow()
        }
    }

    private func authenticationSection(_ provider: CustomProviderConfig) -> some View {
        Section("Authentication") {
            if credentialsManager.hasAPIKey(for: provider) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("API key configured")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } else {
                // Not a warning: local servers routinely accept unauthenticated requests.
                HStack {
                    Image(systemName: "lock.open")
                        .foregroundColor(.secondary)
                    Text("No API key (unauthenticated endpoint)")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }
    }

    private func modelsSection(_ provider: CustomProviderConfig) -> some View {
        Section {
            if isDiscoveringModels {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Discovering models...")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            if let error = discoveryError {
                Text(error)
                    .foregroundColor(.orange)
                    .font(.caption)
                    .themedRow()
            }

            ForEach(provider.allModels) { model in
                Button {
                    editingModel = model
                } label: {
                    ModelRow(model: model, showSource: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    if model.source == .manual {
                        Button(role: .destructive) {
                            credentialsManager.removeModel(from: providerId, modelId: model.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .themedRow()
            }

            Button(action: { showAddModelSheet = true }) {
                Label("Add Model Manually", systemImage: "plus.circle")
            }
            .themedRow()
        } header: {
            HStack {
                Text("Models")
                Spacer()
                if let lastRefresh = provider.lastModelRefresh {
                    Text("Updated \(lastRefresh, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("Pull to refresh model list from endpoint")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Provider")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    private var temperatureSection: some View {
        let defaultTemp = AICredentialsManager.defaultCustomProviderTemperature

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
                        credentialsManager.setTemperature(newValue, for: providerId)
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
                    credentialsManager.setTemperature(nil, for: providerId)
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
        let defaultTemp = AICredentialsManager.defaultCustomProviderTemperature
        if let savedTemp = credentialsManager.temperature(for: providerId) {
            temperature = savedTemp
            isUsingDefaultTemperature = false
        } else {
            temperature = defaultTemp
            isUsingDefaultTemperature = true
        }
    }

    private func discoverModels() async {
        // No API-key requirement: local endpoints are routinely unauthenticated.
        guard let provider = provider else { return }

        isDiscoveringModels = true
        discoveryError = nil

        do {
            let models = try await CustomProviderModelDiscovery.discoverModels(
                endpointURL: provider.endpointURL,
                apiFormat: provider.apiFormat,
                apiKey: credentialsManager.loadAPIKey(for: provider)
            )
            credentialsManager.updateDiscoveredModels(for: providerId, models: models)
        } catch {
            discoveryError = error.localizedDescription
        }

        isDiscoveringModels = false
    }
}

// MARK: - Add Model Sheet

struct AddModelSheet: View {
    let providerId: UUID

    @Environment(\.dismiss) private var dismiss
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var modelID = ""
    @State private var modelName = ""
    @State private var contextWindowInput = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Model ID", text: $modelID)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .themedRow()
                    TextField("Display Name", text: $modelName)
                        .themedRow()
                } header: {
                    Text("Add Custom Model")
                } footer: {
                    Text("Enter the exact model ID as expected by the API (e.g., llama3.1:70b, mixtral:8x7b)")
                }

                Section {
                    TextField("Tokens (e.g. 128000)", text: $contextWindowInput)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .themedRow()
                } header: {
                    Text("Context Window")
                } footer: {
                    Text("Optional. When set, the AI Agent shows a context-usage indicator for this model.")
                }
            }
            .themedList()
            .navigationTitle("Add Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        credentialsManager.addManualModel(to: providerId, id: modelID, displayName: modelName)
                        let tokens = Int(contextWindowInput.trimmingCharacters(in: .whitespaces))
                        credentialsManager.setContextWindowOverride(tokens, for: modelID, in: providerId)
                        dismiss()
                    }
                    .disabled(modelID.isEmpty || modelName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Edit Model Sheet

struct EditModelSheet: View {
    let providerId: UUID
    let model: AIProviderModel

    @Environment(\.dismiss) private var dismiss
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var contextWindowInput: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Model", value: model.displayName)
                        .themedRow()
                    LabeledContent("ID", value: model.id)
                        .themedRow()
                }

                Section {
                    TextField("Tokens (e.g. 128000)", text: $contextWindowInput)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .themedRow()
                    if !contextWindowInput.isEmpty {
                        Button("Clear", role: .destructive) {
                            contextWindowInput = ""
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Context Window")
                } footer: {
                    Text("Optional. When set, the AI Agent shows a context-usage indicator for this model.")
                }
            }
            .themedList()
            .navigationTitle("Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = contextWindowInput.trimmingCharacters(in: .whitespaces)
                        let tokens = trimmed.isEmpty ? nil : Int(trimmed)
                        credentialsManager.setContextWindowOverride(tokens, for: model.id, in: providerId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let existing = credentialsManager.contextWindowOverride(for: model.id, in: providerId) {
                    contextWindowInput = String(existing)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        CustomProviderDetailView(providerId: UUID())
    }
}
#endif
