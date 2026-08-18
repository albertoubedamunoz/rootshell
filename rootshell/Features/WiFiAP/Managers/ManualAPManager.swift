import Combine
import Foundation
import os.log

// MARK: - Manual AP Manager

/// Manages manually associated WiFi access points for users without a
/// provider integration (e.g., Ubiquiti). Stores entries in the shared
/// WiFiAPCacheManager under a fixed "manual" account UUID.
@MainActor
class ManualAPManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ManualAPManager")

    static let shared = ManualAPManager()

    static let manualProviderID = "manual"
    static let manualAccountID = WiFiAPCacheManager.manualAccountID

    // MARK: - Published State

    @Published private(set) var manualAPs: [WiFiAccessPoint] = []

    /// Maps canonical MAC → domain string for favicon fetching.
    /// Stored separately because WiFiAccessPoint has no domain field.
    private(set) var vendorDomains: [String: String] = [:]

    // MARK: - Initialization

    private init() {
        loadFromCache()
        loadDomains()
    }

    // MARK: - CRUD

    @discardableResult
    func addManualAP(
        bssid: String,
        name: String,
        vendorName: String?,
        vendorDomain: String?,
        model: String?,
        siteName: String?
    ) -> WiFiAccessPoint? {
        guard let mac = MACAddress(bssid) else {
            Self.logger.warning("Invalid BSSID for manual AP: \(bssid)")
            return nil
        }

        let canonical = mac.canonicalString

        // Prevent duplicate BSSID
        if manualAPs.contains(where: { $0.mac == canonical }) {
            Self.logger.info("Manual AP already exists for BSSID \(canonical)")
            return nil
        }

        let ap = WiFiAccessPoint(
            id: "manual-\(canonical)",
            accountID: Self.manualAccountID,
            providerID: Self.manualProviderID,
            name: name,
            mac: canonical,
            model: model,
            shortname: nil,
            ip: nil,
            productLine: vendorName,
            status: "online",
            siteName: siteName,
            hostId: nil,
            siteId: nil,
            lastUpdated: Date()
        )

        manualAPs.append(ap)

        if let sanitized = Self.sanitizeDomain(vendorDomain) {
            vendorDomains[canonical] = sanitized
        }

        persist()
        return ap
    }

    func updateManualAP(
        mac: String,
        name: String,
        vendorName: String?,
        vendorDomain: String?,
        model: String?,
        siteName: String?
    ) {
        guard let index = manualAPs.firstIndex(where: { $0.mac == mac }) else { return }

        let existing = manualAPs[index]
        let updated = WiFiAccessPoint(
            id: existing.id,
            accountID: existing.accountID,
            providerID: existing.providerID,
            name: name,
            mac: existing.mac,
            model: model,
            shortname: existing.shortname,
            ip: existing.ip,
            productLine: vendorName ?? existing.productLine,
            status: existing.status,
            siteName: siteName,
            hostId: existing.hostId,
            siteId: existing.siteId,
            lastUpdated: Date()
        )

        manualAPs[index] = updated

        if let sanitized = Self.sanitizeDomain(vendorDomain) {
            vendorDomains[mac] = sanitized
        } else {
            vendorDomains.removeValue(forKey: mac)
        }

        persist()
    }

    func deleteManualAP(mac: String) {
        manualAPs.removeAll { $0.mac == mac }
        vendorDomains.removeValue(forKey: mac)
        persist()
    }

    func deleteManualAPs(at indices: [Int]) {
        let sorted = indices.sorted(by: >)
        for index in sorted {
            let mac = manualAPs[index].mac
            vendorDomains.removeValue(forKey: mac)
            manualAPs.remove(at: index)
        }
        persist()
    }

    // MARK: - Vendor Lookup

    /// Returns the stored vendor name for a manual AP (from productLine).
    func vendorName(forMAC mac: String) -> String? {
        if let ap = manualAPs.first(where: { $0.mac == mac }) {
            return ap.productLine
        }
        if let canonical = MACAddress(mac)?.canonicalString {
            return manualAPs.first(where: { $0.mac == canonical })?.productLine
        }
        return nil
    }

    func vendorDomain(forMAC mac: String) -> String? {
        // Try exact match first, then try canonical form
        if let domain = vendorDomains[mac] {
            return domain
        }
        if let canonical = MACAddress(mac)?.canonicalString {
            return vendorDomains[canonical]
        }
        return nil
    }

    // MARK: - Reload (for backup restore)

    func reload() {
        loadFromCache()
        loadDomains()
    }

    // MARK: - Persistence

    private func persist() {
        WiFiAPCacheManager.shared.updateManualEntries(manualAPs)
        saveDomains()
        // Re-resolve WiFi display state so Live Activity / bssid pick up
        // changes immediately without waiting for a network change.
        WiFiInfoService.shared.refreshVendorAndAP()
    }

    private func loadFromCache() {
        manualAPs = WiFiAPCacheManager.shared.accessPoints(for: Self.manualAccountID)
    }

    private var domainsFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("wifi_ap_cache", isDirectory: true)
            .appendingPathComponent("manual_ap_domains.json")
    }

    private func loadDomains() {
        let url = domainsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: String].self, from: data)
            // Sanitize on load to handle legacy data saved before sanitization was added
            vendorDomains = raw.compactMapValues { Self.sanitizeDomain($0) }
        } catch {
            Self.logger.error("Failed to load manual AP domains: \(error.localizedDescription)")
        }
    }

    private func saveDomains() {
        do {
            let data = try JSONEncoder().encode(vendorDomains)
            try data.write(to: domainsFileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save manual AP domains: \(error.localizedDescription)")
        }
    }

    // MARK: - Domain Sanitization

    /// Strips scheme prefixes, whitespace, and trailing slashes from a domain
    /// string so that runtime code can safely prepend "https://".
    /// Returns nil if the result is empty.
    static func sanitizeDomain(_ raw: String?) -> String? {
        guard var domain = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !domain.isEmpty else { return nil }

        // Strip scheme if user pasted a full URL
        for prefix in ["https://", "http://"] {
            if domain.lowercased().hasPrefix(prefix) {
                domain = String(domain.dropFirst(prefix.count))
                break
            }
        }

        // Strip trailing slashes/whitespace
        domain = domain.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        return domain.isEmpty ? nil : domain
    }
}
