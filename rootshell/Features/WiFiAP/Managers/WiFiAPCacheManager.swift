import Foundation
import Combine
import os.log

// MARK: - Sync Status

enum WiFiAPSyncStatus: Equatable {
    case idle
    case syncing
    case success(deviceCount: Int)
    case error(String)

    var isLoading: Bool {
        if case .syncing = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .idle:
            return "Not synced"
        case .syncing:
            return "Syncing..."
        case .success(let count):
            return "\(count) AP\(count == 1 ? "" : "s")"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - WiFi AP Cache Manager

/// Manages cached WiFi AP data with file-based persistence
@MainActor
class WiFiAPCacheManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WiFiAPCacheManager")

    static let shared = WiFiAPCacheManager()

    static let staleCacheThreshold: TimeInterval = 60 * 60 // 1 hour

    /// Fixed account UUID for manually associated APs (not tied to any provider account).
    static let manualAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - Published State

    @Published private(set) var accessPointsByAccount: [UUID: [WiFiAccessPoint]] = [:]
    @Published private(set) var syncStatus: [UUID: WiFiAPSyncStatus] = [:]

    private(set) var lastSyncDate: [UUID: Date] = [:]

    let cacheDidChange = PassthroughSubject<Void, Never>()

    private var backgroundRefreshTask: Task<Void, Never>?

    // MARK: - Dependencies

    private let accountManager: WiFiAPAccountManager
    private let fileManager: FileManager

    // MARK: - Cache Directory

    private var cacheDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("wifi_ap_cache", isDirectory: true)
    }

    // MARK: - Initialization

    private init() {
        self.accountManager = WiFiAPAccountManager.shared
        self.fileManager = .default
        ensureCacheDirectoryExists()
        loadAllCachedData()
        // Also load manually associated APs (not tied to a provider account)
        loadCacheForAccount(Self.manualAccountID)
    }

