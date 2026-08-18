import SwiftUI

// MARK: - WiFi AP Account Detail View

struct WiFiAPAccountDetailView: View {
    let account: WiFiAPAccount

    @ObservedObject private var cacheManager = WiFiAPCacheManager.shared
    @ObservedObject private var accountManager = WiFiAPAccountManager.shared
    @ObservedObject private var radioScanner = WiFiAPRadioScanner.shared
    @ObservedObject private var radioCacheManager = WiFiAPRadioCacheManager.shared

    @State private var isRefreshing = false
    @State private var showingRenameAlert = false
    @State private var editedLabel = ""
    @State private var cachedSSHCredentials: WiFiAPCredentials?

    var body: some View {
        List {
            accountInfoSection

            if case .error(let message) = syncStatus {
                syncErrorSection(message: message)
            }

            resourceSummarySection

            radioScanningSection

            if !accessPoints.isEmpty {
                accessPointsSection
            }
        }
        .themedList()
        .navigationTitle(currentLabel)
        .navigationBarTitleDisplayMode(.inline)
        .hostKeyPromptAlerts(radioScanner.hostKeyPrompt)
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
        .onAppear { refreshSSHCredentials() }
        .refreshable {
            await cacheManager.syncAccount(account.id)
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

    private var accessPoints: [WiFiAccessPoint] {
        cacheManager.accessPoints(for: account.id).filter { $0.isWirelessAP ?? false }
    }

    private var syncStatus: WiFiAPSyncStatus {
        cacheManager.status(for: account.id)
    }

    private var currentLabel: String {
        accountManager.account(for: account.id)?.label ?? account.label
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
                    Image(systemName: providerIconName)
                        .font(.body)
                        .foregroundColor(.accentColor)
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

    // MARK: - Resource Summary Section

    private var resourceSummarySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(accessPoints.count)")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Access Points")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .themedRow()

            let onlineCount = accessPoints.filter { $0.status == "online" }.count
            if onlineCount > 0 {
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text("\(onlineCount) online")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Resources")
        }
    }

    // MARK: - Access Points Section

    private var accessPointsSection: some View {
        Section {
            ForEach(accessPoints) { ap in
                WiFiAPRowView(accessPoint: ap)
                    .themedRow()
            }
        } header: {
            Text("Access Points (\(accessPoints.count))")
        }
    }

    // MARK: - Radio Scanning Section

    private var hasSSHConfig: Bool {
        guard let creds = cachedSSHCredentials else { return false }
        return creds.sshUsername != nil && !creds.sshUsername!.isEmpty && creds.sshKeyID != nil
    }

    private func refreshSSHCredentials() {
        cachedSSHCredentials = try? accountManager.getCredentials(for: account.id)
    }

    private var radioScanningSection: some View {
        Section {
            // SSH config status
            HStack {
                Text("SSH Username")
                Spacer()
                Text(cachedSSHCredentials?.sshUsername ?? "Not configured")
                    .foregroundColor(.secondary)
            }
            .themedRow()

            HStack {
                Text("SSH Key")
                Spacer()
                Text(sshKeyName ?? "Not configured")
                    .foregroundColor(.secondary)
            }
            .themedRow()

            NavigationLink("Configure SSH") {
                WiFiAPSSHConfigView(accountID: account.id)
            }
            .themedRow()

            // Scan button
            Button {
                Task {
                    await radioScanner.scanAllAPs(for: account.id)
                }
            } label: {
                HStack {
                    Text("Scan AP Radios")
                    Spacer()
                    scanStatusView
                }
            }
            .disabled(!hasSSHConfig || radioScanner.scanStatus.isScanning)
            .themedRow()

            // Last scan date
            if let lastScan = radioCacheManager.lastScanDate[account.id] {
                HStack {
                    Text("Last Scanned")
                    Spacer()
                    Text(lastScan, style: .relative)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Radio Scanning")
        }
    }

    @ViewBuilder
    private var scanStatusView: some View {
        switch radioScanner.scanStatus {
        case .idle:
            EmptyView()
        case .scanning(let progress, let total):
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("\(progress)/\(total)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .success(let radioCount):
            Text("\(radioCount) radios")
                .font(.caption)
                .foregroundColor(.secondary)
        case .partialSuccess(let radioCount, let failedAPs, let firstError):
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(radioCount) radios (\(failedAPs.count) failed)")
                    .font(.caption)
                    .foregroundColor(.orange)
                Text(firstError)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private var sshKeyName: String? {
        guard let keyID = cachedSSHCredentials?.sshKeyID else { return nil }
        return SSHKeyManager.shared.savedKeys.first(where: { $0.id == keyID })?.name
    }

    // MARK: - Helpers

    private var providerDisplayName: String {
        switch account.providerID {
        case UbiquitiProvider.providerID: return UbiquitiProvider.displayName
        default: return account.providerID.capitalized
        }
    }

    private var providerIconName: String {
        switch account.providerID {
        case UbiquitiProvider.providerID: return UbiquitiProvider.iconName
        default: return "wifi.router"
        }
    }

    // MARK: - Actions

    private func refresh() {
        isRefreshing = true
        Task {
            await cacheManager.syncAccount(account.id)
            isRefreshing = false
        }
    }

    private func renameAccount() {
        let newLabel = editedLabel.trimmingCharacters(in: .whitespaces)
        guard !newLabel.isEmpty else { return }

        var updatedAccount = account
        updatedAccount.label = newLabel
        accountManager.updateAccount(updatedAccount)
    }
}

// MARK: - AP Row View

struct WiFiAPRowView: View {
    let accessPoint: WiFiAccessPoint
    @ObservedObject private var radioCacheManager = WiFiAPRadioCacheManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIconName)
                .font(.title3)
                .foregroundColor(statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(accessPoint.name)
                    .font(.body)

                HStack(spacing: 8) {
                    Text(accessPoint.mac)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let ip = accessPoint.ip {
                        Text(ip)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                let apRadios = radioCacheManager.radios(forAccessPointID: accessPoint.id)
                let bands = Set(apRadios.map(\.band)).sorted()
                if !bands.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(bands, id: \.self) { band in
                            Text(band.shortName)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(bandColor(band).opacity(0.2))
                                .cornerRadius(3)
                        }
                    }
                }
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

    private var statusIconName: String {
        accessPoint.status == "online" ? "wifi" : "wifi.slash"
    }

    private var statusColor: Color {
        accessPoint.status == "online" ? .green : .gray
    }

    private func bandColor(_ band: WiFiBand) -> Color {
        switch band {
        case .band2_4: return .green
        case .band5: return .blue
        case .band6: return .purple
        }
    }
}
