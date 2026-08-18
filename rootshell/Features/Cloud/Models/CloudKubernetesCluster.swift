import Foundation

// MARK: - Cluster Status

/// Status of a cloud Kubernetes cluster
enum CloudClusterStatus: String, Codable, CaseIterable, Sendable {
    case ready = "ready"
    case notReady = "not_ready"
    case provisioning = "provisioning"
    case upgrading = "upgrading"
    case deleting = "deleting"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .ready: return String(localized: "Ready", comment: "Cluster status: cluster is ready")
        case .notReady: return String(localized: "Not Ready", comment: "Cluster status: cluster is not ready")
        case .provisioning: return String(localized: "Provisioning", comment: "Cluster status: cluster is being provisioned")
        case .upgrading: return String(localized: "Upgrading", comment: "Cluster status: cluster is upgrading")
        case .deleting: return String(localized: "Deleting", comment: "Cluster status: cluster is being deleted")
        case .unknown: return String(localized: "Unknown", comment: "Cluster status: unknown state")
        }
    }

    /// Whether the cluster is operational
    var isOperational: Bool {
        self == .ready
    }

    /// Color name for status indicator
    var statusColor: String {
        switch self {
        case .ready: return "green"
        case .notReady: return "red"
        case .provisioning, .upgrading: return "orange"
        case .deleting: return "gray"
        case .unknown: return "secondary"
        }
    }

    /// SF Symbol for status
    var iconName: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .notReady: return "xmark.circle.fill"
        case .provisioning: return "arrow.clockwise.circle.fill"
        case .upgrading: return "arrow.up.circle.fill"
        case .deleting: return "trash.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

// MARK: - Cloud Kubernetes Cluster Model

/// Provider-agnostic representation of a managed Kubernetes cluster
struct CloudKubernetesCluster: Codable, Identifiable, Hashable, Sendable {
    /// Local unique identifier
    let id: UUID

    /// Reference to the cloud account this cluster belongs to
    let accountID: UUID

    /// Provider-specific cluster ID (e.g., LKE cluster ID)
    let providerClusterID: String

    /// Provider type (denormalized)
    let providerID: String

    // MARK: - Display Fields

    /// Cluster label/name from provider
    var label: String

    /// Kubernetes version (e.g., "1.28")
    var kubernetesVersion: String?

    /// Region/datacenter
    var region: String?

    /// Current status
    var status: CloudClusterStatus

    // MARK: - Cluster Details

    /// API server endpoint URL
    var apiEndpoint: String?

    /// Total node count across all pools
    var nodeCount: Int

    /// High availability enabled
    var highAvailability: Bool

    // MARK: - Integration with Local K8s Manager

    /// Whether kubeconfig has been downloaded and imported
    var isImported: Bool

    /// Reference to local KubernetesCluster if imported
    var localClusterID: UUID?

    // MARK: - EKS-Specific Fields

    /// EKS cluster ARN (Amazon Resource Name)
    var clusterARN: String?

    /// EKS certificate authority data (base64-encoded)
    var certificateAuthorityData: String?

    /// EKS cluster name (used for token generation)
    var eksClusterName: String?

    // MARK: - AKS-Specific Fields

    /// Azure resource ID (full ARM path)
    var aksResourceId: String?

    /// Azure resource group name
    var aksResourceGroup: String?

    /// Azure subscription ID
    var aksSubscriptionId: String?

    // MARK: - Metadata

    /// Tags/labels from provider
    var tags: [String]

    /// Date this cache entry was last updated
    var lastUpdated: Date

    nonisolated init(
        id: UUID = UUID(),
        accountID: UUID,
        providerClusterID: String,
        providerID: String,
        label: String,
        status: CloudClusterStatus = .unknown
    ) {
        self.id = id
        self.accountID = accountID
        self.providerClusterID = providerClusterID
        self.providerID = providerID
        self.label = label
        self.status = status
        self.kubernetesVersion = nil
        self.region = nil
        self.apiEndpoint = nil
        self.nodeCount = 0
        self.highAvailability = false
        self.isImported = false
        self.localClusterID = nil
        self.clusterARN = nil
        self.certificateAuthorityData = nil
        self.eksClusterName = nil
        self.aksResourceId = nil
        self.aksResourceGroup = nil
        self.aksSubscriptionId = nil
        self.tags = []
        self.lastUpdated = Date()
    }

    // MARK: - Display Helpers

    /// Display name with version
    var displayNameWithVersion: String {
        if let version = kubernetesVersion {
            return "\(label) (v\(version))"
        }
        return label
    }

    /// Whether this cluster can be used
    var isReady: Bool {
        status.isOperational && apiEndpoint != nil
    }

    /// Formatted region name
    var regionDisplayName: String {
        region ?? "Unknown"
    }

    /// Node count display
    var nodeCountDisplay: String {
        "\(nodeCount) node\(nodeCount == 1 ? "" : "s")"
    }

    // MARK: - Search Support

    /// Check if cluster matches a search query
    func matches(query: String) -> Bool {
        let searchQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        if searchQuery.isEmpty { return true }

        if label.lowercased().contains(searchQuery) { return true }
        if kubernetesVersion?.contains(searchQuery) == true { return true }
        if region?.lowercased().contains(searchQuery) == true { return true }
        if tags.contains(where: { $0.lowercased().contains(searchQuery) }) { return true }

        return false
    }
}
