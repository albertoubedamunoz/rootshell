import SwiftUI

// MARK: - Account Detail View

/// Detailed view of a cloud account showing resources
struct CloudAccountDetailView: View {
    let account: CloudAccount

    @ObservedObject private var cacheManager = CloudCacheManager.shared
    @ObservedObject private var accountManager = CloudAccountManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var isRefreshing = false

    // Rename state
    @State private var showingRenameAlert = false
    @State private var editedLabel = ""

    // Kubeconfig import state
    @State private var selectedCluster: CloudKubernetesCluster?
    @State private var isImportingKubeconfig = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showImportSuccess = false

    var body: some View {
        List {
            accountInfoSection

            // Show error if sync failed
            if case .error(let message) = syncStatus {
                syncErrorSection(message: message)
            }

            resourceSummarySection

            if !instances.isEmpty {
                instancesSection
            }

            if !clusters.isEmpty {
                clustersSection
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle(currentLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refresh()
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .refreshable {
            await refreshAsync()
        }
        .overlay(alignment: .bottom) {
            if syncStatus.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Syncing...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .padding(.bottom, 8)
            }
        }
        .sheet(item: $selectedCluster) { cluster in
            KubeconfigImportSheet(
                cluster: cluster,
                accountID: account.id,
                isImporting: $isImportingKubeconfig,
                onImport: { importKubeconfig(cluster) },
                onRefresh: { refreshKubeconfig(cluster) },
                onDismiss: { selectedCluster = nil }
            )
            .presentationDetents([.medium])
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? String(localized: "An unknown error occurred", comment: "Generic error fallback message"))
        }
        .alert("Success", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Kubeconfig imported successfully")
        }
        .alert("Rename Account", isPresented: $showingRenameAlert) {
            TextField("Display Name", text: $editedLabel)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                renameAccount()
            }
            .disabled(editedLabel.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter a new display name for this account.")
        }
    }

    // MARK: - Computed Properties

    private var instances: [CloudInstance] {
        cacheManager.instances(for: account.id)
    }

    private var clusters: [CloudKubernetesCluster] {
        cacheManager.clusters(for: account.id)
    }

    private var syncStatus: CloudSyncStatus {
        cacheManager.status(for: account.id)
    }

    private var providerCapabilities: Set<CloudProviderCapability> {
        guard let providerType = CloudProviderRegistry.shared.provider(for: account.providerID) else {
            return []
        }
        return providerType.capabilities
    }

    private var instancesLabel: String {
        if providerCapabilities.contains(.networkDevices) {
            return CloudProviderCapability.networkDevices.displayName
        }
        return CloudProviderCapability.virtualMachines.displayName
    }

    private var supportsKubernetes: Bool {
        providerCapabilities.contains(.kubernetes)
    }

    // MARK: - Sync Error Section

    private func syncErrorSection(message: String) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Failed")
                        .font(.headline)

                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .themedRow()

            Button {
                refresh()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .themedRow()
        }
    }

    // MARK: - Account Info Section

