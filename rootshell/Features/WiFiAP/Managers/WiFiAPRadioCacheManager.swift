import Foundation
import os.log
import Combine

// MARK: - WiFi AP Radio Cache Manager

/// Manages cached radio data from SSH scans with file-based persistence.
/// Follows the same pattern as WiFiAPCacheManager.
@MainActor
class WiFiAPRadioCacheManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WiFiAPRadioCacheManager")

    static let shared = WiFiAPRadioCacheManager()

    // MARK: - Published State

    @Published private(set) var radiosByAccount: [UUID: [WiFiAPRadio]] = [:]
    @Published private(set) var lastScanDate: [UUID: Date] = [:]

    private let fileManager: FileManager

    // MARK: - Cache Directory

    private var cacheDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("wifi_radio_cache", isDirectory: true)
    }

    // MARK: - Initialization

    private init() {
        self.fileManager = .default
        ensureCacheDirectoryExists()
        loadAllCachedData()
    }

    private func ensureCacheDirectoryExists() {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create radio cache directory: \(error.localizedDescription)")
        }
    }

    // MARK: - BSSID Lookup

    /// Find a radio matching the given BSSID (exact match across all accounts)
    func findRadio(forBSSID bssid: String) -> WiFiAPRadio? {
        guard let mac = MACAddress(bssid) else { return nil }
        let normalized = mac.canonicalString

        for radios in radiosByAccount.values {
            if let radio = radios.first(where: { $0.bssid == normalized }) {
                return radio
            }
        }
        return nil
    }

    /// Get all radios for a specific AP
    func radios(forAccessPointID apID: String) -> [WiFiAPRadio] {
        radiosByAccount.values.flatMap { radios in
            radios.filter { $0.accessPointID == apID }
        }
    }

    // MARK: - Cache Updates

    /// Store scan results for an account
    func updateRadios(_ radios: [WiFiAPRadio], for accountID: UUID) {
        radiosByAccount[accountID] = radios
        lastScanDate[accountID] = Date()
        saveCacheForAccount(accountID)
    }

    /// Clear cache for an account
    func clearCache(for accountID: UUID) {
        radiosByAccount.removeValue(forKey: accountID)
        lastScanDate.removeValue(forKey: accountID)

        let cacheFile = cacheFileURL(for: accountID)
        try? fileManager.removeItem(at: cacheFile)
    }

    // MARK: - File-Based Persistence

    private func cacheFileURL(for accountID: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(accountID.uuidString).json")
    }

    private func loadAllCachedData() {
        let accounts = WiFiAPAccountManager.shared.accounts
        for account in accounts {
            loadCacheForAccount(account.id)
        }
    }

    private func loadCacheForAccount(_ accountID: UUID) {
        let cacheFile = cacheFileURL(for: accountID)

        guard fileManager.fileExists(atPath: cacheFile.path) else { return }

        do {
            let data = try Data(contentsOf: cacheFile)
            let cache = try JSONDecoder().decode(WiFiAPRadioCacheData.self, from: data)

            radiosByAccount[accountID] = cache.radios
            lastScanDate[accountID] = cache.lastUpdated

            let radioCount = cache.radios.count
            Self.logger.debug("Loaded radio cache for account \(accountID.uuidString): \(radioCount) radios")
        } catch {
            Self.logger.error("Failed to load radio cache for account \(accountID.uuidString): \(error.localizedDescription)")
        }
    }

    private func saveCacheForAccount(_ accountID: UUID) {
        let cache = WiFiAPRadioCacheData(
            radios: radiosByAccount[accountID] ?? [],
            lastUpdated: Date()
        )

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheFileURL(for: accountID))
        } catch {
            Self.logger.error("Failed to save radio cache for account \(accountID.uuidString): \(error.localizedDescription)")
        }
    }
}

// MARK: - Cache Data Structure

private struct WiFiAPRadioCacheData: Codable {
    let radios: [WiFiAPRadio]
    let lastUpdated: Date
}
