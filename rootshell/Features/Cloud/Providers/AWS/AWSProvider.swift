import Foundation

// MARK: - AWS Provider

/// Amazon Web Services cloud provider implementation
struct AWSProvider: CloudProvider {
    nonisolated static let providerID = "aws"
    nonisolated static let displayName = "Amazon Web Services"
    nonisolated static let iconName = "cloud.fill"
    nonisolated static let logoImageName: String? = "AWSLogo"

    #if AWS_SSO_ENABLED
    nonisolated static let supportedAuthMethods: [CloudAuthMethod] = [.awsAccessKey, .awsSSO]
    #else
    nonisolated static let supportedAuthMethods: [CloudAuthMethod] = [.awsAccessKey]
    #endif

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .virtualMachines,
        .kubernetes,
        .console
    ]

    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient {
        AWSAPIClient(credentials: credentials)
    }

    // MARK: - AWS Regions

    /// AWS region definition
    struct Region: Identifiable, Hashable {
        let id: String
        let name: String
        let description: String

        var displayName: String {
            "\(name) (\(id))"
        }
    }

    /// All supported AWS regions
    static let regions: [Region] = [
        // US Regions
        Region(id: "us-east-1", name: "US East", description: "N. Virginia"),
        Region(id: "us-east-2", name: "US East", description: "Ohio"),
        Region(id: "us-west-1", name: "US West", description: "N. California"),
        Region(id: "us-west-2", name: "US West", description: "Oregon"),

        // Europe Regions
        Region(id: "eu-west-1", name: "Europe", description: "Ireland"),
        Region(id: "eu-west-2", name: "Europe", description: "London"),
        Region(id: "eu-west-3", name: "Europe", description: "Paris"),
        Region(id: "eu-central-1", name: "Europe", description: "Frankfurt"),
        Region(id: "eu-central-2", name: "Europe", description: "Zurich"),
        Region(id: "eu-north-1", name: "Europe", description: "Stockholm"),
        Region(id: "eu-south-1", name: "Europe", description: "Milan"),
        Region(id: "eu-south-2", name: "Europe", description: "Spain"),

        // Asia Pacific Regions
        Region(id: "ap-northeast-1", name: "Asia Pacific", description: "Tokyo"),
        Region(id: "ap-northeast-2", name: "Asia Pacific", description: "Seoul"),
        Region(id: "ap-northeast-3", name: "Asia Pacific", description: "Osaka"),
        Region(id: "ap-southeast-1", name: "Asia Pacific", description: "Singapore"),
        Region(id: "ap-southeast-2", name: "Asia Pacific", description: "Sydney"),
        Region(id: "ap-southeast-3", name: "Asia Pacific", description: "Jakarta"),
        Region(id: "ap-southeast-4", name: "Asia Pacific", description: "Melbourne"),
        Region(id: "ap-southeast-5", name: "Asia Pacific", description: "Malaysia"),
        Region(id: "ap-southeast-7", name: "Asia Pacific", description: "Thailand"),
        Region(id: "ap-south-1", name: "Asia Pacific", description: "Mumbai"),
        Region(id: "ap-south-2", name: "Asia Pacific", description: "Hyderabad"),
        Region(id: "ap-east-1", name: "Asia Pacific", description: "Hong Kong"),

        // South America
        Region(id: "sa-east-1", name: "South America", description: "São Paulo"),

        // Mexico
        Region(id: "mx-central-1", name: "Mexico", description: "Querétaro"),

        // Canada
        Region(id: "ca-central-1", name: "Canada", description: "Central"),
        Region(id: "ca-west-1", name: "Canada", description: "Calgary"),

        // Middle East
        Region(id: "me-south-1", name: "Middle East", description: "Bahrain"),
        Region(id: "me-central-1", name: "Middle East", description: "UAE"),

        // Africa
        Region(id: "af-south-1", name: "Africa", description: "Cape Town"),

        // Israel
        Region(id: "il-central-1", name: "Israel", description: "Tel Aviv")
    ]

    /// Get display name for a region ID
    static func regionDisplayName(for regionID: String) -> String {
        if let region = regions.first(where: { $0.id == regionID }) {
            return "\(region.name) (\(region.description))"
        }
        return regionID
    }

    /// Default region
    static let defaultRegion = "us-east-1"

    // MARK: - Help Text

    static let accessKeyHelpText = """
    Create an IAM user with programmatic access and attach a policy with \
    ec2:DescribeInstances and eks:ListClusters, eks:DescribeCluster permissions.
    """

    static let accessKeyGenerateURL = URL(string: "https://console.aws.amazon.com/iam/home#/users")!

    static let ssoHelpText = """
    Enter your AWS SSO start URL (e.g., https://your-org.awsapps.com/start) \
    and select a region. You'll be prompted to sign in via your browser.
    """
}

// MARK: - AWS Credentials Model

/// AWS credentials for API access
struct AWSCredentials: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String?
    let region: String

    nonisolated init(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        region: String
    ) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
    }

    /// Convert to AWSSignatureV4.Credentials for signing
    nonisolated var signingCredentials: AWSSignatureV4.Credentials {
        AWSSignatureV4.Credentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken
        )
    }
}

// MARK: - AWS SSO Session

/// AWS SSO session containing client registration and tokens
struct AWSSSOSession: Codable, Sendable {
    // Client registration (long-lived, ~90 days)
    let clientId: String
    let clientSecret: String
    let clientSecretExpiresAt: Date

    // SSO tokens (short-lived, ~8 hours)
    var accessToken: String
    var refreshToken: String?
    var tokenExpiresAt: Date

    // SSO configuration
    let startURL: String
    let region: String

    nonisolated var isClientExpired: Bool {
        Date() >= clientSecretExpiresAt
    }

    nonisolated var isTokenExpired: Bool {
        Date() >= tokenExpiresAt
    }

    /// Check if token needs refresh (5 minutes before expiration)
    nonisolated var needsTokenRefresh: Bool {
        Date() >= tokenExpiresAt.addingTimeInterval(-300)
    }
}

// MARK: - AWS STS Credentials

/// Temporary AWS credentials from STS
struct AWSSTSCredentials: Codable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    let expiration: Date

    nonisolated var isExpired: Bool {
        Date() >= expiration
    }

    /// Check if credentials need refresh (5 minutes before expiration)
    nonisolated var needsRefresh: Bool {
        Date() >= expiration.addingTimeInterval(-300)
    }

    /// Convert to AWSCredentials with region
    nonisolated func toAWSCredentials(region: String) -> AWSCredentials {
        AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            region: region
        )
    }
}

// MARK: - AWS SSO Account

/// AWS account available via SSO
struct AWSSSOAccount: Codable, Identifiable, Hashable, Sendable {
    let accountId: String
    let accountName: String
    let emailAddress: String?

    nonisolated var id: String { accountId }

    nonisolated var displayName: String {
        if let email = emailAddress {
            return "\(accountName) (\(email))"
        }
        return "\(accountName) (\(accountId))"
    }
}

// MARK: - AWS SSO Role

/// AWS IAM role available via SSO
struct AWSSSORole: Codable, Identifiable, Hashable, Sendable {
    let roleName: String
    let accountId: String

    nonisolated var id: String { "\(accountId):\(roleName)" }
}
