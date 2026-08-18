#if !CHINA_BUILD
//
//  OpenAIProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring OpenAI provider: metered API key or
//  ChatGPT subscription sign-in.
//

import SwiftUI

struct OpenAIProviderDetailView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }
    private var modelStore: ChatGPTModelStore { ChatGPTModelStore.shared }

    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var saveError: String?
    @State private var showDeleteConfirmation = false

    // Temperature state
    @State private var temperature: Double = 0.4
    @State private var isUsingDefaultTemperature = true

    // ChatGPT sign-in state
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var accountEmail: String?
    @State private var accountPlan: String?
    @State private var authCoordinator: ChatGPTAuthCoordinator?
    @State private var showSignOutConfirmation = false

    /// Check if the currently selected model supports temperature
    private var selectedModelSupportsTemperature: Bool {
        let selectedModelID = credentialsManager.selectedModelID(for: OpenAIProvider.providerID)
        let model = AIProviderModel.openAIModel(id: selectedModelID)
        return model?.supportsTemperature ?? true
    }

    private var authModeBinding: Binding<OpenAIAuthMode> {
        Binding(
            get: { credentialsManager.openAIAuthMode },
            set: { credentialsManager.openAIAuthMode = $0 }
        )
    }

    var body: some View {
        List {
            authModeSection

            switch credentialsManager.openAIAuthMode {
            case .apiKey:
                apiKeySection

                if credentialsManager.hasAPIKey(for: OpenAIProvider.providerID) {
                    modelsSection
                    temperatureSection
                    deleteSection
                }

            case .chatgptSignIn:
                if credentialsManager.hasChatGPTSignIn {
                    chatGPTAccountSection
                    chatGPTModelsSection
                    chatGPTSignOutSection
                } else {
                    chatGPTSignInSection
                }
            }
        }
        .themedList()
        .onAppear {
            loadTemperature()
        }
        .task(id: credentialsManager.hasChatGPTSignIn) {
            guard credentialsManager.hasChatGPTSignIn else { return }
            await loadAccountSummary()
            await modelStore.refreshIfStale()
        }
        .navigationTitle("OpenAI")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete API Key", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? credentialsManager.deleteAPIKey(for: OpenAIProvider.providerID)
                apiKeyInput = ""
            }
        } message: {
            Text("This will remove your OpenAI API key. You'll need to enter it again to use OpenAI models.")
        }
        .alert("Sign Out of ChatGPT", isPresented: $showSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                signOut()
            }
        } message: {
            Text("This will remove the ChatGPT sign-in from this device. Your subscription is unaffected.")
        }
    }

    // MARK: - Auth Mode

    private var authModeSection: some View {
        Section {
            Picker("Access", selection: authModeBinding) {
                ForEach(OpenAIAuthMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
        } footer: {
            Text(credentialsManager.openAIAuthMode == .apiKey
                 ? "Pay-per-token access with an API key from platform.openai.com."
                 : "Uses your ChatGPT Plus/Pro subscription instead of a metered API key.")
        }
    }

    // MARK: - API Key Sections

    private var apiKeySection: some View {
        Section {
            HStack {
                if showKey {
                    TextField("sk-...", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } else {
                    SecureField("sk-...", text: $apiKeyInput)
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

            if credentialsManager.hasAPIKey(for: OpenAIProvider.providerID) && apiKeyInput.isEmpty {
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
            Text("Get your API key from platform.openai.com")
        }
    }

    private var modelsSection: some View {
        Section("Available Models") {
            ForEach(AIProviderModel.openAIModels) { model in
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
        let defaultTemp = AICredentialsManager.defaultTemperatures[OpenAIProvider.providerID] ?? 0.4
        let supportsTemp = selectedModelSupportsTemperature

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
                    .disabled(!supportsTemp)
                    .onChange(of: temperature) { _, newValue in
                        credentialsManager.setTemperature(newValue, for: OpenAIProvider.providerID)
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
            .opacity(supportsTemp ? 1.0 : 0.5)
            .themedRow()

            if !supportsTemp {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("The selected OpenAI model doesn't support temperature adjustment")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            } else if !isUsingDefaultTemperature {
                Button("Reset to Default (\(String(format: "%.1f", defaultTemp)))") {
                    credentialsManager.setTemperature(nil, for: OpenAIProvider.providerID)
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

    // MARK: - ChatGPT Sections

    private var chatGPTSignInSection: some View {
        Section {
            if let error = signInError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            Button {
                signIn()
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Waiting for ChatGPT…")
                    } else {
                        Image("CodexLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text("Sign in with ChatGPT")
                    }
                }
            }
            .disabled(isSigningIn)
            .themedRow()

            if isSigningIn {
                Button("Cancel Sign-In", role: .cancel) {
                    authCoordinator?.cancel()
                }
                .font(.caption)
                .themedRow()
            }
        } header: {
            Text("ChatGPT Account")
        } footer: {
            Text("Signs in through OpenAI in Safari. Requires a ChatGPT plan that includes Codex model access (Plus, Pro, or Team).")
        }
    }

    private var chatGPTAccountSection: some View {
        Section("ChatGPT Account") {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountEmail ?? "Signed in")
                    if let plan = accountPlan {
                        Text(plan.capitalized + " plan")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .themedRow()
        }
    }

    private var chatGPTModelsSection: some View {
        Section {
            ForEach(modelStore.models) { model in
                ChatGPTModelEffortRow(model: model)
                    .themedRow()
            }

            Button {
                Task { await modelStore.refresh() }
            } label: {
                HStack {
                    if modelStore.isRefreshing {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Text("Refresh Models")
                }
            }
            .disabled(modelStore.isRefreshing)
            .themedRow()
        } header: {
            Text("Available Models")
        } footer: {
            Text(modelStore.isUsingFallback
                 ? "Showing the built-in list until the lineup is fetched from your subscription."
                 : "Reasoning level applies per model and can also be changed from the model picker.")
        }
    }

    private var chatGPTSignOutSection: some View {
        Section {
            Button(role: .destructive) {
                showSignOutConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Sign Out of ChatGPT")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    // MARK: - Actions

    private func loadTemperature() {
        let defaultTemp = AICredentialsManager.defaultTemperatures[OpenAIProvider.providerID] ?? 0.4
        if let savedTemp = credentialsManager.temperature(for: OpenAIProvider.providerID) {
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

        guard apiKeyInput.hasPrefix("sk-") else {
            saveError = "Invalid API key format (should start with sk-)"
            return
        }

        do {
            try credentialsManager.saveAPIKey(apiKeyInput, for: OpenAIProvider.providerID)
            apiKeyInput = ""
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil

        let coordinator = ChatGPTAuthCoordinator()
        authCoordinator = coordinator

        Task {
            defer {
                isSigningIn = false
                authCoordinator = nil
            }
            do {
                let credentials = try await coordinator.signIn()
                await ChatGPTCredentialStore.shared.save(credentials)
                accountEmail = credentials.email
                accountPlan = credentials.planType
                credentialsManager.setChatGPTSignedIn(true)
                await modelStore.refresh()
            } catch ChatGPTAuthError.cancelled {
                // User dismissed the sheet; not an error worth a banner.
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    private func signOut() {
        Task {
            await ChatGPTCredentialStore.shared.clear()
            accountEmail = nil
            accountPlan = nil
            // Keep the cached model list so a re-sign-in is instant.
            credentialsManager.setChatGPTSignedIn(false)
        }
    }

    private func loadAccountSummary() async {
        guard let credentials = await ChatGPTCredentialStore.shared.credentials() else { return }
        accountEmail = credentials.email
        accountPlan = credentials.planType
    }
}

// MARK: - ChatGPT model row

/// A discovered model with its per-model reasoning-level picker. nil selection
/// means "no override": the model's server-reported default applies.
private struct ChatGPTModelEffortRow: View {
    let model: CachedChatGPTModel

    @State private var selection: ChatGPTReasoningEffort?

    private var defaultEffort: ChatGPTReasoningEffort {
        ChatGPTReasoningSettings.defaultEffort(for: model.id)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text("\(model.contextWindow / 1000)K context")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker("", selection: $selection) {
                Text("Default (\(defaultEffort.displayName))")
                    .tag(ChatGPTReasoningEffort?.none)
                ForEach(model.supportedEfforts, id: \.self) { effort in
                    Text(effort.displayName).tag(ChatGPTReasoningEffort?.some(effort))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .onAppear {
            selection = ChatGPTReasoningSettings.storedEffort(for: model.id)
        }
        .onChange(of: selection) { _, newValue in
            ChatGPTReasoningSettings.setEffort(newValue, for: model.id)
        }
    }
}

#Preview {
    NavigationStack {
        OpenAIProviderDetailView()
    }
}
#endif
