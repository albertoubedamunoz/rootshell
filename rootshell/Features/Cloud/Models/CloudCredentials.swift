import Foundation

// MARK: - Cloud Credentials Model

/// Credentials for a cloud provider account (stored in Keychain)
struct CloudCredentials: Codable, Sendable {
    /// Account ID this credential belongs to
    let accountID: UUID

    /// Provider ID for reference
    let providerID: String

    /// Authentication method
    let authMethod: CloudAuthMethod

    // MARK: - PAT Authentication

    /// Personal Access Token (for PAT auth)
    var accessToken: String?

    // MARK: - OAuth Authentication

    /// OAuth access token
    var oauthAccessToken: String?

    /// OAuth refresh token (if supported)
    var oauthRefreshToken: String?

    /// OAuth token expiration date
    var oauthExpiresAt: Date?

    /// OAuth scopes granted
    var oauthScopes: String?

    // MARK: - AWS Access Key Authentication

    /// AWS Access Key ID
    var awsAccessKeyId: String?

    /// AWS Secret Access Key
    var awsSecretAccessKey: String?

    /// AWS Region for this account
    var awsRegion: String?

    // MARK: - AWS SSO Authentication

    /// AWS SSO session (contains client registration and tokens)
    var awsSSOSession: AWSSSOSession?

    /// AWS SSO selected account ID
    var awsSSOAccountId: String?

    /// AWS SSO selected role name
    var awsSSORole: String?

    /// AWS STS temporary credentials (from SSO)
    var awsSTSCredentials: AWSSTSCredentials?

    // MARK: - Azure Device Code Authentication

    /// Azure tenant ID (or "common" for multi-tenant)
    var azureTenantId: String?

    /// Azure access token
    var azureAccessToken: String?

    /// Azure refresh token
    var azureRefreshToken: String?

    /// Azure token expiration date
    var azureTokenExpiresAt: Date?

    /// Azure subscription ID
    var azureSubscriptionId: String?

    /// Azure subscription display name
    var azureSubscriptionName: String?

    // MARK: - Tailscale Client Credentials Authentication

    /// Tailscale OAuth Client ID
    var tailscaleClientId: String?

    /// Tailscale OAuth Client Secret
    var tailscaleClientSecret: String?

    /// Tailscale tailnet name (e.g., "mycompany" without .ts.net suffix)
    var tailscaleTailnet: String?

    /// Tailscale access token (obtained from client credentials exchange)
    var tailscaleAccessToken: String?

    /// Tailscale token expiration date
    var tailscaleTokenExpiresAt: Date?

    // MARK: - NetBird Authentication

    /// NetBird management/API base URL for self-hosted deployments.
    /// Nil means NetBird Cloud (`https://api.netbird.io`). NetBird uses the
    /// existing `.pat` auth method, so the token lives in `accessToken`.
    var netbirdManagementURL: String?

    // MARK: - Initializers

    /// Create PAT credentials
    static func pat(
        accountID: UUID,
        providerID: String,
        token: String
    ) -> CloudCredentials {
        CloudCredentials(
            accountID: accountID,
            providerID: providerID,
            authMethod: .pat,
            accessToken: token
        )
    }

    /// Create OAuth credentials
    static func oauth(
        accountID: UUID,
        providerID: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: String? = nil
    ) -> CloudCredentials {
        CloudCredentials(
            accountID: accountID,
            providerID: providerID,
            authMethod: .oauth,
            oauthAccessToken: accessToken,
            oauthRefreshToken: refreshToken,
            oauthExpiresAt: expiresAt,
            oauthScopes: scopes
        )
    }

    /// Create AWS Access Key credentials
    static func awsAccessKey(
        accountID: UUID,
        region: String,
        accessKeyId: String,
        secretAccessKey: String
    ) -> CloudCredentials {
        CloudCredentials(
            accountID: accountID,
            providerID: AWSProvider.providerID,
            authMethod: .awsAccessKey,
            awsAccessKeyId: accessKeyId,
            awsSecretAccessKey: secretAccessKey,
            awsRegion: region
        )
    }

    /// Create AWS SSO credentials
    static func awsSSO(
        accountID: UUID,
        region: String,
        ssoSession: AWSSSOSession,
        awsAccountId: String,
        roleName: String,
        stsCredentials: AWSSTSCredentials
    ) -> CloudCredentials {
        let credentials = CloudCredentials(
            accountID: accountID,
            providerID: AWSProvider.providerID,
            authMethod: .awsSSO,
            awsRegion: region,
            awsSSOSession: ssoSession,
            awsSSOAccountId: awsAccountId,
            awsSSORole: roleName,
            awsSTSCredentials: stsCredentials
        )
        return credentials
    }

