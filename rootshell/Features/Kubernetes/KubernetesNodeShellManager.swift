//
//  KubernetesNodeShellManager.swift
//  rootshell
//
//  Manages Kubernetes node shell sessions and orphan pod cleanup
//

import Foundation
import UIKit
import Combine
import os.log
import SwiftkubeClient
import SwiftkubeModel

/// Manages node shell pod lifecycle and orphan cleanup
@MainActor
class KubernetesNodeShellManager: ObservableObject {
    static let shared = KubernetesNodeShellManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesNodeShellManager")

    /// Active sessions tracked by this manager
    @Published private(set) var activeSessions: [UUID: KubernetesNodeSession] = [:]

    /// Orphan pods discovered during cleanup scan
    @Published private(set) var orphanedPods: [OrphanedPodInfo] = []

    /// Whether a cleanup scan is in progress
    @Published private(set) var isScanning: Bool = false

    /// Whether a cleanup operation is in progress
    @Published private(set) var isCleaningUp: Bool = false

    private init() {}

    // MARK: - Session Registration

    /// Register a new session for tracking
    func registerSession(_ session: KubernetesNodeSession) {
        activeSessions[session.config.sessionId] = session
        Self.logger.info("Registered session: \(session.config.sessionId)")
    }

    /// Unregister a session when it ends
    func unregisterSession(_ sessionId: UUID) {
        activeSessions.removeValue(forKey: sessionId)
        Self.logger.info("Unregistered session: \(sessionId)")
    }

    /// Check if a session is active
    func isSessionActive(_ sessionId: UUID) -> Bool {
        return activeSessions[sessionId] != nil
    }

    // MARK: - Orphan Detection

    /// Clear the orphaned pods list
    func clearOrphanedPods() {
        orphanedPods.removeAll()
    }

