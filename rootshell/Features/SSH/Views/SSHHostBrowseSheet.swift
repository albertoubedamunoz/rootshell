//
//  SSHHostBrowseSheet.swift
//  rootshell
//
//  Sheet for browsing available SSH hosts from multiple sources:
//  - mDNS discovered hosts on local network
//  - Recent SSH connection history
//  - Cloud instances (filterable by account)
//

import SwiftUI

// MARK: - Selection Result

/// Result of selecting a host from the browse sheet
struct BrowseHostSelection {
    let hostname: String
    let username: String?
    let port: Int?
    let historyEntry: SSHConnectionHistoryEntry?
    let cloudInstanceLabel: String?
    /// Which service the selection targets; routes VNC picks to the
    /// Screen Sharing form instead of the SSH one.
    let serviceKind: DiscoveredServiceKind
}

// MARK: - SSH Host Browse Sheet

/// Sheet for browsing available SSH hosts from multiple sources
struct SSHHostBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let onHostSelected: (BrowseHostSelection) -> Void

    var body: some View {
        NavigationStack {
            SSHHostBrowseListContent(
                onHostSelected: { selection in
                    onHostSelected(selection)
                    dismiss()
                },
                onDismiss: { dismiss() }
            )
            .navigationTitle("Browse Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                    #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.cancelAction)
                    #endif
                }
            }
        }
    }
}

// MARK: - SSH Host Browse List Content

