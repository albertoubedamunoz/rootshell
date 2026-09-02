//
//  AIAgentSettingsView.swift
//  rootshell
//
//  Settings view for AI Agent configuration - Provider list with navigation
//

import SwiftUI

struct AIAgentSettingsView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @State private var showAddCustomProvider = false
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        List {
            providersSection
            customProvidersSection
            webSearchSection
            #if !targetEnvironment(macCatalyst)
            gitCommitSection
            #endif
            displayModeSection
            usageSection
        }
        .themedList()
        .navigationTitle("AI Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddCustomProvider = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddCustomProvider) {
            CustomProviderEditView(mode: .add)
                .themedSubSheet(sheetThemeColors)
        }
    }

    // MARK: - Sections

    private var providersSection: some View {
        Section("Providers") {
            NavigationLink {
                OpenAIProviderDetailView()
            } label: {
                AIProviderRow(
                    name: "OpenAI",
                    isConfigured: credentialsManager.hasOpenAIProviderConfigured,
                    modelCount: credentialsManager.openAIAuthMode == .chatgptSignIn
                        ? ChatGPTModelStore.shared.models.count
                        : AIProviderModel.openAIModels.count,
                    imageName: credentialsManager.openAIAuthMode == .chatgptSignIn
                        ? "CodexLogo"
                        : "OpenAILogo"
                )
            }
            .themedRow()

            NavigationLink {
                AnthropicProviderDetailView()
            } label: {
                AIProviderRow(
                    name: "Anthropic",
                    isConfigured: credentialsManager.hasAnthropicAPIKey,
                    modelCount: AIProviderModel.anthropicModels.count,
                    imageName: "AnthropicLogo"
                )
            }
            .themedRow()

            NavigationLink {
                BedrockProviderDetailView()
            } label: {
                AIProviderRow(
                    name: "AWS Bedrock",
                    isConfigured: credentialsManager.hasBedrockConfigured,
                    modelCount: AIProviderModel.bedrockModels.count,
                    imageName: "AWSLogo"
                )
            }
            .themedRow()

            NavigationLink {
                GeminiProviderDetailView()
            } label: {
                AIProviderRow(
                    name: "Google",
                    isConfigured: credentialsManager.hasGoogleAPIKey,
                    modelCount: AIProviderModel.googleModels.count,
                    imageName: "GoogleLogo"
                )
            }
            .themedRow()

            NavigationLink {
                OpenRouterProviderDetailView()
            } label: {
                AIProviderRow(
                    name: "OpenRouter",
                    isConfigured: credentialsManager.hasOpenRouterAPIKey,
                    modelCount: credentialsManager.openRouterFavoriteModels.count,
                    imageName: "OpenRouterLogo"
                )
            }
            .themedRow()
        }
    }

    private var customProvidersSection: some View {
        Section {
            if credentialsManager.customProviders.isEmpty {
                Text("No custom providers configured")
                    .foregroundColor(.secondary)
                    .themedRow()
            } else {
                ForEach(credentialsManager.customProviders) { provider in
                    NavigationLink {
                        CustomProviderDetailView(providerId: provider.id)
                    } label: {
                        AIProviderRow(
                            name: provider.name,
                            // An unauthenticated endpoint with models is configured too.
                            isConfigured: credentialsManager.hasAPIKey(for: provider) || !provider.allModels.isEmpty,
                            modelCount: provider.allModels.count,
                            isEnabled: provider.isEnabled,
                            systemImage: "server.rack"
                        )
                    }
                    .themedRow()
                }
                .onDelete(perform: deleteCustomProviders)
            }
        } header: {
            Text("Custom Providers")
        } footer: {
            Text("Connect to OpenAI-compatible endpoints (Ollama, vLLM, LMStudio, etc.)")
        }
    }

    private var webSearchSection: some View {
        Section {
            SettingToggle(
                Settings.AI.webSearchEnabled,
                isOn: Binding(
                    get: { credentialsManager.webSearchEnabled },
                    set: { credentialsManager.webSearchEnabled = $0 }
                ),
                title: "Enable Web Search"
            )
            .themedRow()

            if credentialsManager.webSearchEnabled {
                Picker(selection: Binding(
                    get: { credentialsManager.defaultSearchEngine },
                    set: { credentialsManager.defaultSearchEngine = $0 }
                )) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                } label: {
                    Text("Default Engine")
                        .settingRow(Settings.AI.webSearchEngine)
                }
                .themedRow()
            }
        } header: {
            SettingGroupHeader("Web Search", group: .ai)
        } footer: {
            Text("Allow AI agent to search the web for documentation and solutions")
        }
    }

    private var gitCommitSection: some View {
        Section {
            SettingToggle(
                Settings.AI.commitMessageEnabled,
                isOn: Binding(
                    get: { credentialsManager.aiCommitMessageEnabled },
                    set: { credentialsManager.aiCommitMessageEnabled = $0 }
                ),
                title: "AI Commit Messages"
            )
            .themedRow()

            if credentialsManager.aiCommitMessageEnabled {
                let available = credentialsManager.allAvailableModels
                if available.isEmpty {
                    Text("No AI providers configured")
                        .foregroundStyle(.secondary)
                        .themedRow()
                } else {
                    Picker(selection: Binding(
                        get: { credentialsManager.aiCommitMessageModelID },
                        set: { credentialsManager.aiCommitMessageModelID = $0 }
                    )) {
                        Text("Select a model").tag("")
                        ForEach(available, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    } label: {
                        Text("Model")
                            .settingRow(Settings.AI.commitMessageModel)
                    }
                    .themedRow()
                }
            }
        } header: {
            SettingGroupHeader("Git Integration", group: .ai)
        } footer: {
            Text("When running git commit, generate a message from staged changes using the selected AI model")
        }
    }

    @ViewBuilder
    private var displayModeSection: some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        // Only show display mode options on iPad/Mac Catalyst (not iPhone)
        if UIDevice.current.userInterfaceIdiom != .phone {
            Section {
                Picker("Presentation", selection: Binding(
                    get: { credentialsManager.aiAgentPresentationMode },
                    set: { credentialsManager.aiAgentPresentationMode = $0 }
                )) {
                    ForEach(AIAgentPresentationMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .settingRow(Settings.AI.presentationMode)
                .themedRow()
            } header: {
                SettingGroupHeader("Display Mode", group: .ai)
            } footer: {
                Text(credentialsManager.aiAgentPresentationMode.description)
            }
        }
        #endif
    }

    private var usageSection: some View {
        Section("Usage") {
            VStack(alignment: .leading, spacing: 8) {
                Label("How to Launch", systemImage: "sparkles")
                VStack(alignment: .leading, spacing: 4) {
                    Label("Press ⌘I on a hardware keyboard", systemImage: "keyboard")
                        .font(.caption)
                    Label("Tap the AI Agent button on the keyboard toolbar", systemImage: "sparkles")
                        .font(.caption)
                    #if targetEnvironment(macCatalyst)
                    Label("Right-click the terminal for the context menu", systemImage: "cursorarrow.click.2")
                        .font(.caption)
                    #else
                    Label("Double-tap or long-press for the context menu", systemImage: "hand.tap")
                        .font(.caption)
                    #endif
                }
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .themedRow()

            VStack(alignment: .leading, spacing: 8) {
                Label("Command Approval", systemImage: "checkmark.shield")
                Text("All commands require your approval before execution")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .themedRow()

            VStack(alignment: .leading, spacing: 8) {
                Label("SSH & Local Shell", systemImage: "network")
                Text("AI Agent works with SSH and local shell sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .themedRow()
        }
    }

    // MARK: - Actions

    private func deleteCustomProviders(at offsets: IndexSet) {
        for index in offsets {
            let provider = credentialsManager.customProviders[index]
            try? credentialsManager.deleteCustomProvider(id: provider.id)
        }
    }
}

#Preview {
    NavigationStack {
        AIAgentSettingsView()
    }
}
