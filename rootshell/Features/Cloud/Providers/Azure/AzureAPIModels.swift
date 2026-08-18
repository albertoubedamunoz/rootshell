@preconcurrency import Foundation

// MARK: - Device Code Flow Models

/// Response from Azure device code endpoint
struct AzureDeviceCodeResponse: Codable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    let message: String

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

/// Response from Azure token endpoint
struct AzureTokenResponse: Codable, Sendable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let scope: String?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case refreshToken = "refresh_token"
    }
}

/// Azure token error response
struct AzureTokenError: Codable, Sendable {
    let error: String
    let errorDescription: String?
    let errorCodes: [Int]?
    let correlationId: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case errorCodes = "error_codes"
        case correlationId = "correlation_id"
    }
}

// MARK: - Azure Session

/// Azure authentication session
struct AzureSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var tokenExpiresAt: Date
    let tenantId: String

    /// Check if the access token is expired
    var isTokenExpired: Bool {
        Date() >= tokenExpiresAt
    }

    /// Check if the token needs refresh (5 minutes before expiration)
    var needsTokenRefresh: Bool {
        Date() >= tokenExpiresAt.addingTimeInterval(-300)
    }
}

// MARK: - Subscription Models

/// Azure subscription
struct AzureSubscription: Codable, Identifiable, Hashable, Sendable {
    let subscriptionId: String
    let displayName: String
    let state: String
    let tenantId: String?

    var id: String { subscriptionId }
}

/// Response from list subscriptions API
struct AzureSubscriptionListResponse: Codable, Sendable {
    let value: [AzureSubscription]
    let nextLink: String?
}

// MARK: - AKS Models

/// Response from list managed clusters API
struct AKSClusterListResponse: Sendable {
    let value: [AKSCluster]
    let nextLink: String?
}

extension AKSClusterListResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode([AKSCluster].self, forKey: .value)
        nextLink = try container.decodeIfPresent(String.self, forKey: .nextLink)
    }
    private enum CodingKeys: String, CodingKey {
        case value, nextLink
    }
}

/// AKS managed cluster
struct AKSCluster: Sendable {
    let id: String  // Full ARM resource ID
    let name: String
    let location: String
    let properties: AKSClusterProperties
    let tags: [String: String]?

    /// Extract resource group from ARM resource ID
    nonisolated var resourceGroup: String? {
        // Format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ContainerService/managedClusters/{name}
        let components = id.components(separatedBy: "/")
        if let rgIndex = components.firstIndex(of: "resourceGroups"),
           rgIndex + 1 < components.count {
            return components[rgIndex + 1]
        }
        return nil
    }

    /// Extract subscription ID from ARM resource ID
    nonisolated var subscriptionId: String? {
        let components = id.components(separatedBy: "/")
        if let subIndex = components.firstIndex(of: "subscriptions"),
           subIndex + 1 < components.count {
            return components[subIndex + 1]
        }
        return nil
    }

    /// Convert to CloudKubernetesCluster
    nonisolated func toCloudKubernetesCluster(accountID: UUID) -> CloudKubernetesCluster {
        let clusterStatus: CloudClusterStatus
        switch properties.provisioningState?.lowercased() {
        case "succeeded": clusterStatus = .ready
        case "creating": clusterStatus = .provisioning
        case "updating": clusterStatus = .upgrading
        case "deleting": clusterStatus = .deleting
        case "failed": clusterStatus = .notReady
        default: clusterStatus = .unknown
        }

        var cluster = CloudKubernetesCluster(
            id: UUID(),
            accountID: accountID,
            providerClusterID: id,
            providerID: AzureProvider.providerID,
            label: name,
            status: clusterStatus
        )
        cluster.kubernetesVersion = properties.kubernetesVersion
        cluster.region = location
        cluster.apiEndpoint = properties.fqdn.map { "https://\($0)" }
        cluster.nodeCount = properties.agentPoolProfiles?.reduce(0) { $0 + $1.count } ?? 0
        cluster.highAvailability = true  // AKS control plane is managed
        cluster.tags = tags?.map { "\($0.key):\($0.value)" } ?? []
        cluster.isImported = false
        cluster.localClusterID = nil
        cluster.aksResourceId = id
        cluster.aksResourceGroup = resourceGroup
        cluster.aksSubscriptionId = subscriptionId
        return cluster
    }
}

extension AKSCluster: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        location = try container.decode(String.self, forKey: .location)
        properties = try container.decode(AKSClusterProperties.self, forKey: .properties)
        tags = try container.decodeIfPresent([String: String].self, forKey: .tags)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, location, properties, tags
    }
}

