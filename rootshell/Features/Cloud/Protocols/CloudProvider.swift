import Foundation

// MARK: - Cloud Provider Protocol

/// Identifies a cloud provider and its capabilities
protocol CloudProvider {
    /// Unique identifier for this provider type (e.g., "linode", "aws")
    nonisolated static var providerID: String { get }

    /// Human-readable name (e.g., "Linode (Akamai)")
    nonisolated static var displayName: String { get }

    /// SF Symbol icon name (used as fallback if logoImageName is nil)
    nonisolated static var iconName: String { get }

    /// Custom logo image name from asset catalog (optional, takes precedence over iconName)
    nonisolated static var logoImageName: String? { get }

    /// Supported authentication methods for this provider
    nonisolated static var supportedAuthMethods: [CloudAuthMethod] { get }

    /// Capabilities this provider supports
    nonisolated static var capabilities: Set<CloudProviderCapability> { get }

    /// Create an API client for this provider with the given credentials
    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient
}

// MARK: - Default Implementations

extension CloudProvider {
    /// Default implementation returns nil (use SF Symbol iconName instead)
    nonisolated static var logoImageName: String? { nil }
}

// MARK: - Provider Capabilities

/// Capabilities that a cloud provider may support
enum CloudProviderCapability: String, Codable, CaseIterable, Sendable {
    case virtualMachines
    case kubernetes
    case objectStorage
    case databases
    case networking
    case console
    case networkDevices  // For VPN/overlay networks like Tailscale

    /// User-friendly short display name for UI
    var displayName: String {
        switch self {
        case .virtualMachines: return String(localized: "VMs", comment: "Cloud capability: virtual machines")
        case .kubernetes: return String(localized: "Kubernetes", comment: "Cloud capability: Kubernetes container orchestration")
        case .objectStorage: return String(localized: "Storage", comment: "Cloud capability: object storage")
        case .databases: return String(localized: "Databases", comment: "Cloud capability: databases")
        case .networking: return String(localized: "Networking", comment: "Cloud capability: networking")
        case .console: return String(localized: "Console", comment: "Cloud capability: console access")
        case .networkDevices: return String(localized: "Devices", comment: "Cloud capability: network devices")
        }
    }
}

// MARK: - Authentication Methods

/// Authentication method for cloud provider accounts
enum CloudAuthMethod: String, Codable, CaseIterable, Sendable {
    /// Personal Access Token (PAT)
    case pat = "pat"
    /// OAuth 2.0 with PKCE
    case oauth = "oauth"
    /// AWS Access Keys (Access Key ID + Secret Access Key)
    case awsAccessKey = "aws_access_key"
    /// AWS SSO (IAM Identity Center)
    case awsSSO = "aws_sso"
    /// Azure Device Code Flow (Microsoft Entra ID)
    case azureDeviceCode = "azure_device_code"
    /// Tailscale OAuth Client Credentials
    case tailscaleClientCredentials = "tailscale_client_credentials"

    var displayName: String {
        switch self {
        case .pat: return String(localized: "Personal Access Token", comment: "Cloud auth method: personal access token")
        case .oauth: return String(localized: "OAuth 2.0", comment: "Cloud auth method: OAuth 2.0")
        case .awsAccessKey: return String(localized: "Access Keys", comment: "Cloud auth method: AWS access keys")
        case .awsSSO: return String(localized: "AWS SSO", comment: "Cloud auth method: AWS single sign-on")
        case .azureDeviceCode: return String(localized: "Sign in with Microsoft", comment: "Cloud auth method: Azure device code flow")
        case .tailscaleClientCredentials: return String(localized: "OAuth Client Credentials", comment: "Cloud auth method: Tailscale OAuth client credentials")
        }
    }

    var description: String {
        switch self {
        case .pat:
            return String(localized: "Enter a Personal Access Token generated from the provider's dashboard", comment: "Cloud auth method description: personal access token")
        case .oauth:
            return String(localized: "Sign in securely through your browser", comment: "Cloud auth method description: OAuth 2.0")
        case .awsAccessKey:
            return String(localized: "Enter IAM Access Key ID and Secret Access Key", comment: "Cloud auth method description: AWS access keys")
        case .awsSSO:
            return String(localized: "Sign in with AWS IAM Identity Center (SSO)", comment: "Cloud auth method description: AWS SSO")
        case .azureDeviceCode:
            return String(localized: "Sign in with your Microsoft account using device code", comment: "Cloud auth method description: Azure device code flow")
        case .tailscaleClientCredentials:
            return String(localized: "Enter OAuth Client ID and Secret from Tailscale Admin Console", comment: "Cloud auth method description: Tailscale OAuth client credentials")
        }
    }

    var iconName: String {
        switch self {
        case .pat: return "key.fill"
        case .oauth: return "globe"
        case .awsAccessKey: return "key.horizontal.fill"
        case .awsSSO: return "person.badge.key.fill"
        case .azureDeviceCode: return "person.badge.key.fill"
        case .tailscaleClientCredentials: return "key.horizontal.fill"
        }
    }
}

// MARK: - Provider Registry

/// Registry of available cloud providers
@MainActor
class CloudProviderRegistry {
    static let shared = CloudProviderRegistry()

    private var providers: [String: any CloudProvider.Type] = [:]

    private init() {
        // Register built-in providers
        registerBuiltInProviders()
    }

    private func registerBuiltInProviders() {
        register(LinodeProvider.self)
        register(DigitalOceanProvider.self)
        register(AWSProvider.self)
        register(AzureProvider.self)
        register(TailscaleProvider.self)
        register(NetbirdProvider.self)
    }

    /// Register a provider type
    func register<P: CloudProvider>(_ providerType: P.Type) {
        providers[P.providerID] = providerType
    }

    /// Get a provider type by ID
    func provider(for providerID: String) -> (any CloudProvider.Type)? {
        providers[providerID]
    }

    /// Get all registered providers
    var availableProviders: [any CloudProvider.Type] {
        Array(providers.values)
    }

    /// Get provider IDs
    var providerIDs: [String] {
        Array(providers.keys).sorted()
    }
}
