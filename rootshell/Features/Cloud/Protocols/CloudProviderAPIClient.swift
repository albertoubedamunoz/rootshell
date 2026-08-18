import Foundation

// MARK: - Base API Client Protocol

/// Base protocol for all cloud provider API clients
protocol CloudProviderAPIClient: Sendable {
    /// Validate that credentials are still valid
    func validateCredentials() async throws -> Bool

    /// Get account information from the provider
    func getAccountInfo() async throws -> ProviderAccountInfo
}

// MARK: - VM-Capable Provider

/// Protocol for providers that support virtual machines
protocol VMCapableProvider: CloudProviderAPIClient {
    /// List all VM instances for this account
    func listInstances() async throws -> [CloudInstance]
}

// MARK: - Kubernetes-Capable Provider

/// Protocol for providers that support managed Kubernetes
protocol KubernetesCapableProvider: CloudProviderAPIClient {
    /// List all Kubernetes clusters for this account
    func listClusters() async throws -> [CloudKubernetesCluster]

    /// Get kubeconfig for a specific cluster (base64 encoded YAML)
    func getKubeconfig(clusterID: String) async throws -> String
}

// MARK: - Account Info

/// Basic account information from a cloud provider
struct ProviderAccountInfo: Codable, Sendable {
    /// Provider's account ID
    let accountID: String?

    /// Display name or email for the account
    let displayName: String?

    /// Account email address
    let email: String?

    /// Company name (if applicable)
    let company: String?

    nonisolated init(
        accountID: String? = nil,
        displayName: String? = nil,
        email: String? = nil,
        company: String? = nil
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.email = email
        self.company = company
    }
}

// MARK: - API Errors

/// Common errors for cloud provider API operations
enum CloudAPIError: LocalizedError {
    case invalidCredentials
    case invalidManagementURL
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case serverError(Int)
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return String(localized: "Invalid credentials", comment: "Cloud provider API error")
        case .invalidManagementURL:
            return String(localized: "Invalid management URL. Enter a valid http(s) address (e.g. https://netbird.your-company.com).", comment: "Cloud provider API error")
        case .unauthorized:
            return String(localized: "Unauthorized - please check your credentials", comment: "Cloud provider API error")
        case .forbidden:
            return String(localized: "Access denied - insufficient permissions", comment: "Cloud provider API error")
        case .notFound:
            return String(localized: "Resource not found", comment: "Cloud provider API error")
        case .rateLimited:
            return String(localized: "Rate limited - please try again later", comment: "Cloud provider API error")
        case .serverError(let code):
            return String(localized: "Server error (HTTP \(code))", comment: "Cloud provider API error")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)", comment: "Cloud provider API error")
        case .invalidResponse:
            return String(localized: "Invalid response from server", comment: "Cloud provider API error")
        case .decodingError(let error):
            return String(localized: "Failed to decode response: \(error.localizedDescription)", comment: "Cloud provider API error")
        }
    }
}
