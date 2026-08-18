import Foundation

// MARK: - Cloud Account Model

/// Represents a cloud provider account (metadata stored in UserDefaults)
struct CloudAccount: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier (used as Keychain account identifier)
    let id: UUID

    /// Cloud provider identifier (e.g., "linode", "aws")
    let providerID: String

    /// User-provided name for this account (e.g., "Personal Linode", "Work AWS")
    var label: String

    /// Authentication method used for this account
    let authMethod: CloudAuthMethod

    /// Date when the account was added
    let createdDate: Date

    /// Date of last successful sync
    var lastSyncDate: Date?

    /// Account ID from the provider (e.g., Linode account ID)
    var providerAccountID: String?

    /// Display name/email from the provider
    var providerDisplayName: String?

    /// AWS region (only for AWS accounts - each account is scoped to a single region)
    var awsRegion: String?

    init(
        id: UUID = UUID(),
        providerID: String,
        label: String,
        authMethod: CloudAuthMethod,
        awsRegion: String? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.authMethod = authMethod
        self.createdDate = Date()
        self.lastSyncDate = nil
        self.providerAccountID = nil
        self.providerDisplayName = nil
        self.awsRegion = awsRegion
    }

    // MARK: - Display Helpers

    /// Display name combining label and provider info
    var displayName: String {
        if let providerDisplay = providerDisplayName {
            return "\(label) (\(providerDisplay))"
        }
        return label
    }

    /// Short summary for list display
    var summary: String {
        if let lastSync = lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
        }
        return "Never synced"
    }
}