    private var accountInfoSection: some View {
        Section {
            Button {
                editedLabel = currentLabel
                showingRenameAlert = true
            } label: {
                HStack {
                    Text("Display Name")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(currentLabel)
                        .foregroundColor(.secondary)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .themedRow()

            HStack {
                Text("Provider")
                Spacer()
                HStack(spacing: 8) {
                    providerIcon
                        .frame(width: 20, height: 20)
                    Text(providerDisplayName)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            HStack {
                Text("Authentication")
                Spacer()
                Text(account.authMethod.displayName)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            if let providerName = account.providerDisplayName {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(providerName)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            if let lastSync = account.lastSyncDate {
                HStack {
                    Text("Last Synced")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Account Info")
        }
    }

    /// Get the current label from the account manager (may have been updated)
    private var currentLabel: String {
        accountManager.account(for: account.id)?.label ?? account.label
    }

    // MARK: - Resource Summary Section

    private var resourceSummarySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(instances.count)")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(instancesLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if supportsKubernetes {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(clusters.count)")
                            .font(.title)
                            .fontWeight(.semibold)
                        Text("Kubernetes Clusters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .themedRow()

            // Running instances count
            let runningCount = instances.filter { $0.status == .running }.count
            if runningCount > 0 {
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text("\(runningCount) running")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Resources")
        }
    }

    // MARK: - Instances Section

    private var instancesSection: some View {
        Section {
            ForEach(instances) { instance in
                CloudInstanceRowView(instance: instance)
                    .themedRow()
            }
        } header: {
            Text("\(instancesLabel) (\(instances.count))")
        }
    }

    // MARK: - Clusters Section

    private var clustersSection: some View {
        Section {
            ForEach(clusters) { cluster in
                Button {
                    selectedCluster = cluster
                } label: {
                    CloudClusterRowView(cluster: cluster)
                }
                .buttonStyle(.plain)
                .disabled(cluster.status != .ready)
                .themedRow()
            }
        } header: {
            Text("Kubernetes Clusters (\(clusters.count))")
        }
    }

    // MARK: - Helpers

    private var providerDisplayName: String {
        switch account.providerID {
        case LinodeProvider.providerID: return LinodeProvider.displayName
        case DigitalOceanProvider.providerID: return DigitalOceanProvider.displayName
        case AWSProvider.providerID: return AWSProvider.displayName
        default: return account.providerID.capitalized
        }
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
                .font(.body)
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

    // MARK: - Actions

    private func refresh() {
        isRefreshing = true
        Task {
            await cacheManager.syncAccount(account.id)
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func refreshAsync() async {
        await cacheManager.syncAccount(account.id)
    }

    private func renameAccount() {
        let newLabel = editedLabel.trimmingCharacters(in: .whitespaces)
        guard !newLabel.isEmpty else { return }

        var updatedAccount = account
        updatedAccount.label = newLabel
        accountManager.updateAccount(updatedAccount)
    }

    // MARK: - Kubeconfig Import Actions

    private func importKubeconfig(_ cluster: CloudKubernetesCluster) {
        isImportingKubeconfig = true
        Task {
            do {
                _ = try await cacheManager.importKubeconfig(for: cluster, accountID: account.id)
                await MainActor.run {
                    isImportingKubeconfig = false
                    selectedCluster = nil
                    showImportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isImportingKubeconfig = false
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
    }

    private func refreshKubeconfig(_ cluster: CloudKubernetesCluster) {
        isImportingKubeconfig = true
        Task {
            do {
                try await cacheManager.refreshKubeconfig(for: cluster, accountID: account.id)
                await MainActor.run {
                    isImportingKubeconfig = false
                    selectedCluster = nil
                    showImportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isImportingKubeconfig = false
                    importError = error.localizedDescription
                    showImportError = true
                }
            }
        }
    }
}

// MARK: - Instance Row View

struct CloudInstanceRowView: View {
    let instance: CloudInstance

    /// For Tailscale, show "hostname (IP)"; otherwise just show IP
    private var addressDisplay: String? {
        if instance.providerID == "tailscale" {
            if let hostname = instance.hostname, let ip = instance.ipv4Address {
                return "\(hostname) (\(ip))"
            }
            return instance.hostname ?? instance.ipv4Address
        }
        return instance.ipv4Address
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Image(systemName: instance.status.iconName)
                .font(.title3)
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(instance.label)
                    .font(.body)

                HStack(spacing: 8) {
                    if let address = addressDisplay {
                        Text(address)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let region = instance.region {
                        Text(LinodeProvider.regionDisplayName(for: region))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    NetworkDeviceInlineBadges(instance: instance)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Instance type badge
            if let instanceType = instance.instanceType {
                Text(instanceType)
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

    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .stopped: return .gray
        case .provisioning, .rebooting, .migrating: return .orange
        case .unknown: return .secondary
        }
    }
}

// MARK: - Cluster Row View

struct CloudClusterRowView: View {
    let cluster: CloudKubernetesCluster

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Image(systemName: cluster.status.iconName)
                .font(.title3)
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(cluster.label)
                    .font(.body)

                HStack(spacing: 8) {
                    if let version = cluster.kubernetesVersion {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(cluster.nodeCountDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let region = cluster.region {
                        Text(LinodeProvider.regionDisplayName(for: region))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Import badge
            if cluster.isImported {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch cluster.status {
        case .ready: return .green
        case .notReady: return .red
        case .provisioning, .upgrading: return .orange
        case .deleting: return .gray
        case .unknown: return .secondary
        }
    }
}

// MARK: - Kubeconfig Import Sheet

struct KubeconfigImportSheet: View {
    let cluster: CloudKubernetesCluster
    let accountID: UUID
    @Binding var isImporting: Bool
    let onImport: () -> Void
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    /// Check if the cluster is actually imported by verifying against KubernetesClusterManager
    /// This handles the case where a kubeconfig was deleted from settings but the cloud cache is stale
    private var isActuallyImported: Bool {
        guard let apiEndpoint = cluster.apiEndpoint else { return false }
        return KubernetesClusterManager.shared.cluster(byServerURL: apiEndpoint) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Cluster info header
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)

                    Text(cluster.label)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let version = cluster.kubernetesVersion {
                        Text("Kubernetes v\(version)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top)

                // Cluster details
                VStack(alignment: .leading, spacing: 12) {
                    if let endpoint = cluster.apiEndpoint {
                        DetailRow(label: "API Endpoint", value: endpoint)
                    }

                    if let region = cluster.region {
                        DetailRow(label: "Region", value: LinodeProvider.regionDisplayName(for: region))
                    }

                    DetailRow(label: "Nodes", value: cluster.nodeCountDisplay)

                    if cluster.highAvailability {
                        DetailRow(label: "High Availability", value: "Enabled")
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Action button
                VStack(spacing: 12) {
                    if isActuallyImported {
                        Text("This cluster's kubeconfig has already been imported.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            onRefresh()
                        } label: {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(isImporting ? String(localized: "Refreshing...", comment: "Kubeconfig: refresh in progress") : String(localized: "Refresh Kubeconfig", comment: "Kubeconfig: refresh button"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting)
                    } else {
                        Text("Import the kubeconfig to manage this cluster from the app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            onImport()
                        } label: {
                            HStack {
                                if isImporting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "square.and.arrow.down")
                                }
                                Text(isImporting ? String(localized: "Importing...", comment: "Kubeconfig: import in progress") : String(localized: "Import Kubeconfig", comment: "Kubeconfig: import button"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isImporting)
                    }
                }
                .padding()
                .padding(.bottom)
            }
            .navigationTitle(isActuallyImported ? "Refresh Kubeconfig" : "Import Kubeconfig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .disabled(isImporting)
                }
            }
        }
    }
}

/// Helper view for detail rows in the import sheet
private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        CloudAccountDetailView(
            account: CloudAccount(
                providerID: "linode",
                label: "Personal Account",
                authMethod: .pat
            )
        )
    }
}
