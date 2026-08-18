//
//  KubernetesClusterManager.swift
//  rootshell
//
//  Manager for Kubernetes cluster CRUD operations and health checking
//

import Foundation
import Combine
import os.log
import SwiftkubeClient
import SwiftkubeModel

@MainActor
class KubernetesClusterManager: ObservableObject {
    static let shared = KubernetesClusterManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesClusterManager")
    private let keychainManager = KeychainManager.shared

    // UserDefaults key for cluster metadata
    private let clustersMetadataKey = "kubernetes_clusters_metadata"

    // Published properties
    @Published private(set) var clusters: [KubernetesCluster] = []
    @Published private(set) var clusterHealthStatus: [UUID: ClusterHealthStatus] = [:]

    // Event publisher for cluster changes
    let clustersDidChange = PassthroughSubject<Void, Never>()

    private init() {
        loadClusters()
    }

    // MARK: - Cluster Management

    /// Import a kubeconfig and create a new cluster entry
    /// - Parameters:
    ///   - kubeconfigYAML: The kubeconfig YAML content
    ///   - label: User-defined label (if nil, will use context name)
    /// - Returns: The created KubernetesCluster
    /// - Throws: KubernetesImportError if import fails
    func importKubeconfig(_ kubeconfigYAML: String, label: String? = nil) throws -> KubernetesCluster {
        Self.logger.info("Importing kubeconfig...")

        // Parse the kubeconfig
        let kubeConfig: KubeConfig
        do {
            kubeConfig = try KubeConfig.from(config: kubeconfigYAML)
        } catch {
            Self.logger.error("Failed to parse kubeconfig: \(error.localizedDescription)")
            throw KubernetesImportError.invalidKubeconfig(error.localizedDescription)
        }

        // Get the current context
        guard let currentContextName = kubeConfig.currentContext else {
            throw KubernetesImportError.noCurrentContext
        }

        // Find the context
        guard let namedContext = kubeConfig.contexts?.first(where: { $0.name == currentContextName }) else {
            throw KubernetesImportError.contextNotFound(currentContextName)
        }

        let context = namedContext.context

        // Find the cluster
        guard let namedCluster = kubeConfig.clusters?.first(where: { $0.name == context.cluster }) else {
            throw KubernetesImportError.clusterNotFound(context.cluster)
        }

        // Check for duplicates based on server URL + context name
        let serverURL = namedCluster.cluster.server
        if clusters.contains(where: { $0.serverURL == serverURL && $0.contextName == currentContextName }) {
            throw KubernetesImportError.duplicateContext(serverURL: serverURL, contextName: currentContextName)
        }

        // Create the cluster entry
        let clusterId = UUID()
        let clusterLabel = label?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? label!.trimmingCharacters(in: .whitespaces)
            : currentContextName

        let cluster = KubernetesCluster(
            id: clusterId,
            label: clusterLabel,
            contextName: currentContextName,
            clusterName: namedCluster.name,
            serverURL: serverURL,
            userName: context.user,
            namespace: context.namespace,
            importedDate: Date()
        )

        // Save kubeconfig to keychain
        guard let kubeconfigData = kubeconfigYAML.data(using: .utf8) else {
            throw KubernetesImportError.dataConversionFailed
        }

        do {
            try keychainManager.saveKubeconfig(kubeconfigData, identifier: clusterId.uuidString)
        } catch {
            Self.logger.error("Failed to save kubeconfig to keychain: \(error.localizedDescription)")
            throw KubernetesImportError.keychainSaveFailed(error.localizedDescription)
        }

        // Add to clusters list and save
        clusters.append(cluster)
        saveClusters()
        clustersDidChange.send()

        Self.logger.info("Successfully imported cluster: \(cluster.label) (\(cluster.contextName))")
        return cluster
    }

    /// Delete a cluster
    /// - Parameter cluster: The cluster to delete
    func deleteCluster(_ cluster: KubernetesCluster) {
        Self.logger.info("Deleting cluster: \(cluster.label)")

        // Remove from keychain
        do {
            try keychainManager.deleteKubeconfig(identifier: cluster.id.uuidString)
        } catch {
            Self.logger.warning("Failed to delete kubeconfig from keychain: \(error.localizedDescription)")
        }

        // Remove from clusters list
        clusters.removeAll { $0.id == cluster.id }
        clusterHealthStatus.removeValue(forKey: cluster.id)
        saveClusters()
        clustersDidChange.send()
    }