/// AKS cluster properties
struct AKSClusterProperties: Sendable {
    let provisioningState: String?
    let kubernetesVersion: String?
    let dnsPrefix: String?
    let fqdn: String?
    let agentPoolProfiles: [AKSAgentPool]?
}

extension AKSClusterProperties: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provisioningState = try container.decodeIfPresent(String.self, forKey: .provisioningState)
        kubernetesVersion = try container.decodeIfPresent(String.self, forKey: .kubernetesVersion)
        dnsPrefix = try container.decodeIfPresent(String.self, forKey: .dnsPrefix)
        fqdn = try container.decodeIfPresent(String.self, forKey: .fqdn)
        agentPoolProfiles = try container.decodeIfPresent([AKSAgentPool].self, forKey: .agentPoolProfiles)
    }
    private enum CodingKeys: String, CodingKey {
        case provisioningState, kubernetesVersion, dnsPrefix, fqdn, agentPoolProfiles
    }
}

/// AKS agent pool (node pool)
struct AKSAgentPool: Sendable {
    let name: String
    let count: Int
    let vmSize: String?
    let osType: String?
    let mode: String?
}

extension AKSAgentPool: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        count = try container.decode(Int.self, forKey: .count)
        vmSize = try container.decodeIfPresent(String.self, forKey: .vmSize)
        osType = try container.decodeIfPresent(String.self, forKey: .osType)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
    }
    private enum CodingKeys: String, CodingKey {
        case name, count, vmSize, osType, mode
    }
}

// MARK: - AKS Credentials Response

/// Response from list cluster user/admin credentials API
struct AKSCredentialsResponse: Sendable {
    let kubeconfigs: [AKSKubeconfig]
}

extension AKSCredentialsResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kubeconfigs = try container.decode([AKSKubeconfig].self, forKey: .kubeconfigs)
    }
    private enum CodingKeys: String, CodingKey {
        case kubeconfigs
    }
}

/// Single kubeconfig entry
struct AKSKubeconfig: Sendable {
    let name: String
    let value: String  // Base64-encoded kubeconfig YAML
}

extension AKSKubeconfig: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
    }
    private enum CodingKeys: String, CodingKey {
        case name, value
    }
}

// MARK: - VM Models

/// Response from list virtual machines API
struct AzureVMListResponse: Sendable {
    let value: [AzureVM]
    let nextLink: String?
}

extension AzureVMListResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode([AzureVM].self, forKey: .value)
        nextLink = try container.decodeIfPresent(String.self, forKey: .nextLink)
    }
    private enum CodingKeys: String, CodingKey {
        case value, nextLink
    }
}

/// Azure virtual machine
struct AzureVM: Codable, Sendable {
    let id: String
    let name: String
    let location: String
    let properties: AzureVMProperties?
    let tags: [String: String]?

    /// Extract resource group from ARM resource ID
    nonisolated var resourceGroup: String? {
        let components = id.components(separatedBy: "/")
        if let rgIndex = components.firstIndex(of: "resourceGroups"),
           rgIndex + 1 < components.count {
            return components[rgIndex + 1]
        }
        return nil
    }

    /// Convert to CloudInstance
    nonisolated func toCloudInstance(accountID: UUID) -> CloudInstance {
        let instanceStatus = mapPowerState(properties?.instanceView?.statuses)

        var instance = CloudInstance(
            id: UUID(),
            accountID: accountID,
            providerInstanceID: id,
            providerID: AzureProvider.providerID,
            label: name,
            status: instanceStatus
        )
        instance.region = location
        instance.instanceType = properties?.hardwareProfile?.vmSize
        instance.image = formatImageInfo()
        instance.tags = tags?.map { "\($0.key):\($0.value)" } ?? []
        // Note: IP addresses require separate network interface API calls
        return instance
    }

    /// Format image info from storage profile
    private nonisolated func formatImageInfo() -> String? {
        guard let imageRef = properties?.storageProfile?.imageReference else {
            return nil
        }
        if let offer = imageRef.offer, let sku = imageRef.sku {
            return "\(offer) \(sku)"
        }
        return imageRef.offer ?? imageRef.publisher
    }