    /// Scan for orphaned pods in a cluster
    /// - Parameters:
    ///   - cluster: The cluster to scan
    ///   - olderThan: Only consider pods older than this interval (default: 1 hour)
    ///   - appendResults: If true, appends to existing orphanedPods; if false, replaces (default: false for backward compatibility)
    /// - Returns: Array of orphaned pod info
    func scanForOrphanedPods(in cluster: KubernetesCluster, olderThan: TimeInterval = 3600, appendResults: Bool = false) async -> [OrphanedPodInfo] {
        Self.logger.info("Scanning for orphaned pods in cluster: \(cluster.label)")
        isScanning = true

        defer {
            isScanning = false
        }

        do {
            let kubeconfigYAML = try KubernetesClusterManager.shared.getKubeconfig(for: cluster)
            let kubeConfig = try KubeConfig.from(config: kubeconfigYAML)

            guard let client = KubernetesClient(kubeConfig: kubeConfig, contextName: cluster.contextName) else {
                Self.logger.error("Failed to create Kubernetes client")
                return []
            }

            defer {
                Task {
                    try? await client.shutdown()
                }
            }

            // List pods with our label selector
            let pods = try await client.pods.list(
                in: NamespaceSelector.system,
                options: [
                    .labelSelector(.eq([
                        KubernetesNodeShellConstants.Labels.appManagedBy: KubernetesNodeShellConstants.Labels.appManagedByValue,
                        KubernetesNodeShellConstants.Labels.appName: KubernetesNodeShellConstants.Labels.appNameValue
                    ]))
                ]
            )

            let now = Date()
            var orphans: [OrphanedPodInfo] = []

            for pod in pods.items {
                guard let metadata = pod.metadata,
                      let name = metadata.name,
                      let labels = metadata.labels,
                      let annotations = metadata.annotations else {
                    continue
                }

                // Parse creation time
                let createdAt: Date
                if let createdAtStr = annotations[KubernetesNodeShellConstants.Annotations.createdAt],
                   let parsedDate = ISO8601DateFormatter().date(from: createdAtStr) {
                    createdAt = parsedDate
                } else if let k8sCreationTimestamp = metadata.creationTimestamp {
                    createdAt = k8sCreationTimestamp
                } else {
                    continue
                }

                let age = now.timeIntervalSince(createdAt)

                // Check if older than threshold
                guard age > olderThan else { continue }

                // Extract info from labels/annotations
                let sessionIdStr = labels[KubernetesNodeShellConstants.Labels.sessionId] ?? "unknown"
                let nodeName = labels[KubernetesNodeShellConstants.Labels.nodeName] ?? "unknown"
                let deviceId = annotations[KubernetesNodeShellConstants.Annotations.deviceId] ?? "unknown"
                let clusterIdStr = annotations[KubernetesNodeShellConstants.Annotations.clusterId] ?? ""

                // Check if this session is currently active
                if let sessionId = UUID(uuidString: sessionIdStr), isSessionActive(sessionId) {
                    // Session is still active, not an orphan
                    Self.logger.debug("Pod \(name) belongs to active session, skipping")
                    continue
                }

                // This is an orphan
                let orphanInfo = OrphanedPodInfo(
                    id: name,
                    nodeName: nodeName,
                    clusterId: UUID(uuidString: clusterIdStr) ?? cluster.id,
                    createdAt: createdAt,
                    sessionId: sessionIdStr,
                    deviceId: deviceId
                )

                orphans.append(orphanInfo)
                Self.logger.info("Found orphaned pod: \(name) (age: \(orphanInfo.ageDescription))")
            }

            if appendResults {
                self.orphanedPods.append(contentsOf: orphans)
            } else {
                self.orphanedPods = orphans
            }
            Self.logger.info("Scan complete: found \(orphans.count) orphaned pods in \(cluster.label) (total: \(self.orphanedPods.count))")
            return orphans

        } catch {
            Self.logger.error("Failed to scan for orphaned pods: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Orphan Cleanup

    /// Delete orphaned pods in a cluster
    /// - Parameters:
    ///   - cluster: The cluster to clean
    ///   - pods: Specific pods to delete (if nil, deletes all orphans)
    /// - Returns: Number of pods deleted
    @discardableResult
    func cleanupOrphanedPods(in cluster: KubernetesCluster, pods: [OrphanedPodInfo]? = nil) async -> Int {
        let podsToDelete = pods ?? orphanedPods
        guard !podsToDelete.isEmpty else {
            Self.logger.info("No orphaned pods to clean up")
            return 0
        }

        Self.logger.info("Cleaning up \(podsToDelete.count) orphaned pods in cluster: \(cluster.label)")
        isCleaningUp = true

        defer {
            isCleaningUp = false
        }

        do {
            let kubeconfigYAML = try KubernetesClusterManager.shared.getKubeconfig(for: cluster)
            let kubeConfig = try KubeConfig.from(config: kubeconfigYAML)

            guard let client = KubernetesClient(kubeConfig: kubeConfig, contextName: cluster.contextName) else {
                Self.logger.error("Failed to create Kubernetes client")
                return 0
            }

            defer {
                Task {
                    try? await client.shutdown()
                }
            }

            var deletedCount = 0

            for pod in podsToDelete {
                do {
                    try await client.pods.delete(inNamespace: NamespaceSelector.system, name: pod.id)
                    deletedCount += 1
                    Self.logger.info("Deleted orphaned pod: \(pod.id)")

                    // Remove from our list
                    orphanedPods.removeAll { $0.id == pod.id }

                } catch {
                    Self.logger.warning("Failed to delete pod \(pod.id): \(error.localizedDescription)")
                }
            }

            Self.logger.info("Cleanup complete: deleted \(deletedCount) pods")
            return deletedCount

        } catch {
            Self.logger.error("Failed to cleanup orphaned pods: \(error.localizedDescription)")
            return 0
        }
    }

    /// Clean up all pods from this device in a cluster
    /// - Parameter cluster: The cluster to clean
    /// - Returns: Number of pods deleted
    @discardableResult
    func cleanupPodsFromThisDevice(in cluster: KubernetesCluster) async -> Int {
        // Use the same source of truth that annotates created pods
        // (`KubernetesNodeShellConfig.cachedDeviceID`), so cleanup matches the
        // ids actually written onto the pods.
        let deviceId = KubernetesNodeShellConfig.cachedDeviceID()
        #if canImport(UIKit)
        // Pods created before the persisted-id migration were annotated with
        // `identifierForVendor`; match those too so they aren't stranded.
        let legacyDeviceId = UIDevice.current.identifierForVendor?.uuidString
        #else
        let legacyDeviceId: String? = nil
        #endif

        Self.logger.info("Cleaning up pods from device \(deviceId) in cluster: \(cluster.label)")

        // First scan for all pods (regardless of age)
        let allPods = await scanForOrphanedPods(in: cluster, olderThan: 0)

        // Filter to this device (current persisted id, or the legacy vendor id)
        let devicePods = allPods.filter { $0.deviceId == deviceId || $0.deviceId == legacyDeviceId }

        if devicePods.isEmpty {
            Self.logger.info("No pods from this device found")
            return 0
        }

        return await cleanupOrphanedPods(in: cluster, pods: devicePods)
    }

    // MARK: - Cleanup on App Events

    /// Clean up all sessions on app termination
    func cleanupOnTermination() {
        Self.logger.info("App terminating, cleaning up \(self.activeSessions.count) active sessions")

        for (_, session) in activeSessions {
            session.stop()
        }

        activeSessions.removeAll()
    }
}

// MARK: - Cluster Extension

extension KubernetesClusterManager {
    /// Get the count of orphaned debug pods in a cluster
    func getOrphanedPodCount(for cluster: KubernetesCluster) async -> Int {
        let orphans = await KubernetesNodeShellManager.shared.scanForOrphanedPods(in: cluster)
        return orphans.count
    }
}
