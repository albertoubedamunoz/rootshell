import Foundation

// MARK: - NetBird Provider

/// NetBird network provider implementation.
///
/// Like ``TailscaleProvider``, this is a REST device-discovery provider: it lists
/// the peers in a NetBird network via the NetBird Management API and surfaces them
/// for SSH. It does not tunnel traffic itself — routing to the NetBird overlay
/// (100.64.0.0/10) and `*.netbird.cloud` name resolution are provided by the
/// official NetBird client running on the device.
struct NetbirdProvider: CloudProvider {
    // MARK: - Provider Identity

    nonisolated static let providerID = "netbird"
    nonisolated static let displayName = "NetBird"
    nonisolated static let iconName = "network"
    nonisolated static let logoImageName: String? = "NetbirdLogo"

    // MARK: - Capabilities

    nonisolated static let supportedAuthMethods: [CloudAuthMethod] = [.pat]

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .networkDevices
    ]

    // MARK: - API Configuration

    struct APIConfig {
        /// NetBird Cloud management API. Self-hosted deployments override this
        /// via `CloudCredentials.netbirdManagementURL`.
        static let defaultBaseURL = URL(string: "https://api.netbird.io")!
    }

    // MARK: - API Client Factory

    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient {
        NetbirdAPIClient(credentials: credentials, accountID: credentials.accountID)
    }

    // MARK: - Provider Info

    /// Description for the provider
    static let description = "Connect to your NetBird network to discover and SSH to peers."

    /// Help text for personal access token authentication
    static let authHelpText = "Generate a Personal Access Token in your NetBird dashboard (User settings → Access Tokens). For self-hosted NetBird, also enter your management URL below."

    /// Link to the NetBird dashboard where access tokens are generated
    static let credentialsURL = URL(string: "https://app.netbird.io")!
}
