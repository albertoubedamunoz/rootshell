import Foundation

// MARK: - WiFi Access Point Model

/// Represents a cached WiFi access point from a management API
nonisolated struct WiFiAccessPoint: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier from the provider
    let id: String

    /// Account ID this AP belongs to
    let accountID: UUID

    /// Provider identifier (e.g., "ubiquiti")
    let providerID: String

    /// Friendly display name of the AP
    let name: String

    /// MAC address (uppercase colon-separated, e.g., "AA:BB:CC:DD:EE:FF")
    let mac: String

    /// Device model (e.g., "U6-Pro")
    let model: String?

    /// Short name / alias (e.g., "U6Pro")
    let shortname: String?

    /// IP address on the management network
    let ip: String?

    /// Product line (e.g., "UniFi")
    let productLine: String?

    /// Device status (e.g., "online", "offline")
    let status: String?

    /// Site name where the AP is deployed
    let siteName: String?

    /// Host/console ID for Network API proxy calls
    var hostId: String?

    /// Site ID for Network API proxy calls
    var siteId: String?

    /// Whether this device has wireless AP capability (from Network API features)
    var isWirelessAP: Bool?

    /// When this record was last fetched
    var lastUpdated: Date?

    var macAddress: MACAddress? {
        MACAddress(mac)
    }

    /// Some controller APIs report the AP chassis MAC while the live BSSID is a
    /// derived radio/interface MAC. We keep both prefix and suffix forms for
    /// ranked matching.
    var macPrefix: String? {
        macAddress?.prefix(octetCount: 5)
    }

    var macSuffix: String? {
        macAddress?.suffix(octetCount: 5)
    }
}
