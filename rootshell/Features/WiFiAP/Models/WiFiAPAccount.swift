import Foundation

// MARK: - WiFi AP Account Model

/// Account metadata for a WiFi AP provider (stored in UserDefaults)
struct WiFiAPAccount: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier (used as Keychain account identifier)
    let id: UUID

    /// Provider identifier (e.g., "ubiquiti")
    let providerID: String

    /// Authentication method used
    let authMethod: WiFiAPAuthMethod

    /// User-provided label (e.g., "Home UniFi", "Office Network")
    var label: String

    /// Date when the account was added
    let createdDate: Date

    /// Date of last successful sync
    var lastSyncDate: Date?

    /// Number of APs found during last sync
    var deviceCount: Int?

    init(
        id: UUID = UUID(),
        providerID: String,
        authMethod: WiFiAPAuthMethod,
        label: String
    ) {
        self.id = id
        self.providerID = providerID
        self.authMethod = authMethod
        self.label = label
        self.createdDate = Date()
        self.lastSyncDate = nil
        self.deviceCount = nil
    }

    // MARK: - Display Helpers

    var summary: String {
        if let lastSync = lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
        }
        return "Never synced"
    }
}
