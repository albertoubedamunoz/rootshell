@preconcurrency import Foundation

// MARK: - Linode API Response Models

/// Generic paginated response from Linode API
struct LinodeListResponse<T: Codable>: Codable {
    let data: [T]
    let page: Int
    let pages: Int
    let results: Int
}

// MARK: - Account Info

/// Linode account information response
struct LinodeAccountResponse: Codable, Sendable {
    let email: String?
    let firstName: String?
    let lastName: String?
    let company: String?
    let euuid: String?

    enum CodingKeys: String, CodingKey {
        case email
        case firstName = "first_name"
        case lastName = "last_name"
        case company
        case euuid
    }

    /// Convert to generic ProviderAccountInfo
    nonisolated func toProviderAccountInfo() -> ProviderAccountInfo {
        var displayName: String?
        if let first = firstName, let last = lastName {
            displayName = "\(first) \(last)"
        } else if let email = email {
            displayName = email
        }

        return ProviderAccountInfo(
            accountID: euuid,
            displayName: displayName,
            email: email,
            company: company
        )
    }
}

// MARK: - Instances

/// Linode instance (VM) response
struct LinodeInstanceResponse: Codable, Sendable {
    let id: Int
    let label: String
    let status: String
    let ipv4: [String]
    let ipv6: String?
    let region: String
    let type: String
    let image: String?
    let created: String
    let updated: String
    let tags: [String]
    let specs: LinodeInstanceSpecsResponse?

    enum CodingKeys: String, CodingKey {
        case id, label, status, ipv4, ipv6, region, type, image, created, updated, tags, specs
    }

    /// Convert to provider-agnostic CloudInstance
    nonisolated func toCloudInstance(accountID: UUID) -> CloudInstance {
        var instance = CloudInstance(
            accountID: accountID,
            providerInstanceID: String(id),
            providerID: LinodeProvider.providerID,
            label: label,
            status: mapStatus(status)
        )

        instance.ipv4Address = ipv4.first
        instance.ipv6Address = ipv6
        instance.region = region
        instance.instanceType = type
        instance.image = image
        instance.tags = tags
        instance.lastUpdated = Date()

        return instance
    }

    private nonisolated func mapStatus(_ status: String) -> CloudInstanceStatus {
        switch status.lowercased() {
        case "running": return .running
        case "offline", "stopped": return .stopped
        case "booting", "provisioning": return .provisioning
        case "rebooting": return .rebooting
        case "migrating": return .migrating
        default: return .unknown
        }
    }
}

/// Linode instance specs
struct LinodeInstanceSpecsResponse: Codable, Sendable {
    let memory: Int?
    let vcpus: Int?
    let disk: Int?
    let transfer: Int?
    let gpus: Int?
}

// MARK: - LKE (Kubernetes) Clusters

/// LKE cluster response
struct LinodeLKEClusterResponse: Codable, Sendable {
    let id: Int
    let label: String
    let region: String
    let status: String
    let k8sVersion: String
    let created: String
    let updated: String
    let tags: [String]
    let controlPlane: LinodeLKEControlPlaneResponse?

    enum CodingKeys: String, CodingKey {
        case id, label, region, status
        case k8sVersion = "k8s_version"
        case created, updated, tags
        case controlPlane = "control_plane"
    }

    /// Convert to provider-agnostic CloudKubernetesCluster
    nonisolated func toCloudKubernetesCluster(accountID: UUID) -> CloudKubernetesCluster {
        var cluster = CloudKubernetesCluster(
            accountID: accountID,
            providerClusterID: String(id),
            providerID: LinodeProvider.providerID,
            label: label,
            status: mapStatus(status)
        )

        cluster.kubernetesVersion = k8sVersion
        cluster.region = region
        cluster.highAvailability = controlPlane?.highAvailability ?? false
        cluster.tags = tags
        cluster.lastUpdated = Date()

        return cluster
    }

    private nonisolated func mapStatus(_ status: String) -> CloudClusterStatus {
        switch status.lowercased() {
        case "ready": return .ready
        case "not_ready": return .notReady
        case "provisioning": return .provisioning
        case "upgrading", "updating": return .upgrading
        case "deleting": return .deleting
        default: return .unknown
        }
    }
}

/// LKE control plane configuration
struct LinodeLKEControlPlaneResponse: Codable, Sendable {
    let highAvailability: Bool?

    enum CodingKeys: String, CodingKey {
        case highAvailability = "high_availability"
    }
}

/// LKE node pool response
struct LinodeLKENodePoolResponse: Codable, Sendable {
    let id: Int
    let count: Int
    let type: String
    let nodes: [LinodeLKENodeResponse]?
    let autoscaler: LinodeLKEAutoscalerResponse?
}

/// LKE node response
struct LinodeLKENodeResponse: Codable, Sendable {
    let id: String
    let instanceId: Int?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case instanceId = "instance_id"
        case status
    }
}

/// LKE autoscaler configuration
struct LinodeLKEAutoscalerResponse: Codable, Sendable {
    let enabled: Bool?
    let min: Int?
    let max: Int?
}

/// LKE kubeconfig response
struct LinodeLKEKubeconfigResponse: Codable, Sendable {
    let kubeconfig: String
}

/// LKE API endpoints response
struct LinodeLKEAPIEndpointResponse: Codable, Sendable {
    let endpoint: String
}

// MARK: - LISH (Console)

/// Linode LISH (Linode Shell) response data
/// Used for out-of-band console access via WebSocket
struct LinodeLishData: Codable, Sendable {
    let weblishUrl: String
    let glishUrl: String
    let monitorUrl: String
    let wsProtocols: [String]

    enum CodingKeys: String, CodingKey {
        case weblishUrl = "weblish_url"
        case glishUrl = "glish_url"
        case monitorUrl = "monitor_url"
        case wsProtocols = "ws_protocols"
    }
}

// MARK: - Error Response

/// Linode API error response
struct LinodeErrorResponse: Codable, Sendable {
    let errors: [LinodeAPIErrorDetail]
}

/// Individual error detail
struct LinodeAPIErrorDetail: Codable, Sendable {
    let reason: String
    let field: String?
}
