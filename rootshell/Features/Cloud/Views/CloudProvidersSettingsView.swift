import SwiftUI

// MARK: - Cloud Providers Settings View

/// Main settings view for cloud providers
struct CloudProvidersSettingsView: View {
    @ObservedObject private var accountManager = CloudAccountManager.shared
    @ObservedObject private var cacheManager = CloudCacheManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var showingAddAccount = false
    @State private var accountToDelete: CloudAccount?
    @State private var showingDeleteAlert = false

    var body: some View {
        List {
            if accountManager.accounts.isEmpty {
                emptyStateSection
            } else {
                accountsSection
            }

            aboutSection
        }
        .themedList()
        .navigationTitle("Cloud Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddAccount = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            NavigationView {
                CloudAccountAddView()
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Delete Account", isPresented: $showingDeleteAlert, presenting: accountToDelete) { account in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAccount(account)
            }
        } message: { account in
            Text("Are you sure you want to delete '\(account.label)'? This will remove the account and all cached data.")
        }
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "cloud")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("No Cloud Accounts")
                    .font(.headline)

                Text("Add a cloud provider account for quick connect autocomplete and Kubernetes kubeconfig import.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    showingAddAccount = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Account")
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .themedRow()
        }
    }

    // MARK: - Accounts Section

    private var accountsSection: some View {
        Section {
            ForEach(accountManager.accounts) { account in
                NavigationLink {
                    CloudAccountDetailView(account: account)
                } label: {
                    CloudAccountRowView(account: account)
                }
                .themedRow()
            }
            .onDelete(perform: confirmDelete)
        } header: {
            Text("Accounts")
        } footer: {
            Text("\(accountManager.accounts.count) account\(accountManager.accounts.count == 1 ? "" : "s") configured")
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section {
            Text("Cloud providers enable quick connect autocomplete for your VMs and kubeconfig import for Kubernetes clusters.")
                .font(.caption)
                .foregroundColor(.secondary)
                .themedRow()
        }
    }

    // MARK: - Actions

    private func confirmDelete(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        accountToDelete = accountManager.accounts[index]
        showingDeleteAlert = true
    }

    private func deleteAccount(_ account: CloudAccount) {
        do {
            cacheManager.clearCache(for: account.id)
            try accountManager.deleteAccount(id: account.id)
        } catch {
            // Handle error
        }
    }
}

// MARK: - Account Row View

struct CloudAccountRowView: View {
    let account: CloudAccount

    @ObservedObject private var cacheManager = CloudCacheManager.shared

    var body: some View {
        HStack(spacing: 12) {
            // Provider icon
            providerIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                // Label
                Text(account.label)
                    .font(.body)

                // Status
                HStack(spacing: 4) {
                    statusBadge
                    Text(cacheManager.status(for: account.id).displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Auth method badge
            authMethodBadge
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let logoImage = providerLogoImageName {
            Image(logoImage)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: providerIconName)
                .font(.title2)
                .foregroundColor(.accentColor)
        }
    }

    private var providerLogoImageName: String? {
        switch account.providerID {
        case LinodeProvider.providerID: return LinodeProvider.logoImageName
        case DigitalOceanProvider.providerID: return DigitalOceanProvider.logoImageName
        case AWSProvider.providerID: return AWSProvider.logoImageName
        case AzureProvider.providerID: return AzureProvider.logoImageName
        case TailscaleProvider.providerID: return TailscaleProvider.logoImageName
        case NetbirdProvider.providerID: return NetbirdProvider.logoImageName
        default: return nil
        }
    }

    private var providerIconName: String {
        switch account.providerID {
        case LinodeProvider.providerID: return LinodeProvider.iconName
        case DigitalOceanProvider.providerID: return DigitalOceanProvider.iconName
        case AWSProvider.providerID: return AWSProvider.iconName
        case AzureProvider.providerID: return AzureProvider.iconName
        case TailscaleProvider.providerID: return TailscaleProvider.iconName
        case NetbirdProvider.providerID: return NetbirdProvider.iconName
        default: return "cloud"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let status = cacheManager.status(for: account.id)
        switch status {
        case .idle:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .syncing:
            ProgressView()
                .scaleEffect(0.7)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }

    private var authMethodBadge: some View {
        let badgeText: String = {
            switch account.authMethod {
            case .pat: return "PAT"
            case .oauth: return "OAuth"
            case .awsAccessKey: return "Access Key"
            case .awsSSO: return "SSO"
            case .azureDeviceCode: return "Microsoft"
            case .tailscaleClientCredentials: return "OAuth"
            }
        }()

        return Text(badgeText)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        CloudProvidersSettingsView()
    }
}