    /// Create Azure Device Code credentials
    static func azureDeviceCode(
        accountID: UUID,
        tenantId: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        subscriptionId: String,
        subscriptionName: String
    ) -> CloudCredentials {
        CloudCredentials(
            accountID: accountID,
            providerID: AzureProvider.providerID,
            authMethod: .azureDeviceCode,
            azureTenantId: tenantId,
            azureAccessToken: accessToken,
            azureRefreshToken: refreshToken,
            azureTokenExpiresAt: expiresAt,
            azureSubscriptionId: subscriptionId,
            azureSubscriptionName: subscriptionName
        )
    }

    /// Create Tailscale client credentials
    /// - Note: `tailnet` is optional. The API uses "-" to auto-resolve to the OAuth client's tailnet.
    static func tailscale(
        accountID: UUID,
        clientId: String,
        clientSecret: String,
        tailnet: String? = nil,
        accessToken: String? = nil,
        expiresAt: Date? = nil
    ) -> CloudCredentials {
        CloudCredentials(
            accountID: accountID,
            providerID: TailscaleProvider.providerID,
            authMethod: .tailscaleClientCredentials,
            tailscaleClientId: clientId,
            tailscaleClientSecret: clientSecret,
            tailscaleTailnet: tailnet,
            tailscaleAccessToken: accessToken,
            tailscaleTokenExpiresAt: expiresAt
        )
    }

    /// Create NetBird credentials.
    /// - Note: NetBird authenticates with a static Personal Access Token, so it
    ///   reuses the `.pat` auth method (`bearerToken` returns `accessToken`).
    ///   `managementURL` is nil for NetBird Cloud, or a base URL for self-hosted.
    static func netbird(
        accountID: UUID,
        token: String,
        managementURL: String? = nil
    ) -> CloudCredentials {
        var credentials = CloudCredentials(
            accountID: accountID,
            providerID: NetbirdProvider.providerID,
            authMethod: .pat,
            accessToken: token
        )
        credentials.netbirdManagementURL = managementURL
        return credentials
    }

    // MARK: - Token Access

    /// Get the current bearer token for API requests
    nonisolated var bearerToken: String? {
        switch authMethod {
        case .pat:
            return accessToken
        case .oauth:
            return oauthAccessToken
        case .awsAccessKey, .awsSSO:
            return nil // AWS uses Signature V4, not bearer tokens
        case .azureDeviceCode:
            return azureAccessToken
        case .tailscaleClientCredentials:
            return tailscaleAccessToken
        }
    }

    /// Get AWS credentials for API requests
    nonisolated var awsCredentials: AWSCredentials? {
        guard let region = awsRegion else { return nil }

        switch authMethod {
        case .awsAccessKey:
            guard let accessKeyId = awsAccessKeyId,
                  let secretAccessKey = awsSecretAccessKey else {
                return nil
            }
            return AWSCredentials(
                accessKeyId: accessKeyId,
                secretAccessKey: secretAccessKey,
                region: region
            )

        case .awsSSO:
            guard let stsCredentials = awsSTSCredentials else { return nil }
            return stsCredentials.toAWSCredentials(region: region)

        default:
            return nil
        }
    }

    /// Check if OAuth token is expired
    nonisolated var isExpired: Bool {
        switch authMethod {
        case .oauth:
            guard let expiresAt = oauthExpiresAt else { return false }
            return Date() >= expiresAt
        case .awsSSO:
            return awsSTSCredentials?.isExpired ?? true
        case .azureDeviceCode:
            guard let expiresAt = azureTokenExpiresAt else { return true }
            return Date() >= expiresAt
        case .tailscaleClientCredentials:
            guard let expiresAt = tailscaleTokenExpiresAt else { return true }
            return Date() >= expiresAt
        default:
            return false
        }
    }

    /// Check if credentials need refresh
    nonisolated var needsRefresh: Bool {
        switch authMethod {
        case .oauth:
            guard let expiresAt = oauthExpiresAt else { return false }
            let refreshThreshold = expiresAt.addingTimeInterval(-300)
            return Date() >= refreshThreshold
        case .awsSSO:
            return awsSTSCredentials?.needsRefresh ?? true
        case .azureDeviceCode:
            guard let expiresAt = azureTokenExpiresAt else { return true }
            // Refresh 5 minutes before expiration
            let refreshThreshold = expiresAt.addingTimeInterval(-300)
            return Date() >= refreshThreshold
        case .tailscaleClientCredentials:
            guard let expiresAt = tailscaleTokenExpiresAt else { return true }
            // Refresh 5 minutes before expiration
            let refreshThreshold = expiresAt.addingTimeInterval(-300)
            return Date() >= refreshThreshold
        default:
            return false
        }
    }

    /// Check if AWS SSO session needs token refresh
    nonisolated var needsSSOTokenRefresh: Bool {
        guard authMethod == .awsSSO else { return false }
        return awsSSOSession?.needsTokenRefresh ?? true
    }

    /// Check if AWS SSO client registration is expired
    nonisolated var isSSOClientExpired: Bool {
        guard authMethod == .awsSSO else { return false }
        return awsSSOSession?.isClientExpired ?? true
    }
}
