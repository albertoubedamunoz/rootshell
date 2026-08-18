import Foundation

enum OUILookup {
    struct Vendor {
        let name: String
        let address: String
        let website: String?
    }

    private static let vendors: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "oui_vendors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else {
            return [:]
        }
        return dict
    }()

    private static let prefixLengths: [Int] = {
        Array(Set(vendors.keys.map(\.count))).sorted(by: >)
    }()

    static func lookup(bssid: String) -> Vendor? {
        guard let address = MACAddress(bssid) else { return nil }

        for candidate in candidateHexPrefixes(for: address) {
            if let vendor = vendor(forPrefixHex: candidate) {
                return vendor
            }
        }

        return nil
    }

    static func resolveVendor(bssid: String, matchedAP: WiFiAccessPoint?) -> Vendor? {
        if let vendor = lookup(bssid: bssid) {
            return vendor
        }
        if let accessPointMAC = matchedAP?.mac {
            return lookup(bssid: accessPointMAC)
        }
        return nil
    }

    /// Detect randomized/private MAC addresses.
    /// Returns true only if the locally-administered bit is set AND no vendor
    /// match exists (even after clearing the LA bit). Enterprise APs routinely
    /// set the LA bit on virtual BSSIDs for multi-SSID, so the bit alone is
    /// not sufficient to flag a MAC as randomized.
    static func isRandomizedMAC(_ bssid: String) -> Bool {
        guard let address = MACAddress(bssid),
              address.isLocallyAdministered else { return false }
        return lookup(bssid: bssid) == nil
    }

    private static func candidateHexPrefixes(for address: MACAddress) -> [String] {
        let variants = address.isLocallyAdministered
            ? [address, address.clearingLocallyAdministeredBit()]
            : [address]
        var seen = Set<String>()
        var prefixes: [String] = []

        for variant in variants {
            let hex = variant.hexString
            for length in prefixLengths where hex.count >= length {
                let prefix = String(hex.prefix(length))
                if seen.insert(prefix).inserted {
                    prefixes.append(prefix)
                }
            }
        }

        return prefixes
    }

    private static func vendor(forPrefixHex prefix: String) -> Vendor? {
        guard let entry = vendors[prefix] else { return nil }
        return Vendor(
            name: entry["n"] ?? "",
            address: entry["a"] ?? "",
            website: entry["w"]
        )
    }

    // MARK: - Vendor Search

    /// A unique vendor entry for search/selection UI.
    struct VendorEntry: Identifiable, Sendable {
        let id: String       // First OUI prefix hex for this vendor
        let name: String
        let website: String?

        var domain: String? {
            website.flatMap { FaviconFetcher.extractDomain(from: $0) }
        }
    }

    /// All unique vendor names from the OUI database, collapsed from ~39K OUI
    /// prefixes to ~20K unique names. Prefers entries with a website URL.
    /// Computed once on first access.
    private static let uniqueVendorList: [VendorEntry] = {
        var byName: [String: (prefix: String, name: String, website: String?)] = [:]

        for (prefix, entry) in vendors {
            let name = entry["n"] ?? ""
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            let website = entry["w"]

            if let existing = byName[key] {
                // Prefer the entry that has a website
                if existing.website == nil && website != nil {
                    byName[key] = (prefix, name, website)
                }
            } else {
                byName[key] = (prefix, name, website)
            }
        }

        return byName.values
            .map { VendorEntry(id: $0.prefix, name: $0.name, website: $0.website) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Number of unique vendor names in the database.
    static var uniqueVendorCount: Int {
        uniqueVendorList.count
    }

    /// Returns all unique vendor names for the vendor search UI.
    static func allUniqueVendors() -> [VendorEntry] {
        uniqueVendorList
    }

    /// Search vendors by name substring, returning up to `limit` results.
    /// Uses case-insensitive matching. Vendors whose name starts with the
    /// query are ranked before substring matches. Always scans the full list
    /// to ensure prefix matches aren't missed by an early exit.
    static func searchVendors(query: String, limit: Int) -> [VendorEntry] {
        let lower = query.lowercased()
        var prefixMatches: [VendorEntry] = []
        var substringMatches: [VendorEntry] = []

        for vendor in uniqueVendorList {
            let nameLower = vendor.name.lowercased()
            if nameLower.hasPrefix(lower) {
                if prefixMatches.count < limit {
                    prefixMatches.append(vendor)
                }
            } else if nameLower.contains(lower) {
                if substringMatches.count < limit {
                    substringMatches.append(vendor)
                }
            }
            // Only stop when both buckets are full
            if prefixMatches.count >= limit && substringMatches.count >= limit {
                break
            }
        }

        var results = prefixMatches.prefix(limit)
        let remaining = limit - results.count
        if remaining > 0 {
            results.append(contentsOf: substringMatches.prefix(remaining))
        }
        return Array(results)
    }
}