    private func ensureCacheDirectoryExists() {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create cache directory: \(error.localizedDescription)")
        }
    }

    // MARK: - BSSID Matching

    /// Find an access point matching the given BSSID using ranked, deterministic
    /// MAC similarity matching. This handles controller/device MAC drift seen on
    /// some APs where the live BSSID differs in the first octet, as well as the
    /// more common last-octet radio variation.
    func findAccessPoint(forBSSID bssid: String) -> WiFiAccessPoint? {
        guard let bssidAddress = MACAddress(bssid) else { return nil }

        let accessPoints = allAccessPoints.sorted { lhs, rhs in
            let lhsKey = "\(lhs.accountID.uuidString)|\(lhs.id)"
            let rhsKey = "\(rhs.accountID.uuidString)|\(rhs.id)"
            return lhsKey < rhsKey
        }

        var rankedMatches: [(ap: WiFiAccessPoint, rank: Int)] = []
        for accessPoint in accessPoints {
            guard let rank = matchRank(for: accessPoint, bssid: bssidAddress) else { continue }
            rankedMatches.append((accessPoint, rank))
        }

        guard let bestRank = rankedMatches.map(\.rank).min() else { return nil }
        let bestMatches = rankedMatches.filter { $0.rank == bestRank }

        if bestMatches.count > 1 {
            // Prefer manual entries — explicit user configuration wins over provider data
            let manualMatches = bestMatches.filter { $0.ap.providerID == ManualAPManager.manualProviderID }
            if manualMatches.count == 1 {
                return manualMatches.first?.ap
            }

            let normalizedBSSID = bssidAddress.canonicalString
            Self.logger.info(
                "Ambiguous AP match for BSSID \(normalizedBSSID, privacy: .public); \(bestMatches.count) candidates at rank \(bestRank)"
            )
            return nil
        }

        return bestMatches.first?.ap
    }

    private func matchRank(for accessPoint: WiFiAccessPoint, bssid: MACAddress) -> Int? {
        guard let accessPointMAC = accessPoint.macAddress else { return nil }

        if accessPointMAC == bssid {
            return 0
        }

        let accessPointCleared = accessPointMAC.clearingLocallyAdministeredBit()
        let bssidCleared = bssid.clearingLocallyAdministeredBit()

        if accessPointMAC == bssidCleared || accessPointCleared == bssid {
            return 1
        }

        if accessPointCleared == bssidCleared {
            return 2
        }

        if accessPoint.macSuffix == bssid.suffix(octetCount: 5) {
            return 3
        }

        if accessPoint.macPrefix == bssid.prefix(octetCount: 5) ||
           accessPoint.macPrefix == bssidCleared.prefix(octetCount: 5) {
            return 4
        }

        return nil
    }

    // MARK: - Sync Operations

    func syncAllAccounts() async {
        Self.logger.info("Syncing all WiFi AP accounts")
        await withTaskGroup(of: Void.self) { group in
            for account in accountManager.accounts {
                group.addTask { @MainActor in
                    await self.syncAccount(account.id)
                }
            }
        }
    }

    func isCacheStale() -> Bool {
        let accounts = accountManager.accounts
        guard !accounts.isEmpty else { return false }

        let now = Date()
        for account in accounts {
            guard let syncDate = lastSyncDate[account.id] else {
                return true
            }
            if now.timeIntervalSince(syncDate) > Self.staleCacheThreshold {
                return true
            }
        }
        return false
    }

    func refreshIfStale() {
        guard backgroundRefreshTask == nil else { return }
        guard isCacheStale() else { return }

        Self.logger.info("WiFi AP cache stale, triggering background refresh")
        backgroundRefreshTask = Task {
            await syncAllAccounts()
            backgroundRefreshTask = nil
        }
    }

    func syncAccount(_ accountID: UUID) async {
        guard let account = accountManager.account(for: accountID) else {
            Self.logger.warning("Cannot sync unknown account: \(accountID.uuidString)")
            return
        }

        Self.logger.info("Syncing WiFi AP account: \(account.label)")
        syncStatus[accountID] = .syncing

        do {
            let client = try accountManager.createAPIClient(for: accountID)
            let accessPoints = try await client.listAccessPoints()

            accessPointsByAccount[accountID] = accessPoints
            let apCount = accessPoints.filter { $0.isWirelessAP ?? false }.count
            syncStatus[accountID] = .success(deviceCount: apCount)
            lastSyncDate[accountID] = Date()

            accountManager.updateAccountSyncInfo(
                accountID: accountID,
                lastSyncDate: Date(),
                deviceCount: apCount
            )

            saveCacheForAccount(accountID)
            cacheDidChange.send()

            Self.logger.info("Sync completed for \(account.label): \(apCount) APs")

        } catch {
            Self.logger.error("Sync failed for \(account.label): \(error.localizedDescription)")
            syncStatus[accountID] = .error(error.localizedDescription)
        }
    }

    // MARK: - Cache Access

    var allAccessPoints: [WiFiAccessPoint] {
        accessPointsByAccount.values.flatMap { $0 }
    }

    func accessPoints(for accountID: UUID) -> [WiFiAccessPoint] {
        accessPointsByAccount[accountID] ?? []
    }

    func status(for accountID: UUID) -> WiFiAPSyncStatus {
        syncStatus[accountID] ?? .idle
    }

    // MARK: - Manual AP Entries

    /// Update manually associated APs. Called by ManualAPManager.
    func updateManualEntries(_ aps: [WiFiAccessPoint]) {
        accessPointsByAccount[Self.manualAccountID] = aps
        saveCacheForAccount(Self.manualAccountID)
        let count = aps.count
        syncStatus[Self.manualAccountID] = .success(deviceCount: count)
        cacheDidChange.send()
    }

    // MARK: - Cache Management

    func clearCache(for accountID: UUID) {
        // Never clear manual entries via provider account cleanup
        guard accountID != Self.manualAccountID else { return }
        accessPointsByAccount.removeValue(forKey: accountID)
        syncStatus.removeValue(forKey: accountID)
        lastSyncDate.removeValue(forKey: accountID)

        let cacheFile = cacheFileURL(for: accountID)
        try? fileManager.removeItem(at: cacheFile)

        cacheDidChange.send()
    }

    // MARK: - File-Based Persistence

    private func cacheFileURL(for accountID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(accountID.uuidString).json")
    }

    private func loadAllCachedData() {
        for account in accountManager.accounts {
            loadCacheForAccount(account.id)
        }
    }

    private func loadCacheForAccount(_ accountID: UUID) {
        let cacheFile = cacheFileURL(for: accountID)

        guard fileManager.fileExists(atPath: cacheFile.path) else {
            syncStatus[accountID] = .idle
            return
        }

        do {
            let data = try Data(contentsOf: cacheFile)
            let cache = try JSONDecoder().decode(WiFiAPCacheData.self, from: data)

            accessPointsByAccount[accountID] = cache.accessPoints
            let apCount = cache.accessPoints.count
            syncStatus[accountID] = .success(deviceCount: apCount)
            lastSyncDate[accountID] = cache.lastUpdated

            Self.logger.debug("Loaded cache for account \(accountID.uuidString): \(apCount) APs")
        } catch {
            Self.logger.error("Failed to load cache for account \(accountID.uuidString): \(error.localizedDescription)")
            syncStatus[accountID] = .idle
        }
    }

    private func saveCacheForAccount(_ accountID: UUID) {
        let cache = WiFiAPCacheData(
            accessPoints: accessPointsByAccount[accountID] ?? [],
            lastUpdated: Date()
        )

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheFileURL(for: accountID))
        } catch {
            Self.logger.error("Failed to save cache for account \(accountID.uuidString): \(error.localizedDescription)")
        }
    }
}

// MARK: - Cache Data Structure

private struct WiFiAPCacheData: Codable {
    let accessPoints: [WiFiAccessPoint]
    let lastUpdated: Date
}
