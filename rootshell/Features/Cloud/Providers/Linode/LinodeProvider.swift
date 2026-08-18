import Foundation

// MARK: - Linode Provider

/// Linode/Akamai cloud provider implementation
struct LinodeProvider: CloudProvider {
    // MARK: - Provider Identity

    nonisolated static let providerID = "linode"
    nonisolated static let displayName = "Linode (Akamai)"
    nonisolated static let iconName = "server.rack"
    nonisolated static let logoImageName: String? = "LinodeLogo"

    // MARK: - Capabilities

    nonisolated static var supportedAuthMethods: [CloudAuthMethod] {
        OAuthConfig.isConfigured ? [.oauth, .pat] : [.pat]
    }

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .virtualMachines,
        .kubernetes,
        .console
    ]

    // MARK: - OAuth Configuration

    struct OAuthConfig {
        static let authorizationURL = URL(string: "https://login.linode.com/oauth/authorize")!
        static let tokenURL = URL(string: "https://login.linode.com/oauth/token")!
        static let revokeURL = URL(string: "https://login.linode.com/oauth/revoke")!
        nonisolated static let clientID = bundledValue(for: "RootshellLinodeOAuthClientID") ?? ""
        nonisolated static let clientSecret = bundledValue(for: "RootshellLinodeOAuthClientSecret")
        nonisolated static var isConfigured: Bool {
            !clientID.isEmpty && clientSecret != nil
        }
        static let redirectPort: UInt16 = 19847
        static let redirectURI = URL(string: "http://localhost:19847/oauth/callback")!
        static let scopes = "*"

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
        LinodeAPIClient(credentials: credentials, accountID: credentials.accountID)
    }

    // MARK: - Provider Info

    /// Description for the provider
    static let description = "Connect to your Linode (Akamai) account to manage virtual machines and Kubernetes clusters."

    /// Help text for PAT authentication
    static let patHelpText = "Generate a Personal Access Token in the Linode Cloud Manager under 'My Profile' > 'API Tokens'. The token needs Read access to Linodes and LKE clusters."

    /// Help text for OAuth authentication
    static let oauthHelpText = "Sign in with your Linode account to grant access. You'll be redirected to Linode's login page."

    /// Link to generate PAT
    static let patGenerateURL = URL(string: "https://cloud.linode.com/profile/tokens")!

    // MARK: - Regions

    /// Linode region display names
    static let regionDisplayNames: [String: String] = [
        "us-east": "Newark, NJ",
        "us-central": "Dallas, TX",
        "us-west": "Fremont, CA",
        "us-southeast": "Atlanta, GA",
        "us-lax": "Los Angeles, CA",
        "us-mia": "Miami, FL",
        "us-ord": "Chicago, IL",
        "us-sea": "Seattle, WA",
        "ca-central": "Toronto, Canada",
        "eu-west": "London, UK",
        "eu-central": "Frankfurt, Germany",
        "ap-west": "Mumbai, India",
        "ap-south": "Singapore",
        "ap-southeast": "Sydney, Australia",
        "ap-northeast": "Tokyo, Japan"
    ]

    /// Get display name for a region
    static func regionDisplayName(for region: String) -> String {
        regionDisplayNames[region] ?? region
    }
}
