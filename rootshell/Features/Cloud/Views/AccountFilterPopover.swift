import SwiftUI

/// Popover for multi-selecting cloud accounts to filter console instances
struct AccountFilterPopover: View {
    let accounts: [CloudAccount]
    @Binding var selectedAccountIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var cacheManager = CloudCacheManager.shared

    var body: some View {
        NavigationStack {
            List {
                // Quick actions
                Section {
                    Button(action: selectAll) {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    .themedRow()
                    Button(action: deselectAll) {
                        Label("Deselect All", systemImage: "circle")
                    }
                    .themedRow()
                }

                // Account list with checkboxes
                Section("Accounts") {
                    ForEach(accounts) { account in
                        AccountFilterRow(
                            account: account,
                            isSelected: isAccountSelected(account.id),
                            onToggle: { toggleAccount(account.id) }
                        )
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Filter Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .frame(minWidth: 320, minHeight: 400)
    }

    // Empty set means all accounts are selected
    private func isAccountSelected(_ accountID: UUID) -> Bool {
        selectedAccountIDs.isEmpty || selectedAccountIDs.contains(accountID)
    }

    private func toggleAccount(_ accountID: UUID) {
        if selectedAccountIDs.isEmpty {
            // Currently showing all - switch to showing all except this one
            selectedAccountIDs = Set(accounts.map { $0.id })
            selectedAccountIDs.remove(accountID)
        } else if selectedAccountIDs.contains(accountID) {
            selectedAccountIDs.remove(accountID)
            // If removing last one, keep it (can't have none selected)
            if selectedAccountIDs.isEmpty {
                selectedAccountIDs.insert(accountID)
            }
        } else {
            selectedAccountIDs.insert(accountID)
            // If all are now selected, switch to empty set (means all)
            if selectedAccountIDs.count == accounts.count {
                selectedAccountIDs.removeAll()
            }
        }
    }

    private func selectAll() {
        selectedAccountIDs.removeAll()
    }

    private func deselectAll() {
        // Keep at least one selected - keep first account
        if let first = accounts.first {
            selectedAccountIDs = [first.id]
        }
    }
}

// MARK: - Account Filter Row

/// A row in the account filter popover showing account with checkbox
struct AccountFilterRow: View {
    let account: CloudAccount
    let isSelected: Bool
    let onToggle: () -> Void

    @ObservedObject private var cacheManager = CloudCacheManager.shared

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.title3)

                // Provider icon
                providerIcon
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                        .font(.body)
                        .foregroundColor(.primary)

                    // Status + VM count
                    HStack(spacing: 4) {
                        statusBadge
                        Text(vmCountText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var vmCountText: String {
        let count = cacheManager.instanceCount(for: account.id)
        return "\(count) VM\(count == 1 ? "" : "s")"
    }

    // MARK: - Provider Icon

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

    // MARK: - Status Badge

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

#Preview {
    AccountFilterPopover(
        accounts: [],
        selectedAccountIDs: .constant([])
    )
}
