#if !CHINA_BUILD
//
//  OpenAIProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring OpenAI provider: metered API key or
//  ChatGPT plan usage through Sign in with ChatGPT.
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
    @State private var accounts: ChatGPTAccountsSnapshot?
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var authCoordinator: ChatGPTAuthCoordinator?
    @State private var showSignOutConfirmation = false
    @State private var showPlanWelcome = false
    @State private var showRevocationUnconfirmed = false
    @State private var needsReconnect = UserDefaults.standard.bool(forKey: ChatGPTCredentialStore.needsReconnectKey)

    @Environment(\.openURL) private var openURL

    private static let planWelcomeShownKey = "ai.chatgpt.planWelcomeShown"

    /// The active account while it holds a session.
    private var activeAccount: ChatGPTRegistration? {
        accounts?.active.flatMap { $0.isSignedIn ? $0 : nil }
    }

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
                if let active = activeAccount {
                    chatGPTAccountSection(active)
                    if active.canUsePlan {
                        chatGPTModelsSection
                    } else {
                        chatGPTPlanDisabledSection(active)
                    }
                    chatGPTOtherAccountsSection(active)
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
            await loadAccounts()
            guard credentialsManager.hasChatGPTSignIn else { return }
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
            Text("rootshell will stop using your ChatGPT plan on this device. To disconnect rootshell completely, go to ChatGPT Settings → Security and login.")
        }
        .alert("You're using your ChatGPT plan", isPresented: $showPlanWelcome) {
            Button("Got it", role: .cancel) {}
            Button("Manage Usage") {
                openURL(ChatGPTOAuth.manageUsageURL)
            }
        } message: {
            Text("Eligible usage in this app uses your ChatGPT plan. Manage usage in your ChatGPT settings.")
        }
        .alert("Signed Out on This Device", isPresented: $showRevocationUnconfirmed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("OpenAI didn't confirm that the session was revoked. You can disconnect rootshell in ChatGPT Settings → Security and login.")
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
                 : "Uses your ChatGPT plan instead of a metered API key.")
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
        let saved = accounts?.saved ?? []

        return Section {
            if needsReconnect {
                Label("ChatGPT sign-in has changed. Continue with ChatGPT to reconnect your account.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }

            if let error = signInError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            ForEach(saved) { registration in
                Button {
                    if registration.isSignedIn {
                        switchAccount(to: registration)
                    } else {
                        signIn(.existing(registration, forceConsent: false))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(registration.isSignedIn ? "Switch to \(registration.label)" : "Continue as \(registration.label)")
                        if let email = registration.email, email != registration.label {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(isSigningIn)
                .themedRow()
            }

            Button {
                signIn(.newAccount)
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Waiting for ChatGPT…")
                    } else {
                        Image("OpenAILogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text(saved.isEmpty ? "Continue with ChatGPT" : "Use a Different Account")
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
            Text("Use your ChatGPT plan")
        } footer: {
            Text("Complete eligible AI requests in rootshell with usage included in your ChatGPT plan or credits balance. rootshell is free and doesn't charge for this. Signs in through OpenAI in Safari.")
        }
    }

    private func chatGPTAccountSection(_ account: ChatGPTRegistration) -> some View {
        Section {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                    if let email = account.email, email != account.label {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .themedRow()

            if account.canUsePlan {
                HStack {
                    Text("Using ChatGPT plan")
                        .foregroundColor(.secondary)
                    Spacer()
                    Link("Manage usage", destination: ChatGPTOAuth.manageUsageURL)
                }
                .themedRow()
            }
        } header: {
            Text("ChatGPT Account")
        } footer: {
            if account.canUsePlan {
                Text("Eligible AI requests use your ChatGPT plan. Review usage and set a limit for rootshell in ChatGPT settings.")
            }
        }
    }

    /// Signed in, but the plan-usage scope wasn't granted.
    private func chatGPTPlanDisabledSection(_ account: ChatGPTRegistration) -> some View {
        Section {
            Label("ChatGPT plan use isn't enabled for this account.", systemImage: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .themedRow()

            if let error = signInError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .themedRow()
            }

            Button {
                signIn(.existing(account, forceConsent: true))
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                            .padding(.trailing, 4)
                    }
                    Text("Enable ChatGPT Plan")
                }
            }
            .disabled(isSigningIn)
            .themedRow()

            Button("Use an API Key Instead") {
                credentialsManager.openAIAuthMode = .apiKey
            }
            .themedRow()
        } header: {
            Text("ChatGPT Plan")
        } footer: {
            Text("rootshell needs your permission to use your ChatGPT plan for AI requests. You can also pay per token with your own API key.")
        }
    }

    private func chatGPTOtherAccountsSection(_ active: ChatGPTRegistration) -> some View {
        let others = (accounts?.saved ?? []).filter { $0.clientID != active.clientID }

        return Section {
            ForEach(others) { registration in
                Button {
                    if registration.isSignedIn {
                        switchAccount(to: registration)
                    } else {
                        signIn(.existing(registration, forceConsent: false))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(registration.isSignedIn ? "Switch to \(registration.label)" : "Continue as \(registration.label)")
                        if let email = registration.email, email != registration.label {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(isSigningIn)
                .themedRow()
            }

            Button {
                signIn(.newAccount)
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Waiting for ChatGPT…")
                    } else {
                        Text("Use a Different Account")
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
            Text("Other Accounts")
        } footer: {
            Text("Add another ChatGPT account or workspace. Each keeps its own sign-in.")
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

            if let error = modelStore.refreshError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .themedRow()
            }
        } header: {
            Text("Available Models")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if modelStore.isUsingFallback {
                    Text("Showing the built-in list until the models are fetched from your ChatGPT account.")
                } else if let refreshed = modelStore.lastRefreshed {
                    Text("Models updated \(refreshed.formatted(date: .abbreviated, time: .shortened)).")
                }
                Text("Reasoning level applies per model and can also be changed from the model picker.")
            }
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

    private func signIn(_ target: ChatGPTSignInTarget) {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil

        let coordinator = ChatGPTAuthCoordinator()
        authCoordinator = coordinator
        let previousClientID = accounts?.active?.clientID

        Task {
            defer {
                isSigningIn = false
                authCoordinator = nil
            }
            do {
                let result = try await coordinator.signIn(target)
                let stored = await ChatGPTCredentialStore.shared.install(result)
                needsReconnect = false
                await loadAccounts()
                if stored.clientID != previousClientID {
                    modelStore.resetToFallback()
                }
                credentialsManager.setChatGPTSignedIn(stored.canUsePlan)

                guard stored.canUsePlan else { return }
                if !UserDefaults.standard.bool(forKey: Self.planWelcomeShownKey) {
                    UserDefaults.standard.set(true, forKey: Self.planWelcomeShownKey)
                    showPlanWelcome = true
                }
                await modelStore.refresh()
            } catch ChatGPTAuthError.cancelled {
                // User dismissed the sheet; not an error worth a banner.
            } catch {
                signInError = error.localizedDescription
            }
        }
    }

    private func switchAccount(to registration: ChatGPTRegistration) {
        Task {
            guard await ChatGPTCredentialStore.shared.activate(clientID: registration.clientID) else { return }
            await loadAccounts()
            modelStore.resetToFallback()
            credentialsManager.setChatGPTSignedIn(registration.canUsePlan)
            if registration.canUsePlan {
                await modelStore.refresh()
            }
        }
    }

    private func signOut() {
        Task {
            // Stop requests first; revocation is a network round trip.
            credentialsManager.setChatGPTSignedIn(false)
            let confirmed = await ChatGPTCredentialStore.shared.signOut()
            await loadAccounts()
            if !confirmed {
                showRevocationUnconfirmed = true
            }
        }
    }

    private func loadAccounts() async {
        accounts = await ChatGPTCredentialStore.shared.snapshot()
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
