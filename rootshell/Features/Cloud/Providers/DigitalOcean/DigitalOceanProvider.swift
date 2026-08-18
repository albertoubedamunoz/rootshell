import Foundation

// MARK: - DigitalOcean Provider

/// DigitalOcean cloud provider implementation
struct DigitalOceanProvider: CloudProvider {
    // MARK: - Provider Identity

    nonisolated static let providerID = "digitalocean"
    nonisolated static let displayName = "DigitalOcean"
    nonisolated static let iconName = "drop.fill"
    nonisolated static let logoImageName: String? = "DigitalOceanLogo"

    // MARK: - Capabilities

    nonisolated static var supportedAuthMethods: [CloudAuthMethod] {
        OAuthConfig.isConfigured ? [.oauth, .pat] : [.pat]
    }

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .virtualMachines,
        .kubernetes
    ]

    // MARK: - OAuth Configuration

    struct OAuthConfig {
        static let authorizationURL = URL(string: "https://cloud.digitalocean.com/v1/oauth/authorize")!
        static let tokenURL = URL(string: "https://cloud.digitalocean.com/v1/oauth/token")!
        nonisolated static let clientID = bundledValue(for: "RootshellDigitalOceanOAuthClientID") ?? ""
        nonisolated static let clientSecret = bundledValue(for: "RootshellDigitalOceanOAuthClientSecret")
        nonisolated static var isConfigured: Bool {
            !clientID.isEmpty && clientSecret != nil
        }
        static let redirectPort: UInt16 = 19847
        static let redirectURI = URL(string: "http://localhost:19847/oauth/callback")!
        static let scopes = "account:read droplet:read kubernetes:read kubernetes:access_cluster"

        private nonisolated static func bundledValue(for key: String) -> String? {
            guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
                return nil
            }

            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
            return value
        }
    }

    // MARK: - API Client Factory

    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient {
        DigitalOceanAPIClient(credentials: credentials, accountID: credentials.accountID)
    }

    // MARK: - Provider Info

    /// Description for the provider
    static let description = "Connect to your DigitalOcean account to manage Droplets and Kubernetes clusters."

    /// Help text for PAT authentication
    static let patHelpText = "Generate a Personal Access Token in the DigitalOcean Control Panel under 'API' > 'Tokens'. The token needs Read access to Droplets and Kubernetes."

    /// Help text for OAuth authentication
    static let oauthHelpText = "Sign in with your DigitalOcean account to grant access. You'll be redirected to DigitalOcean's login page."

    /// Link to generate PAT
    static let patGenerateURL = URL(string: "https://cloud.digitalocean.com/account/api/tokens")!

    // MARK: - Regions

    /// DigitalOcean region display names
    static let regionDisplayNames: [String: String] = [
        "nyc1": "New York 1",
        "nyc2": "New York 2",
        "nyc3": "New York 3",
        "sfo1": "San Francisco 1",
        "sfo2": "San Francisco 2",
        "sfo3": "San Francisco 3",
        "ams2": "Amsterdam 2",
        "ams3": "Amsterdam 3",
        "sgp1": "Singapore 1",
        "lon1": "London 1",
        "fra1": "Frankfurt 1",
        "tor1": "Toronto 1",
        "blr1": "Bangalore 1",
        "syd1": "Sydney 1"
    ]

    /// Get display name for a region
    static func regionDisplayName(for region: String) -> String {
        regionDisplayNames[region] ?? region
    }
}
