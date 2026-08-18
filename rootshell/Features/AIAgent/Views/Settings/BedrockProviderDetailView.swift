#if !CHINA_BUILD
//
//  BedrockProviderDetailView.swift
//  rootshell
//
//  Detail view for configuring the AWS Bedrock provider. Unlike the
//  direct-API providers (which take a single API key), Bedrock binds to
//  an existing AWS Cloud account so the user inherits that account's
//  Access Key or SSO/STS auth automatically.
//

import SwiftUI

struct BedrockProviderDetailView: View {
    private var credentialsManager: AICredentialsManager { AICredentialsManager.shared }

    @ObservedObject private var cloudManager = CloudAccountManager.shared

    // Temperature state (mirrors AnthropicProviderDetailView's pattern).
    @State private var temperature: Double = 1.0
    @State private var isUsingDefaultTemperature = true
    @State private var showUnlinkConfirmation = false

    private var awsAccounts: [CloudAccount] {
        cloudManager.accounts(for: AWSProvider.providerID)
    }

    /// The linked AWS account's CloudAccount, if it still exists.
    /// Used both to surface its label in the picker and to detect the
    /// "linked account was deleted elsewhere" case.
    private var linkedAccount: CloudAccount? {
        guard let id = credentialsManager.bedrockCloudAccountID else { return nil }
        return cloudManager.account(for: id)
    }

    var body: some View {
        List {
            accountSection

            if credentialsManager.bedrockCloudAccountID != nil {
                regionSection
                modelsSection
                temperatureSection
                unlinkSection
            }
        }
        .themedList()
        .onAppear { loadTemperature() }
        .navigationTitle("AWS Bedrock")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Unlink AWS Account", isPresented: $showUnlinkConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) {
                credentialsManager.bedrockCloudAccountID = nil
            }
        } message: {
            Text("Bedrock will stop using this AWS account. The account itself stays in Cloud settings.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if awsAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No AWS accounts configured")
                        .foregroundStyle(.secondary)
                    Text("Add an AWS account under Settings → Connections → Cloud Providers, then return here to link it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .themedRow()
            } else {
                Picker("Account", selection: Binding<UUID?>(
                    get: { credentialsManager.bedrockCloudAccountID },
                    set: { credentialsManager.bedrockCloudAccountID = $0 }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(awsAccounts) { account in
                        Text(accountLabel(account)).tag(UUID?.some(account.id))
                    }
                }
                .themedRow()

                // Surface a warning if the linked account vanished (e.g., user
                // deleted it from Cloud settings while Bedrock was configured).
                if let linkedID = credentialsManager.bedrockCloudAccountID,
                   cloudManager.account(for: linkedID) == nil {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("The linked AWS account no longer exists. Pick another account or unlink Bedrock.")
                            .font(.caption)
                    }
                    .themedRow()
                }
            }
        } header: {
            Text("AWS Account")
        } footer: {
            Text("Bedrock signs API calls with this account's Access Key or SSO/STS credentials.")
        }
    }

    private var regionSection: some View {
        Section {
            Picker("Region", selection: Binding(
                get: { credentialsManager.bedrockRegion },
                set: { credentialsManager.bedrockRegion = $0 }
            )) {
                ForEach(BedrockRegions.regions) { region in
                    Text(BedrockRegions.displayName(for: region.id)).tag(region.id)
                }
            }
            .themedRow()
        } header: {
            Text("Region")
        } footer: {
            Text("Invocations are routed through this region. Some Anthropic models require cross-region inference profiles, which the app handles automatically.")
        }
    }

    private var modelsSection: some View {
        Section("Available Models") {
            ForEach(AIProviderModel.bedrockModels) { model in
                ModelRow(model: model)
                    .themedRow()
            }
        }
    }

    private var temperatureSection: some View {
        let defaultTemp = AICredentialsManager.defaultTemperatures[BedrockProvider.providerID] ?? 1.0

        return Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $temperature, in: 0.0...2.0, step: 0.05)
                    .onChange(of: temperature) { _, newValue in
                        credentialsManager.setTemperature(newValue, for: BedrockProvider.providerID)
                        isUsingDefaultTemperature = false
                    }

                HStack {
                    Text("Deterministic")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Creative")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            if !isUsingDefaultTemperature {
                Button("Reset to Default (\(String(format: "%.1f", defaultTemp)))") {
                    credentialsManager.setTemperature(nil, for: BedrockProvider.providerID)
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

    private var unlinkSection: some View {
        Section {
            Button(role: .destructive) {
                showUnlinkConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Unlink AWS Account")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    // MARK: - Actions

    private func accountLabel(_ account: CloudAccount) -> String {
        let methodTag: String
        switch account.authMethod {
        case .awsAccessKey: methodTag = "Access Key"
        case .awsSSO: methodTag = "SSO"
        default: methodTag = ""
        }
        return methodTag.isEmpty ? account.label : "\(account.label) · \(methodTag)"
    }

    private func loadTemperature() {
        let defaultTemp = AICredentialsManager.defaultTemperatures[BedrockProvider.providerID] ?? 1.0
        if let savedTemp = credentialsManager.temperature(for: BedrockProvider.providerID) {
            temperature = savedTemp
            isUsingDefaultTemperature = false
        } else {
            temperature = defaultTemp
            isUsingDefaultTemperature = true
        }
    }
}

#Preview {
    NavigationStack {
        BedrockProviderDetailView()
    }
}
#endif