/// Reusable browse hosts content that can be embedded in both the sheet and the connection sidebar.
/// Does NOT include its own NavigationStack — the caller must provide one.
struct SSHHostBrowseListContent: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    // Managers
    @StateObject private var localNetworkManager = LocalNetworkDiscoveryManager.shared
    @StateObject private var historyManager = SSHConnectionHistoryManager.shared
    @StateObject private var cloudCacheManager = CloudCacheManager.shared
    @StateObject private var cloudAccountManager = CloudAccountManager.shared

    // Cloud filtering state
    @State private var selectedAccountIDs: Set<UUID> = []
    @State private var showAccountFilter: Bool = false
    @State private var searchQuery: String = ""

    // Profile creation state
    @State private var historyEntryForProfile: SSHConnectionHistoryEntry?
    @State private var showingProfileEditor: Bool = false

    // Focus state for search field
    @State private var isSearchFocused: Bool = false

    // Keyboard navigation
    @State private var highlightedIndex: Int = 0
    @State private var scrollTargetID: String?
    @State private var searchFocusRequestID: Int = 0
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()
    @State private var pendingFocusTask: Task<Void, Never>?

    let onHostSelected: (BrowseHostSelection) -> Void
    /// Called when escape is pressed in the search field. Wire this to the sidebar's dismiss.
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                // Search section at top
                searchSection

                // Section 1: Local Network (mDNS)
                localNetworkSection

                // Section 2: Recent Connections
                recentConnectionsSection

                // Section 3: Cloud Assets
                cloudAssetsSection

                // No results message
                noResultsSection
            }
            .themedList()
            .onChange(of: scrollTargetID) { _, target in
                guard let target else { return }
                scrollProxy.scrollTo(target, anchor: .center)
            }
        }
        .onAppear {
            localNetworkManager.refreshIfStale()
            cloudCacheManager.refreshIfStale()

            // Auto-focus search field when hardware keyboard is connected
            scheduleSearchFocus()
        }
        .onDisappear {
            arrowKeyRepeatManager.stop()
            pendingFocusTask?.cancel()
            pendingFocusTask = nil
        }
        #if !os(visionOS)
        .onKeyPress(.downArrow, phases: .down) { _ in
            moveHighlightDown()
            arrowKeyRepeatManager.start(direction: .down) { [self] in
                moveHighlightDown()
            }
            return .handled
        }
        .onKeyPress(.downArrow, phases: .up) { _ in
            arrowKeyRepeatManager.stop(direction: .down)
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { _ in
            moveHighlightUp()
            arrowKeyRepeatManager.start(direction: .up) { [self] in
                moveHighlightUp()
            }
            return .handled
        }
        .onKeyPress(.upArrow, phases: .up) { _ in
            arrowKeyRepeatManager.stop(direction: .up)
            return .handled
        }
        .onKeyPress(.return) {
            if isSearchFocused {
                return .ignored
            }
            arrowKeyRepeatManager.stop()
            if activateHighlightedItem() {
                return .handled
            }
            return .ignored
        }
        #endif
        .onChange(of: searchQuery) { _, _ in
            highlightedIndex = 0
        }
        .onChange(of: selectedAccountIDs) { _, _ in
            highlightedIndex = 0
        }
        .navigationDestination(isPresented: $showingProfileEditor) {
            if let entry = historyEntryForProfile {
                ProfileEditorSheet(historyEntry: entry, embedded: true)
            }
        }
    }

    // MARK: - Search Section

    @ViewBuilder
    private var searchSection: some View {
        Section {
            Group {
                searchBar

                if !isAllAccountsSelected {
                    activeFilterChips
                }
            }
            .themedRow()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        BrowseSearchBar(
            searchQuery: $searchQuery,
            placeholder: String(localized: "Search hosts..."),
            focusedBinding: $isSearchFocused,
            focusRequestID: searchFocusRequestID,
            onEscape: onDismiss,
            onSubmit: { activateHighlightedItem() }
        ) {
            // Filter button with badge (only show if cloud accounts exist)
            if !vmCapableAccounts.isEmpty {
                Button(action: { showAccountFilter = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.title3)
                        if !isAllAccountsSelected {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .popover(isPresented: $showAccountFilter) {
                    AccountFilterPopover(
                        accounts: vmCapableAccounts,
                        selectedAccountIDs: $selectedAccountIDs
                    )
                }
            }
        }
    }

    // MARK: - Active Filter Chips

    private var activeFilterChips: some View {
        FilterChipBar(
            items: vmCapableAccounts.filter { selectedAccountIDs.contains($0.id) },
            label: { $0.label },
            icon: { account in
                providerIcon(for: account.providerID)
                    .frame(width: 14, height: 14)
            },
            onRemove: { removeAccountFromFilter($0.id) }
        )
    }

    // MARK: - No Results Section

    @ViewBuilder
    private var noResultsSection: some View {
        if !searchQuery.isEmpty &&
            filteredDiscoveredHosts.isEmpty &&
            filteredHistoryEntries.isEmpty &&
            filteredInstancesByAccount.isEmpty {
            Section {
                Group {
                    NoResultsRow(message: "No hosts match '\(searchQuery)'")
                }
                .themedRow()
            }
        }
    }

    // MARK: - Local Network Section

    @ViewBuilder
    private var localNetworkSection: some View {
        if !filteredDiscoveredHosts.isEmpty {
            Section {
                Group {
                    ForEach(filteredDiscoveredHosts) { host in
                        let rowID = BrowseItem.discoveredID(host)
                        DiscoveredHostRow(host: host) {
                            selectDiscoveredHost(host)
                        }
                        .id(rowID)
                        .listRowBackground(
                            isItemHighlighted(rowID)
                                ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                        )
                    }
                }
                .themedRow()
            } header: {
                HStack {
                    Text("Local Network")
                    Spacer()
                    if localNetworkManager.isScanning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
            }
        }
    }

    // MARK: - Recent Connections Section

    @ViewBuilder
    private var recentConnectionsSection: some View {
        if !filteredHistoryEntries.isEmpty {
            Section("Recent Connections") {
                Group {
                    ForEach(filteredHistoryEntries) { entry in
                        let rowID = BrowseItem.historyID(entry)
                        HistoryHostRow(entry: entry) {
                            selectHistoryEntry(entry)
                        }
                        .id(rowID)
                        .listRowBackground(
                            isItemHighlighted(rowID)
                                ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                        )
                        .contextMenu {
                            Button {
                                historyEntryForProfile = entry
                                showingProfileEditor = true
                            } label: {
                                Label("Save as Profile...", systemImage: "star")
                            }
                        }
                    }
                }
                .themedRow()
            }
        }
    }

    // MARK: - Cloud Assets Section

    @ViewBuilder
    private var cloudAssetsSection: some View {
        // Grouped instances by account
        ForEach(filteredInstancesByAccount, id: \.account.id) { group in
            Section(header: cloudAccountHeader(group.account, count: group.instances.count)) {
                Group {
                    ForEach(group.instances) { instance in
                        let rowID = BrowseItem.cloudID(instance)
                        CloudInstanceHostRow(instance: instance, account: group.account) {
                            selectCloudInstance(instance)
                        }
                        .id(rowID)
                        .listRowBackground(
                            isItemHighlighted(rowID)
                                ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                        )
                    }
                }
                .themedRow()
            }
        }
    }

    private func removeAccountFromFilter(_ accountID: UUID) {
        selectedAccountIDs.remove(accountID)
    }

    // MARK: - Cloud Account Header

    private func cloudAccountHeader(_ account: CloudAccount, count: Int) -> some View {
        HStack(spacing: 8) {
            providerIcon(for: account.providerID)
                .frame(width: 16, height: 16)

            Text(account.label)
                .textCase(nil)

            Spacer()

            Text("\(count)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Provider Icon

    @ViewBuilder
    private func providerIcon(for providerID: String) -> some View {
        switch providerID {
        case LinodeProvider.providerID:
            if let logoName = LinodeProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: LinodeProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case DigitalOceanProvider.providerID:
            if let logoName = DigitalOceanProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: DigitalOceanProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case AWSProvider.providerID:
            if let logoName = AWSProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: AWSProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case AzureProvider.providerID:
            if let logoName = AzureProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: AzureProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case TailscaleProvider.providerID:
            if let logoName = TailscaleProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: TailscaleProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        case NetbirdProvider.providerID:
            if let logoName = NetbirdProvider.logoImageName {
                Image(logoName)
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: NetbirdProvider.iconName)
                    .foregroundColor(.accentColor)
            }
        default:
            Image(systemName: "cloud")
                .foregroundColor(.accentColor)
        }
    }

    // MARK: - Search Filtering Computed Properties

    /// Filtered local network hosts based on search query
    private var filteredDiscoveredHosts: [DiscoveredSSHHost] {
        if searchQuery.isEmpty {
            return localNetworkManager.discoveredHosts
        }
        return localNetworkManager.discoveredHosts.filter { host in
            host.hostname.localizedCaseInsensitiveContains(searchQuery) ||
            host.serviceName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// Filtered history entries based on search query
    private var filteredHistoryEntries: [SSHConnectionHistoryEntry] {
        let entries = Array(historyManager.entries.prefix(10))
        if searchQuery.isEmpty {
            return entries
        }
        return entries.filter { entry in
            entry.host.localizedCaseInsensitiveContains(searchQuery) ||
            entry.username.localizedCaseInsensitiveContains(searchQuery) ||
            entry.displayString.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    // MARK: - Cloud Filtering Computed Properties

    /// Cloud accounts that support VMs or network devices (for SSH)
    private var vmCapableAccounts: [CloudAccount] {
        cloudAccountManager.accounts.filter { account in
            guard let provider = CloudProviderRegistry.shared.provider(for: account.providerID) else {
                return false
            }
            return provider.capabilities.contains(.virtualMachines) ||
                   provider.capabilities.contains(.networkDevices)
        }
    }

    /// Whether all accounts are effectively selected (empty set = all)
    private var isAllAccountsSelected: Bool {
        selectedAccountIDs.isEmpty || selectedAccountIDs.count == vmCapableAccounts.count
    }

    /// Accounts to include in search
    private var effectiveAccountIDs: Set<UUID> {
        selectedAccountIDs.isEmpty
            ? Set(vmCapableAccounts.map { $0.id })
            : selectedAccountIDs
    }

    /// Filtered and grouped instances by account
    private var filteredInstancesByAccount: [(account: CloudAccount, instances: [CloudInstance])] {
        var results: [(account: CloudAccount, instances: [CloudInstance])] = []

        for account in vmCapableAccounts where effectiveAccountIDs.contains(account.id) {
            let accountInstances = cloudCacheManager.instances(for: account.id)
            let filtered = searchQuery.isEmpty
                ? accountInstances.filter { $0.canSSH }
                : accountInstances.filter { $0.canSSH && $0.matches(query: searchQuery) }

            if !filtered.isEmpty {
                results.append((account: account, instances: filtered.sorted { $0.label < $1.label }))
            }
        }

        return results.sorted { $0.account.label < $1.account.label }
    }

    // MARK: - Keyboard Navigation

    /// A single navigable host across all three sections, in visual order.
    private enum BrowseItem: Identifiable {
        case discovered(DiscoveredSSHHost)
        case history(SSHConnectionHistoryEntry)
        case cloud(CloudInstance)

        var id: String {
            switch self {
            case .discovered(let h): return Self.discoveredID(h)
            case .history(let e): return Self.historyID(e)
            case .cloud(let i): return Self.cloudID(i)
            }
        }

        static func discoveredID(_ h: DiscoveredSSHHost) -> String { "discovered:\(h.id)" }
        static func historyID(_ e: SSHConnectionHistoryEntry) -> String { "history:\(e.id)" }
        static func cloudID(_ i: CloudInstance) -> String { "cloud:\(i.id)" }
    }

    /// Flattened, ordered list of all selectable rows (matches on-screen order).
    private var navigableItems: [BrowseItem] {
        var items: [BrowseItem] = []
        items += filteredDiscoveredHosts.map { .discovered($0) }
        items += filteredHistoryEntries.map { .history($0) }
        for group in filteredInstancesByAccount {
            items += group.instances.map { .cloud($0) }
        }
        return items
    }

    private func isItemHighlighted(_ id: String) -> Bool {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return false }
        let items = navigableItems
        guard highlightedIndex < items.count else { return false }
        return items[highlightedIndex].id == id
    }

    private func moveHighlightDown() {
        let items = navigableItems
        guard !items.isEmpty else { return }
        let lastIndex = items.count - 1
        let current = min(max(highlightedIndex, 0), lastIndex)
        highlightedIndex = min(current + 1, lastIndex)
        scrollTargetID = items[highlightedIndex].id
    }

    private func moveHighlightUp() {
        let items = navigableItems
        guard !items.isEmpty else { return }
        let lastIndex = items.count - 1
        let current = min(max(highlightedIndex, 0), lastIndex)
        highlightedIndex = max(current - 1, 0)
        scrollTargetID = items[highlightedIndex].id
    }

    @discardableResult
    private func activateHighlightedItem() -> Bool {
        let items = navigableItems
        guard highlightedIndex < items.count else { return false }
        switch items[highlightedIndex] {
        case .discovered(let host): selectDiscoveredHost(host)
        case .history(let entry): selectHistoryEntry(entry)
        case .cloud(let instance): selectCloudInstance(instance)
        }
        return true
    }

    private func restoreSearchFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else {
            isSearchFocused = false
            return
        }
        isSearchFocused = true
        searchFocusRequestID &+= 1
    }

    private func scheduleSearchFocus() {
        pendingFocusTask?.cancel()
        pendingFocusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            restoreSearchFocus()
        }
    }

    // MARK: - Selection Handlers

    private func selectDiscoveredHost(_ host: DiscoveredSSHHost) {
        // Screen Sharing hosts route to the VNC form; SSH history has no
        // bearing on them.
        if host.kind == .vnc {
            onHostSelected(BrowseHostSelection(
                hostname: host.hostname,
                username: nil,
                port: Int(host.port),
                historyEntry: nil,
                cloudInstanceLabel: nil,
                serviceKind: .vnc
            ))
            return
        }

        // Find matching history for username lookup
        let matchingEntry = historyManager.entries.first { entry in
            let entryHost = entry.host.lowercased()
            let discoveredHost = host.hostname.lowercased()
            return entryHost == discoveredHost ||
                   entryHost == discoveredHost.replacingOccurrences(of: ".local", with: "")
        }

        let selection = BrowseHostSelection(
            hostname: host.hostname,
            username: matchingEntry?.username,
            port: Int(host.port),
            historyEntry: matchingEntry,
            cloudInstanceLabel: nil,
            serviceKind: .ssh
        )

        onHostSelected(selection)
    }

    private func selectHistoryEntry(_ entry: SSHConnectionHistoryEntry) {
        let selection = BrowseHostSelection(
            hostname: entry.host,
            username: entry.username,
            port: entry.port,
            historyEntry: entry,
            cloudInstanceLabel: nil,
            serviceKind: .ssh
        )

        onHostSelected(selection)
    }

    private func selectCloudInstance(_ instance: CloudInstance) {
        guard let sshHost = instance.sshHost else { return }

        // Find matching history for this IP to restore auth settings
        let matchingEntry = historyManager.entries.first { $0.host == sshHost }

        let selection = BrowseHostSelection(
            hostname: sshHost,
            username: instance.defaultSSHUsername,
            port: 22,
            historyEntry: matchingEntry,
            cloudInstanceLabel: instance.label,
            serviceKind: .ssh
        )

        onHostSelected(selection)
    }
}

// MARK: - Discovered Host Row

/// Row for mDNS-discovered local network hosts
private struct DiscoveredHostRow: View {
    let host: DiscoveredSSHHost
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: host.kind == .vnc ? "display" : "antenna.radiowaves.left.and.right")
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(host.serviceName)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(host.hostname)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if host.kind == .vnc {
                            Text("·")
                            Text("Screen Sharing")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - History Host Row

/// Row for recent SSH connection history entries
private struct HistoryHostRow: View {
    let entry: SSHConnectionHistoryEntry
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.displayString)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if entry.connectionProtocol == .mosh || entry.connectionProtocol == .trzsz {
                            let badgeColor: Color = entry.connectionProtocol == .mosh ? .blue : .teal
                            Text("Roam")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(badgeColor.opacity(0.15))
                                .foregroundColor(badgeColor)
                                .cornerRadius(4)
                        }
                    }
                    Text(entry.lastUsed.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                authIndicator

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var authIndicator: some View {
        switch entry.authType {
        case .password:
            Image(systemName: "key.horizontal")
                .font(.caption)
                .foregroundColor(.secondary)
        case .savedPassword:
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundColor(.green)
        case .key:
            Image(systemName: "key")
                .font(.caption)
                .foregroundColor(.green)
        case .none:
            Image(systemName: "network")
                .font(.caption)
                .foregroundColor(.blue)
        case .keyboardInteractive:
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundColor(.green)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Cloud Instance Host Row

/// Row for cloud VM instances
private struct CloudInstanceHostRow: View {
    let instance: CloudInstance
    let account: CloudAccount
    let onSelect: () -> Void

    private var statusColor: Color {
        switch instance.status {
        case .running: return .green
        case .stopped: return .gray
        case .provisioning, .rebooting, .migrating: return .orange
        case .unknown: return .secondary
        }
    }

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
        Button(action: onSelect) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.label)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 4) {
                        if let address = addressDisplay {
                            Text(address)
                        }
                        if let region = instance.region {
                            Text("·")
                            Text(region)
                        }
                        NetworkDeviceInlineBadges(instance: instance)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Text(instance.status.displayName)
                    .font(.caption)
                    .foregroundColor(instance.status == .running ? .green : .secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SSHHostBrowseSheet { selection in
        print("Selected: \(selection.hostname)")
    }
}
