import SwiftUI

// MARK: - WiFi AP Providers Settings View

struct WiFiAPProvidersSettingsView: View {
    @ObservedObject private var accountManager = WiFiAPAccountManager.shared
    @ObservedObject private var cacheManager = WiFiAPCacheManager.shared
    @ObservedObject private var manualAPManager = ManualAPManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var showingAddAccount = false
    @State private var accountToDelete: WiFiAPAccount?
    @State private var showingDeleteAlert = false

    var body: some View {
        List {
            if accountManager.accounts.isEmpty {
                emptyStateSection
            } else {
                accountsSection
            }

            manualAPsSection
        }
        .themedList()
        .navigationTitle("WiFi AP Providers")
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
                WiFiAPAccountAddView()
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Delete Account", isPresented: $showingDeleteAlert, presenting: accountToDelete) { account in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAccount(account)
            }
        } message: { account in
            Text("Are you sure you want to delete '\(account.label)'? This will remove the account and all cached AP data.")
        }
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "wifi.router")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("No WiFi AP Accounts")
                    .font(.headline)

                Text("Add a WiFi management account to see friendly AP names in the bssid command output.")
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
                    WiFiAPAccountDetailView(account: account)
                } label: {
                    WiFiAPAccountRowView(account: account)
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

    // MARK: - Manual APs Section

    private var manualAPsSection: some View {
        Section {
            if manualAPManager.manualAPs.isEmpty {
                NavigationLink {
                    ManualAPAddView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add Manual AP")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Associate a BSSID with a vendor and name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .themedRow()
            } else {
                ForEach(manualAPManager.manualAPs) { ap in
                    NavigationLink {
                        ManualAPDetailView(accessPoint: ap)
                    } label: {
                        ManualAPRowView(accessPoint: ap)
                    }
                    .themedRow()
                }
                .onDelete(perform: deleteManualAP)

                NavigationLink {
                    ManualAPAddView()
                } label: {
                    Label("Add Manual AP", systemImage: "plus.circle")
                }
                .themedRow()
            }
        } header: {
            Text("Manual APs")
        } footer: {
            Text("Manually associate BSSIDs with vendor and AP names for the bssid command and Live Activity.")
        }
    }

    // MARK: - Actions

    private func confirmDelete(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        accountToDelete = accountManager.accounts[index]
        showingDeleteAlert = true
    }

    private func deleteManualAP(at offsets: IndexSet) {
        manualAPManager.deleteManualAPs(at: Array(offsets))
    }

    private func deleteAccount(_ account: WiFiAPAccount) {
        do {
            cacheManager.clearCache(for: account.id)
            try accountManager.deleteAccount(id: account.id)
        } catch {
            // Handle error silently - already logged in manager
        }
    }
}

// MARK: - Account Row View

struct WiFiAPAccountRowView: View {
    let account: WiFiAPAccount

    @ObservedObject private var cacheManager = WiFiAPCacheManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: providerIconName)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.label)
                    .font(.body)

                HStack(spacing: 4) {
                    statusBadge
                    Text(cacheManager.status(for: account.id).displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(account.authMethod.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var providerIconName: String {
        switch account.providerID {
        case UbiquitiProvider.providerID: return UbiquitiProvider.iconName
        default: return "wifi.router"
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
}

// MARK: - Manual AP Row View

struct ManualAPRowView: View {
    let accessPoint: WiFiAccessPoint

    var body: some View {
        HStack(spacing: 12) {
            let domain = ManualAPManager.shared.vendorDomain(forMAC: accessPoint.mac)
            if let domain {
                FaviconImage(domain: domain, size: 32)
            } else {
                Image(systemName: "wifi")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(accessPoint.name)
                    .font(.body)

                Text(accessPoint.mac)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let model = accessPoint.shortname ?? accessPoint.model {
                Text(model)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
