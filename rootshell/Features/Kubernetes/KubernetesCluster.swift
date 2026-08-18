//
//  KubernetesCluster.swift
//  rootshell
//
//  Model for storing Kubernetes cluster metadata
//

import Foundation

/// Represents an imported Kubernetes cluster configuration
struct KubernetesCluster: Codable, Identifiable, Equatable, Hashable {
    /// Unique identifier for this cluster
    let id: UUID

    /// User-defined label for easy identification
    var label: String

    /// Context name parsed from the kubeconfig
    let contextName: String

    /// Cluster name parsed from the kubeconfig
    let clusterName: String

    /// Server URL from the kubeconfig
    let serverURL: String

    /// User name from the kubeconfig context
    let userName: String

    /// Default namespace (if specified in kubeconfig)
    let namespace: String?

    /// Date when this cluster was imported
    let importedDate: Date

    /// Date when this cluster was last accessed
    var lastAccessedDate: Date?

    init(
        id: UUID = UUID(),
        label: String,
        contextName: String,
        clusterName: String,
        serverURL: String,
        userName: String,
        namespace: String?,
        importedDate: Date = Date(),
        lastAccessedDate: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.contextName = contextName
        self.clusterName = clusterName
        self.serverURL = serverURL
        self.userName = userName
        self.namespace = namespace
        self.importedDate = importedDate
        self.lastAccessedDate = lastAccessedDate
    }

    static func == (lhs: KubernetesCluster, rhs: KubernetesCluster) -> Bool {
        lhs.id == rhs.id
    }
}

/// Health status of a Kubernetes cluster
enum ClusterHealthStatus: Equatable {
    case unknown
    case checking
    case healthy(nodeCount: Int, readyCount: Int)
    case unhealthy(nodeCount: Int, readyCount: Int, notReadyNodes: [String])
    case unreachable(error: String)

    var isHealthy: Bool {
        if case .healthy = self {
            return true
        }
        return false
    }

    var displayText: String {
        switch self {
        case .unknown:
            return String(localized: "Unknown", comment: "Kubernetes cluster health status")
        case .checking:
            return String(localized: "Checking...", comment: "Kubernetes cluster health status")
        case .healthy(let nodeCount, _):
            return String(localized: "\(nodeCount) node\(nodeCount == 1 ? "" : "s") healthy", comment: "Kubernetes cluster health status")
        case .unhealthy(let nodeCount, let readyCount, _):
            return String(localized: "\(readyCount)/\(nodeCount) nodes ready", comment: "Kubernetes cluster health status")
        case .unreachable(let error):
            return String(localized: "Unreachable: \(error)", comment: "Kubernetes cluster health status")
        }
    }

    var statusColor: String {
        switch self {
        case .unknown, .checking:
            return "secondary"
        case .healthy:
            return "green"
        case .unhealthy:
            return "orange"
        case .unreachable:
            return "red"
        }
    }
}

/// Detailed node information for display
struct ClusterNodeInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let isReady: Bool
    let conditions: [NodeCondition]
    let kubeletVersion: String?
    let osImage: String?
    let architecture: String?

    // New fields for enhanced node selection
    let labels: [String: String]
    /// All internal IP addresses (IPv4 and IPv6)
    let internalIPs: [String]
    /// All external IP addresses (IPv4 and IPv6)
    let externalIPs: [String]

    struct NodeCondition: Hashable {
        let type: String
        let status: String
        let reason: String?
        let message: String?
    }

    /// Extracted node pool name from common cloud provider labels
    var nodePool: String? {
        // GKE node pool label
        if let pool = labels["cloud.google.com/gke-nodepool"] {
            return pool
        }
        // EKS node group label
        if let pool = labels["eks.amazonaws.com/nodegroup"] {
            return pool
        }
        // AKS node pool label
        if let pool = labels["kubernetes.azure.com/agentpool"] {
            return pool
        }
        // Linode LKE pool ID
        if let pool = labels["lke.linode.com/pool-id"] {
            return "pool-\(pool)"
        }
        // Generic node pool label (used by some providers)
        if let pool = labels["node.kubernetes.io/instance-type"] {
            return pool
        }
        // Rancher node pool
        if let pool = labels["rke.cattle.io/machine"] {
            return pool
        }
        return nil
    }

    /// Primary internal IP (prefers IPv4)
    var internalIP: String? {
        internalIPs.first { !$0.contains(":") } ?? internalIPs.first
    }

    /// Primary external IP (prefers IPv4)
    var externalIP: String? {
        externalIPs.first { !$0.contains(":") } ?? externalIPs.first
    }

    /// Primary IP address (internal preferred, falls back to external)
    var primaryIP: String? {
        internalIP ?? externalIP
    }

    /// Check if the node matches a search query (name, IP, or label value)
    func matches(searchQuery: String) -> Bool {
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return true }

        // Match against name
        if name.lowercased().contains(query) { return true }

        // Match against all internal IPs
        for ip in internalIPs {
            if ip.lowercased().contains(query) { return true }
        }

        // Match against all external IPs
        for ip in externalIPs {
            if ip.lowercased().contains(query) { return true }
        }

        // Match against label values
        for (key, value) in labels {
            if key.lowercased().contains(query) || value.lowercased().contains(query) {
                return true
            }
        }

        return false
    }
}