    /// Update a cluster's label
    /// - Parameters:
    ///   - cluster: The cluster to update
    ///   - newLabel: The new label
    func updateClusterLabel(_ cluster: KubernetesCluster, newLabel: String) {
        guard let index = clusters.firstIndex(where: { $0.id == cluster.id }) else { return }

        clusters[index].label = newLabel.trimmingCharacters(in: .whitespaces)
        saveClusters()
        clustersDidChange.send()
    }

    /// Get the kubeconfig for a cluster
    /// - Parameter cluster: The cluster
    /// - Returns: The kubeconfig YAML string
    func getKubeconfig(for cluster: KubernetesCluster) throws -> String {
        let data = try keychainManager.loadKubeconfig(identifier: cluster.id.uuidString)
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw KubernetesImportError.dataConversionFailed
        }
        return yaml
    }

    /// Update the kubeconfig for an existing cluster (refresh from cloud provider)
    /// - Parameters:
    ///   - cluster: The cluster to update
    ///   - newKubeconfigYAML: The new kubeconfig YAML content
    /// - Throws: KubernetesImportError if update fails
    func updateKubeconfig(for cluster: KubernetesCluster, newKubeconfigYAML: String) throws {
        Self.logger.info("Updating kubeconfig for cluster: \(cluster.label)")

        // Validate the new kubeconfig parses correctly
        let kubeConfig: KubeConfig
        do {
            kubeConfig = try KubeConfig.from(config: newKubeconfigYAML)
        } catch {
            Self.logger.error("Failed to parse new kubeconfig: \(error.localizedDescription)")
            throw KubernetesImportError.invalidKubeconfig(error.localizedDescription)
        }

        // Verify it has a current context
        guard kubeConfig.currentContext != nil else {
            throw KubernetesImportError.noCurrentContext
        }

        // Convert to data
        guard let kubeconfigData = newKubeconfigYAML.data(using: .utf8) else {
            throw KubernetesImportError.dataConversionFailed
        }

        // Update kubeconfig in keychain (overwrite existing)
        do {
            try keychainManager.saveKubeconfig(kubeconfigData, identifier: cluster.id.uuidString)
        } catch {
            Self.logger.error("Failed to update kubeconfig in keychain: \(error.localizedDescription)")
            throw KubernetesImportError.keychainSaveFailed(error.localizedDescription)
        }

        // Update last accessed date
        if let index = clusters.firstIndex(where: { $0.id == cluster.id }) {
            clusters[index].lastAccessedDate = Date()
            saveClusters()
            clustersDidChange.send()
        }

        Self.logger.info("Successfully updated kubeconfig for cluster: \(cluster.label)")
    }

    /// Find a cluster by its server URL
    /// - Parameter serverURL: The server URL to search for
    /// - Returns: The matching cluster, if found
    func cluster(byServerURL serverURL: String) -> KubernetesCluster? {
        clusters.first { $0.serverURL == serverURL }
    }

    // MARK: - Health Checking

    /// Check the health of a cluster
    /// - Parameter cluster: The cluster to check
    func checkClusterHealth(_ cluster: KubernetesCluster) async {
        Self.logger.info("Checking health for cluster: \(cluster.label)")
        clusterHealthStatus[cluster.id] = .checking

        do {
            // Load kubeconfig
            let kubeconfigYAML = try getKubeconfig(for: cluster)
            let kubeConfig = try KubeConfig.from(config: kubeconfigYAML)

            // Create client
            guard let client = KubernetesClient(kubeConfig: kubeConfig, contextName: cluster.contextName) else {
                clusterHealthStatus[cluster.id] = .unreachable(error: "Failed to create client")
                return
            }

            defer {
                Task {
                    try? await client.shutdown()
                }
            }

            // List nodes
            let nodeList = try await client.nodes.list()
            let nodes = nodeList.items

            var readyCount = 0
            var notReadyNodes: [String] = []

            for node in nodes {
                let nodeName = node.metadata?.name ?? "unknown"
                let isReady = node.status?.conditions?.contains { condition in
                    condition.type == "Ready" && condition.status == "True"
                } ?? false

                if isReady {
                    readyCount += 1
                } else {
                    notReadyNodes.append(nodeName)
                }
            }

            let totalCount = nodes.count

            if readyCount == totalCount && totalCount > 0 {
                clusterHealthStatus[cluster.id] = .healthy(nodeCount: totalCount, readyCount: readyCount)
            } else if totalCount > 0 {
                clusterHealthStatus[cluster.id] = .unhealthy(
                    nodeCount: totalCount,
                    readyCount: readyCount,
                    notReadyNodes: notReadyNodes
                )
            } else {
                clusterHealthStatus[cluster.id] = .unhealthy(
                    nodeCount: 0,
                    readyCount: 0,
                    notReadyNodes: []
                )
            }

            // Update last accessed date
            if let index = clusters.firstIndex(where: { $0.id == cluster.id }) {
                clusters[index].lastAccessedDate = Date()
                saveClusters()
            }

            Self.logger.info("Health check complete for \(cluster.label): \(readyCount)/\(totalCount) nodes ready")

        } catch {
            Self.logger.error("Health check failed for \(cluster.label): \(error.localizedDescription)")
            clusterHealthStatus[cluster.id] = .unreachable(error: error.localizedDescription)
        }
    }

    /// Check health of all clusters
    func checkAllClustersHealth() async {
        for cluster in clusters {
            await checkClusterHealth(cluster)
        }
    }

    /// Get detailed node information for a cluster
    /// - Parameter cluster: The cluster
    /// - Returns: Array of node info
    func getClusterNodes(_ cluster: KubernetesCluster) async throws -> [ClusterNodeInfo] {
        let kubeconfigYAML = try getKubeconfig(for: cluster)
        let kubeConfig = try KubeConfig.from(config: kubeconfigYAML)

        guard let client = KubernetesClient(kubeConfig: kubeConfig, contextName: cluster.contextName) else {
            throw KubernetesImportError.clientCreationFailed
        }

        defer {
            Task {
                try? await client.shutdown()
            }
        }

        let nodeList = try await client.nodes.list()

        return nodeList.items.map { node in
            let conditions = node.status?.conditions?.map { condition in
                ClusterNodeInfo.NodeCondition(
                    type: condition.type,
                    status: condition.status,
                    reason: condition.reason,
                    message: condition.message
                )
            } ?? []

            let isReady = node.status?.conditions?.contains { condition in
                condition.type == "Ready" && condition.status == "True"
            } ?? false

            // Extract labels
            let labels = node.metadata?.labels ?? [:]

            // Extract all IP addresses from node addresses
            var internalIPs: [String] = []
            var externalIPs: [String] = []
            if let addresses = node.status?.addresses {
                for address in addresses {
                    let addressType = address.type.lowercased()
                    if addressType == "internalip" {
                        internalIPs.append(address.address)
                    } else if addressType == "externalip" {
                        externalIPs.append(address.address)
                    }
                }
            }

            return ClusterNodeInfo(
                id: node.metadata?.uid ?? UUID().uuidString,
                name: node.metadata?.name ?? "unknown",
                isReady: isReady,
                conditions: conditions,
                kubeletVersion: node.status?.nodeInfo?.kubeletVersion,
                osImage: node.status?.nodeInfo?.osImage,
                architecture: node.status?.nodeInfo?.architecture,
                labels: labels,
                internalIPs: internalIPs,
                externalIPs: externalIPs
            )
        }
    }

    // MARK: - Persistence

    private func loadClusters() {
        guard let data = UserDefaults.standard.data(forKey: clustersMetadataKey) else {
            Self.logger.info("No saved clusters found")
            return
        }

        do {
            clusters = try JSONDecoder().decode([KubernetesCluster].self, from: data)
            Self.logger.info("Loaded \(self.clusters.count) clusters from storage")
        } catch {
            Self.logger.error("Failed to decode clusters: \(error.localizedDescription)")
        }
    }

    private func saveClusters() {
        do {
            let data = try JSONEncoder().encode(clusters)
            UserDefaults.standard.set(data, forKey: clustersMetadataKey)
            Self.logger.info("Saved \(self.clusters.count) clusters to storage")
        } catch {
            Self.logger.error("Failed to encode clusters: \(error.localizedDescription)")
        }
    }

    // MARK: - Kubeconfig Parsing Helpers

    /// Parse a kubeconfig and extract context information without importing
    /// - Parameter kubeconfigYAML: The kubeconfig YAML content
    /// - Returns: Parsed context info
    func parseKubeconfig(_ kubeconfigYAML: String) throws -> ParsedKubeconfigInfo {
        let kubeConfig = try KubeConfig.from(config: kubeconfigYAML)

        guard let currentContextName = kubeConfig.currentContext else {
            throw KubernetesImportError.noCurrentContext
        }

        guard let namedContext = kubeConfig.contexts?.first(where: { $0.name == currentContextName }) else {
            throw KubernetesImportError.contextNotFound(currentContextName)
        }

        let context = namedContext.context

        guard let namedCluster = kubeConfig.clusters?.first(where: { $0.name == context.cluster }) else {
            throw KubernetesImportError.clusterNotFound(context.cluster)
        }

        let allContexts = kubeConfig.contexts?.map { $0.name } ?? []

        // Build ParsedContextInfo for each valid context
        var parsedContexts: [ParsedContextInfo] = []
        for namedCtx in kubeConfig.contexts ?? [] {
            let ctx = namedCtx.context
            // Find the cluster for this context
            guard let cluster = kubeConfig.clusters?.first(where: { $0.name == ctx.cluster }) else {
                // Skip contexts with missing cluster definitions
                Self.logger.debug("Skipping context '\(namedCtx.name)' - cluster '\(ctx.cluster)' not found")
                continue
            }

            parsedContexts.append(ParsedContextInfo(
                contextName: namedCtx.name,
                clusterName: cluster.name,
                serverURL: cluster.cluster.server,
                userName: ctx.user,
                namespace: ctx.namespace,
                isCurrentContext: namedCtx.name == currentContextName
            ))
        }

        return ParsedKubeconfigInfo(
            currentContext: currentContextName,
            clusterName: namedCluster.name,
            serverURL: namedCluster.cluster.server,
            userName: context.user,
            namespace: context.namespace,
            availableContexts: allContexts,
            contexts: parsedContexts
        )
    }

    // MARK: - Multi-Context Import

    /// Import multiple contexts from a kubeconfig
    /// - Parameters:
    ///   - kubeconfigYAML: The kubeconfig YAML content
    ///   - contextNames: The names of contexts to import
    ///   - labelPrefix: Optional prefix for labels (context name will be appended)
    /// - Returns: Array of successfully imported clusters
    /// - Throws: KubernetesImportError if all imports fail or partial failure occurs
    func importKubeconfig(
        _ kubeconfigYAML: String,
        contextNames: [String],
        labelPrefix: String?
    ) throws -> [KubernetesCluster] {
        Self.logger.info("Importing \(contextNames.count) contexts from kubeconfig...")

        // Parse the kubeconfig once
        let kubeConfig: KubeConfig
        do {
            kubeConfig = try KubeConfig.from(config: kubeconfigYAML)
        } catch {
            Self.logger.error("Failed to parse kubeconfig: \(error.localizedDescription)")
            throw KubernetesImportError.invalidKubeconfig(error.localizedDescription)
        }

        var importedClusters: [KubernetesCluster] = []
        var succeededContexts: [String] = []
        var failedContexts: [(context: String, error: String)] = []

        for contextName in contextNames {
            do {
                let label: String?
                if let prefix = labelPrefix, !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                    label = "\(prefix.trimmingCharacters(in: .whitespaces)) - \(contextName)"
                } else {
                    label = contextName
                }

                let cluster = try importSingleContext(
                    from: kubeConfig,
                    contextName: contextName,
                    kubeconfigYAML: kubeconfigYAML,
                    label: label
                )
                importedClusters.append(cluster)
                succeededContexts.append(contextName)
            } catch {
                Self.logger.warning("Failed to import context '\(contextName)': \(error.localizedDescription)")
                failedContexts.append((context: contextName, error: error.localizedDescription))
            }
        }

        // Handle results
        if importedClusters.isEmpty {
            // All failed
            throw KubernetesImportError.partialImportFailure(succeeded: [], failed: failedContexts)
        } else if !failedContexts.isEmpty {
            // Partial success - throw error with details but still return imported clusters
            // The caller can decide how to handle this
            Self.logger.warning("Partial import: \(succeededContexts.count) succeeded, \(failedContexts.count) failed")
            throw KubernetesImportError.partialImportFailure(succeeded: succeededContexts, failed: failedContexts)
        }

        Self.logger.info("Successfully imported \(importedClusters.count) clusters")
        return importedClusters
    }

    /// Import a single context from a pre-parsed kubeconfig
    private func importSingleContext(
        from kubeConfig: KubeConfig,
        contextName: String,
        kubeconfigYAML: String,
        label: String?
    ) throws -> KubernetesCluster {
        // Find the context
        guard let namedContext = kubeConfig.contexts?.first(where: { $0.name == contextName }) else {
            throw KubernetesImportError.contextNotFound(contextName)
        }

        let context = namedContext.context

        // Find the cluster
        guard let namedCluster = kubeConfig.clusters?.first(where: { $0.name == context.cluster }) else {
            throw KubernetesImportError.clusterNotFound(context.cluster)
        }

        // Check for duplicates based on server URL + context name
        let serverURL = namedCluster.cluster.server
        if clusters.contains(where: { $0.serverURL == serverURL && $0.contextName == contextName }) {
            throw KubernetesImportError.duplicateContext(serverURL: serverURL, contextName: contextName)
        }

        // Create the cluster entry
        let clusterId = UUID()
        let clusterLabel = label?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? label!.trimmingCharacters(in: .whitespaces)
            : contextName

        let cluster = KubernetesCluster(
            id: clusterId,
            label: clusterLabel,
            contextName: contextName,
            clusterName: namedCluster.name,
            serverURL: serverURL,
            userName: context.user,
            namespace: context.namespace,
            importedDate: Date()
        )

        // Save kubeconfig to keychain
        guard let kubeconfigData = kubeconfigYAML.data(using: .utf8) else {
            throw KubernetesImportError.dataConversionFailed
        }

        do {
            try keychainManager.saveKubeconfig(kubeconfigData, identifier: clusterId.uuidString)
        } catch {
            Self.logger.error("Failed to save kubeconfig to keychain: \(error.localizedDescription)")
            throw KubernetesImportError.keychainSaveFailed(error.localizedDescription)
        }

        // Add to clusters list and save
        clusters.append(cluster)
        saveClusters()
        clustersDidChange.send()

        Self.logger.info("Successfully imported cluster: \(cluster.label) (\(cluster.contextName))")
        return cluster
    }

    /// Check if a context is already imported
    /// - Parameters:
    ///   - serverURL: The cluster server URL
    ///   - contextName: The context name
    /// - Returns: True if the context is already imported
    func isContextImported(serverURL: String, contextName: String) -> Bool {
        clusters.contains { $0.serverURL == serverURL && $0.contextName == contextName }
    }
}

