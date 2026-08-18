import Foundation

// MARK: - Tailscale Provider

/// Tailscale network provider implementation
struct TailscaleProvider: CloudProvider {
    // MARK: - Provider Identity

    nonisolated static let providerID = "tailscale"
    nonisolated static let displayName = "Tailscale"
    nonisolated static let iconName = "network"
    nonisolated static let logoImageName: String? = "TailscaleLogo"

    // MARK: - Capabilities

    nonisolated static let supportedAuthMethods: [CloudAuthMethod] = [.tailscaleClientCredentials]

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .networkDevices
    ]

    // MARK: - OAuth Configuration

    struct OAuthConfig {
        static let tokenURL = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
        static let baseURL = URL(string: "https://api.tailscale.com/api/v2")!
    }

    // MARK: - API Client Factory

    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient {
        TailscaleAPIClient(credentials: credentials, accountID: credentials.accountID)
    }

    // MARK: - Provider Info

    /// Description for the provider
    static let description = "Connect to your Tailscale tailnet to discover and SSH to devices on your network."

    /// Help text for client credentials authentication
    static let authHelpText = "Create an OAuth client in your Tailscale Admin Console under Trust > Credentials. Select 'devices:read' scope."

    /// Link to generate OAuth credentials
    static let credentialsURL = URL(string: "https://login.tailscale.com/admin/settings/oauth")!

}
