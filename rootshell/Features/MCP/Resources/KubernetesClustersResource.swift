//
//  KubernetesClustersResource.swift
//  rootshell
//
//  MCP resource provider for Kubernetes clusters
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// MCP resource provider for Kubernetes clusters
/// Exposes both imported local clusters and cloud-managed clusters
struct KubernetesClustersResourceProvider: MCPResourceProvider {
    static let scheme = "k8s"

    @MainActor
    func listResources() async throws -> [MCPResource] {
        var resources: [MCPResource] = []

        // Cloud clusters from CloudCacheManager
        let cloudClusters = CloudCacheManager.shared.allClusters
        for cluster in cloudClusters {
            resources.append(MCPResource(
                uri: "k8s://cloud/\(cluster.providerID)/\(cluster.providerClusterID)",
                name: cluster.label,
                description: "[\(cluster.status.displayName)] \(cluster.providerID) K8s v\(cluster.kubernetesVersion ?? "?")",
                mimeType: "application/json"
            ))
        }

        // Local imported clusters from KubernetesClusterManager
        let localClusters = KubernetesClusterManager.shared.clusters
        for cluster in localClusters {
            resources.append(MCPResource(
                uri: "k8s://local/\(cluster.id.uuidString)",
                name: cluster.label,
                description: "Imported cluster - \(cluster.contextName)",
                mimeType: "application/json"
            ))
        }

        return resources
    }

    @MainActor
    func readResource(uri: String) async throws -> MCPResourceContent {
        // Parse URI: k8s://cloud/{providerID}/{clusterID} or k8s://local/{id}
        let path = uri.replacingOccurrences(of: "k8s://", with: "")
        let components = path.split(separator: "/")

        guard !components.isEmpty else {
            throw MCPError.resourceNotFound(uri)
        }

        let source = String(components[0])

        if source == "cloud" {
            return try await readCloudCluster(uri: uri, components: Array(components.dropFirst()))
        } else if source == "local" {
            return try await readLocalCluster(uri: uri, components: Array(components.dropFirst()))
        } else {
            throw MCPError.resourceNotFound(uri)
        }
    }

    @MainActor
    private func readCloudCluster(uri: String, components: [Substring]) async throws -> MCPResourceContent {
        guard components.count >= 2 else {
            throw MCPError.resourceNotFound(uri)
        }

        let providerID = String(components[0])
        let clusterID = String(components[1])

        // Find the cluster
        let clusters = CloudCacheManager.shared.allClusters
        guard let cluster = clusters.first(where: {
            $0.providerID == providerID && $0.providerClusterID == clusterID
        }) else {
            throw MCPError.resourceNotFound(uri)
        }

        // Convert to JSON
        let dto = CloudKubernetesClusterDTO(from: cluster)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"

        return MCPResourceContent(
            uri: uri,
            mimeType: "application/json",
            text: jsonString
        )
    }

    @MainActor
    private func readLocalCluster(uri: String, components: [Substring]) async throws -> MCPResourceContent {
        guard let idString = components.first,
              let id = UUID(uuidString: String(idString)) else {
            throw MCPError.resourceNotFound(uri)
        }

        // Find the cluster
        let clusters = KubernetesClusterManager.shared.clusters
        guard let cluster = clusters.first(where: { $0.id == id }) else {
            throw MCPError.resourceNotFound(uri)
        }

        // Get health status from the manager's published dictionary
        let healthStatus = KubernetesClusterManager.shared.clusterHealthStatus[id]

        // Convert to JSON
        let dto = LocalKubernetesClusterDTO(from: cluster, health: healthStatus)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(dto)
        let jsonString = String(data: data, encoding: .utf8) ?? "{}"

        return MCPResourceContent(
            uri: uri,
            mimeType: "application/json",
            text: jsonString
        )
    }
}

// MARK: - DTOs

/// DTO for cloud Kubernetes cluster serialization
private struct CloudKubernetesClusterDTO: Codable {
    let id: String
    let label: String
    let provider: String
    let region: String?
    let kubernetesVersion: String?
    let status: String
    let nodeCount: Int
    let highAvailability: Bool
    let apiEndpoint: String?
    let isImported: Bool
    let lastUpdated: String

    init(from cluster: CloudKubernetesCluster) {
        self.id = cluster.providerClusterID
        self.label = cluster.label
        self.provider = cluster.providerID
        self.region = cluster.region
        self.kubernetesVersion = cluster.kubernetesVersion
        self.status = cluster.status.rawValue
        self.nodeCount = cluster.nodeCount
        self.highAvailability = cluster.highAvailability
        self.apiEndpoint = cluster.apiEndpoint
        self.isImported = cluster.isImported
        self.lastUpdated = ISO8601DateFormatter().string(from: cluster.lastUpdated)
    }
}

/// DTO for local Kubernetes cluster serialization
private struct LocalKubernetesClusterDTO: Codable {
    let id: String
    let label: String
    let contextName: String
    let clusterName: String
    let serverURL: String
    let userName: String
    let namespace: String?
    let importedDate: String
    let lastAccessedDate: String?
    let health: HealthDTO?

    struct HealthDTO: Codable {
        let status: String
        let nodeCount: Int?
        let readyCount: Int?
        let notReadyNodes: [String]?
        let error: String?
    }

    init(from cluster: KubernetesCluster, health: ClusterHealthStatus?) {
        self.id = cluster.id.uuidString
        self.label = cluster.label
        self.contextName = cluster.contextName
        self.clusterName = cluster.clusterName
        self.serverURL = cluster.serverURL
        self.userName = cluster.userName
        self.namespace = cluster.namespace
        self.importedDate = ISO8601DateFormatter().string(from: cluster.importedDate)
        self.lastAccessedDate = cluster.lastAccessedDate.map { ISO8601DateFormatter().string(from: $0) }

        // Convert health status
        if let health = health {
            switch health {
            case .unknown:
                self.health = HealthDTO(status: "unknown", nodeCount: nil, readyCount: nil, notReadyNodes: nil, error: nil)
            case .checking:
                self.health = HealthDTO(status: "checking", nodeCount: nil, readyCount: nil, notReadyNodes: nil, error: nil)
            case .healthy(let nodeCount, let readyCount):
                self.health = HealthDTO(status: "healthy", nodeCount: nodeCount, readyCount: readyCount, notReadyNodes: nil, error: nil)
            case .unhealthy(let nodeCount, let readyCount, let notReadyNodes):
                self.health = HealthDTO(status: "unhealthy", nodeCount: nodeCount, readyCount: readyCount, notReadyNodes: notReadyNodes, error: nil)
            case .unreachable(let error):
                self.health = HealthDTO(status: "unreachable", nodeCount: nil, readyCount: nil, notReadyNodes: nil, error: error)
            }
        } else {
            self.health = nil
        }
    }
}