// MARK: - Supporting Types

/// Detailed information about a single context in a kubeconfig
struct ParsedContextInfo: Identifiable, Hashable {
    var id: String { contextName }
    let contextName: String
    let clusterName: String
    let serverURL: String
    let userName: String
    let namespace: String?
    let isCurrentContext: Bool
}

struct ParsedKubeconfigInfo {
    let currentContext: String
    let clusterName: String
    let serverURL: String
    let userName: String
    let namespace: String?
    let availableContexts: [String]
    /// Full details for all valid contexts in the kubeconfig
    let contexts: [ParsedContextInfo]

    /// Whether this kubeconfig has multiple contexts
    var hasMultipleContexts: Bool {
        contexts.count > 1
    }
}

enum KubernetesImportError: LocalizedError {
    case invalidKubeconfig(String)
    case noCurrentContext
    case contextNotFound(String)
    case clusterNotFound(String)
    case duplicateCluster(String)
    case duplicateContext(serverURL: String, contextName: String)
    case dataConversionFailed
    case keychainSaveFailed(String)
    case clientCreationFailed
    case partialImportFailure(succeeded: [String], failed: [(context: String, error: String)])

    var errorDescription: String? {
        switch self {
        case .invalidKubeconfig(let details):
            return String(localized: "Invalid kubeconfig: \(details)", comment: "Kubernetes cluster import error")
        case .noCurrentContext:
            return String(localized: "No current-context specified in kubeconfig", comment: "Kubernetes cluster import error")
        case .contextNotFound(let name):
            return String(localized: "Context '\(name)' not found in kubeconfig", comment: "Kubernetes cluster import error")
        case .clusterNotFound(let name):
            return String(localized: "Cluster '\(name)' not found in kubeconfig", comment: "Kubernetes cluster import error")
        case .duplicateCluster(let server):
            return String(localized: "A cluster with server '\(server)' already exists", comment: "Kubernetes cluster import error")
        case .duplicateContext(let serverURL, let contextName):
            return String(localized: "Context '\(contextName)' for server '\(serverURL)' already exists", comment: "Kubernetes cluster import error")
        case .dataConversionFailed:
            return String(localized: "Failed to convert kubeconfig data", comment: "Kubernetes cluster import error")
        case .keychainSaveFailed(let details):
            return String(localized: "Failed to save to keychain: \(details)", comment: "Kubernetes cluster import error")
        case .clientCreationFailed:
            return String(localized: "Failed to create Kubernetes client", comment: "Kubernetes cluster import error")
        case .partialImportFailure(let succeeded, let failed):
            let failedContexts = failed.map { $0.context }.joined(separator: ", ")
            if succeeded.isEmpty {
                return String(localized: "Failed to import all contexts: \(failedContexts)", comment: "Kubernetes cluster import error")
            } else {
                return String(localized: "Imported \(succeeded.count) context(s), but failed to import: \(failedContexts)", comment: "Kubernetes cluster import error")
            }
        }
    }
}
