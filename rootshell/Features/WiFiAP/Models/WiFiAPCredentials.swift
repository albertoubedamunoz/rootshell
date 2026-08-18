import Foundation

// MARK: - WiFi AP Credentials Model

/// Credentials for a WiFi AP provider account (stored in Keychain)
struct WiFiAPCredentials: Codable, Sendable {
    /// Account ID this credential belongs to
    let accountID: UUID

    /// Provider ID for reference
    let providerID: String

    /// Authentication method
    let authMethod: WiFiAPAuthMethod

    /// API key (for providers that use header-based auth)
    var apiKey: String?

    /// SSH username for radio scanning (optional)
    var sshUsername: String?

    /// SSH key ID for radio scanning (optional, references SSHKey.id)
    var sshKeyID: UUID?

    // MARK: - Factory Methods

    /// Create API key credentials
    static func apiKey(
        accountID: UUID,
        providerID: String,
        key: String
    ) -> WiFiAPCredentials {
        WiFiAPCredentials(
            accountID: accountID,
            providerID: providerID,
            authMethod: .apiKey,
            apiKey: key
        )
    }

    /// Create API key credentials with SSH radio scanning config
    static func apiKeyWithSSH(
        accountID: UUID,
        providerID: String,
        key: String,
        sshUsername: String?,
        sshKeyID: UUID?
    ) -> WiFiAPCredentials {
        WiFiAPCredentials(
            accountID: accountID,
            providerID: providerID,
            authMethod: .apiKey,
            apiKey: key,
            sshUsername: sshUsername,
            sshKeyID: sshKeyID
        )
    }
}