    private nonisolated func mapPowerState(_ statuses: [AzureVMStatus]?) -> CloudInstanceStatus {
        // Look for PowerState status
        if let powerState = statuses?.first(where: { $0.code?.hasPrefix("PowerState/") == true }) {
            switch powerState.code {
            case "PowerState/running": return .running
            case "PowerState/stopped", "PowerState/deallocated": return .stopped
            case "PowerState/starting": return .provisioning
            case "PowerState/stopping", "PowerState/deallocating": return .rebooting
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// Azure VM properties
struct AzureVMProperties: Codable, Sendable {
    let vmId: String?
    let hardwareProfile: AzureHardwareProfile?
    let storageProfile: AzureStorageProfile?
    let osProfile: AzureOSProfile?
    let networkProfile: AzureNetworkProfile?
    let instanceView: AzureVMInstanceView?
}

/// VM hardware profile
struct AzureHardwareProfile: Codable, Sendable {
    let vmSize: String?
}

/// VM storage profile
struct AzureStorageProfile: Codable, Sendable {
    let imageReference: AzureImageReference?
    let osDisk: AzureOSDisk?
}

/// VM image reference
struct AzureImageReference: Codable, Sendable {
    let publisher: String?
    let offer: String?
    let sku: String?
    let version: String?
}

/// VM OS disk
struct AzureOSDisk: Codable, Sendable {
    let osType: String?
    let name: String?
}

/// VM OS profile
struct AzureOSProfile: Codable, Sendable {
    let computerName: String?
    let adminUsername: String?
}

/// VM network profile
struct AzureNetworkProfile: Codable, Sendable {
    let networkInterfaces: [AzureNetworkInterfaceRef]?
}

/// Network interface reference
struct AzureNetworkInterfaceRef: Codable, Sendable {
    let id: String?
}

/// VM instance view (runtime state)
struct AzureVMInstanceView: Codable, Sendable {
    let statuses: [AzureVMStatus]?
}

/// VM status
struct AzureVMStatus: Codable, Sendable {
    let code: String?
    let displayStatus: String?
    let time: String?
}

// MARK: - Network Interface Models (for IP lookup)

/// Network interface
struct AzureNetworkInterface: Sendable {
    let id: String
    let properties: AzureNetworkInterfaceProperties?
}

extension AzureNetworkInterface: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        properties = try container.decodeIfPresent(AzureNetworkInterfaceProperties.self, forKey: .properties)
    }
    private enum CodingKeys: String, CodingKey {
        case id, properties
    }
}

/// Network interface properties
struct AzureNetworkInterfaceProperties: Codable, Sendable {
    let ipConfigurations: [AzureIPConfiguration]?
}

/// IP configuration
struct AzureIPConfiguration: Codable, Sendable {
    let properties: AzureIPConfigurationProperties?
}

/// IP configuration properties
struct AzureIPConfigurationProperties: Codable, Sendable {
    let privateIPAddress: String?
    let publicIPAddress: AzurePublicIPAddressRef?
}

/// Public IP address reference
struct AzurePublicIPAddressRef: Codable, Sendable {
    let id: String?
}

/// Public IP address
struct AzurePublicIPAddress: Sendable {
    let properties: AzurePublicIPAddressProperties?
}

extension AzurePublicIPAddress: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        properties = try container.decodeIfPresent(AzurePublicIPAddressProperties.self, forKey: .properties)
    }
    private enum CodingKeys: String, CodingKey {
        case properties
    }
}

/// Public IP address properties
struct AzurePublicIPAddressProperties: Codable, Sendable {
    let ipAddress: String?
}

// MARK: - Azure API Error

/// Azure API error response
struct AzureAPIErrorResponse: Sendable {
    let error: AzureAPIErrorDetail
}

extension AzureAPIErrorResponse: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(AzureAPIErrorDetail.self, forKey: .error)
    }
    private enum CodingKeys: String, CodingKey {
        case error
    }
}

/// Azure API error detail
struct AzureAPIErrorDetail: Codable, Sendable {
    let code: String
    let message: String
}

// MARK: - Azure Errors

enum AzureError: LocalizedError, Sendable {
    case invalidCredentials
    case authorizationPending
    case slowDown
    case expiredToken
    case accessDenied
    case apiError(code: String, message: String)
    case timeout
    case cancelled
    case invalidResponse
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid Azure credentials"
        case .authorizationPending:
            return "Waiting for user authorization"
        case .slowDown:
            return "Rate limited, slowing down"
        case .expiredToken:
            return "Device code has expired"
        case .accessDenied:
            return "Access denied"
        case .apiError(let code, let message):
            return "Azure API error (\(code)): \(message)"
        case .timeout:
            return "Authentication timed out"
        case .cancelled:
            return "Authentication was cancelled"
        case .invalidResponse:
            return "Invalid response from Azure"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }

    /// Whether polling should continue for this error
    var shouldContinuePolling: Bool {
        switch self {
        case .authorizationPending, .slowDown:
            return true
        default:
            return false
        }
    }
}
