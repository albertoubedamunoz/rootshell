//
//  KubernetesSettingsView.swift
//  rootshell
//
//  Settings view for managing Kubernetes clusters
//

import SwiftUI

struct KubernetesSettingsView: View {
    @StateObject private var clusterManager = KubernetesClusterManager.shared
    @StateObject private var nodeShellManager = KubernetesNodeShellManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var showingImportSheet = false
    @State private var showingDeleteAlert = false
    @State private var clusterToDelete: KubernetesCluster?
    @State private var isRefreshing = false
    @State private var showingCleanupAlert = false
    @State private var cleanupResult: String?

    var body: some View {
        List {
            if clusterManager.clusters.isEmpty {
                Section {
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("No Clusters Imported")
                            .font(.headline)

                        Text("Import a kubeconfig file to connect to your Kubernetes clusters.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button(action: { showingImportSheet = true }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Import Kubeconfig")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .themedRow()
                }
            } else {
                Section {
                    ForEach(clusterManager.clusters) { cluster in
                        NavigationLink {
                            KubernetesClusterDetailView(cluster: cluster)
                        } label: {
                            ClusterRowView(
                                cluster: cluster,
                                healthStatus: clusterManager.clusterHealthStatus[cluster.id] ?? .unknown
                            )
                        }
                        .themedRow()
                    }
                    .onDelete(perform: deleteCluster)
                } header: {
                    HStack {
                        Text("Clusters")
                        Spacer()
                        if isRefreshing {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                } footer: {
                    Text("\(clusterManager.clusters.count) cluster\(clusterManager.clusters.count == 1 ? "" : "s") imported")
                }

                Section {
                    Button(action: { showingImportSheet = true }) {
                        HStack {
                            Image(systemName: "plus.circle")
                            Text("Import Kubeconfig")
                        }
                    }
                    .themedRow()
                }
            }

            // Node Shell Cleanup Section
            if !clusterManager.clusters.isEmpty {
                Section {
                    // Active sessions info
                    if !nodeShellManager.activeSessions.isEmpty {
                        HStack {
                            Label("Active Sessions", systemImage: "terminal")
                            Spacer()
                            Text("\(nodeShellManager.activeSessions.count)")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }

                    // Orphan pod info
                    HStack {
                        Label("Orphaned Debug Pods", systemImage: "exclamationmark.triangle")
                        Spacer()
                        if nodeShellManager.isScanning {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Text("\(nodeShellManager.orphanedPods.count)")
                                .foregroundColor(nodeShellManager.orphanedPods.isEmpty ? .secondary : .orange)
                        }
                    }
                    .themedRow()

                    // Scan button
                    Button(action: scanForOrphans) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Scan for Orphaned Pods")
                        }
                    }
                    .disabled(nodeShellManager.isScanning || clusterManager.clusters.isEmpty)
                    .themedRow()

                    // Cleanup button
                    if !nodeShellManager.orphanedPods.isEmpty {
                        Button(action: { showingCleanupAlert = true }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clean Up \(nodeShellManager.orphanedPods.count) Orphaned Pod\(nodeShellManager.orphanedPods.count == 1 ? "" : "s")")
                            }
                        }
                        .foregroundColor(.red)
                        .disabled(nodeShellManager.isCleaningUp)
                        .themedRow()
                    }
                } header: {
                    Text("Node Shell Management")
                } footer: {
                    Text("Debug pods older than 1 hour without an active session are considered orphaned. These may have been left behind if the app crashed.")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("About Kubernetes Integration", systemImage: "info.circle")
                        .font(.caption.bold())

                    Text("Kubeconfig files are stored securely in the system Keychain. Cluster health is checked on-demand when viewing cluster details.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }
        .themedList()
        .refreshable {
            await refreshAllClusters()
        }
        .navigationTitle("Kubernetes")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingImportSheet) {
            KubernetesClusterImportView()
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Delete Cluster", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {
                clusterToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let cluster = clusterToDelete {
                    clusterManager.deleteCluster(cluster)
                }
                clusterToDelete = nil
            }
        } message: {
            if let cluster = clusterToDelete {
                Text("Are you sure you want to delete '\(cluster.label)'? The kubeconfig will be removed from your device.")
            }
        }
        .alert("Clean Up Orphaned Pods", isPresented: $showingCleanupAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Up", role: .destructive) {
                cleanupOrphanedPods()
            }
        } message: {
            Text("This will delete \(nodeShellManager.orphanedPods.count) orphaned debug pod\(nodeShellManager.orphanedPods.count == 1 ? "" : "s") from your clusters. This cannot be undone.")
        }
        .alert("Cleanup Complete", isPresented: .constant(cleanupResult != nil)) {
            Button("OK") {
                cleanupResult = nil
            }
        } message: {
            if let result = cleanupResult {
                Text(result)
            }
        }
        .task {
            await refreshAllClusters()
        }
    }

    private func deleteCluster(at offsets: IndexSet) {
        guard let index = offsets.first else { return }
        clusterToDelete = clusterManager.clusters[index]
        showingDeleteAlert = true
    }

    private func refreshAllClusters() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await clusterManager.checkAllClustersHealth()
    }

    private func scanForOrphans() {
        Task {
            // Clear existing orphans before scanning all clusters
            nodeShellManager.clearOrphanedPods()

            // Scan all clusters for orphaned pods
            for cluster in clusterManager.clusters {
                _ = await nodeShellManager.scanForOrphanedPods(in: cluster, appendResults: true)
            }
        }
    }

    private func cleanupOrphanedPods() {
        Task {
            var totalDeleted = 0

            // Group orphaned pods by cluster and clean up
            let orphansByCluster = Dictionary(grouping: nodeShellManager.orphanedPods) { $0.clusterId }

            for (clusterId, pods) in orphansByCluster {
                // First try to find by clusterId from annotation
                // If that fails, try all clusters since the pod was found during a scan of one of them
                if let cluster = clusterManager.clusters.first(where: { $0.id == clusterId }) {
                    let deleted = await nodeShellManager.cleanupOrphanedPods(in: cluster, pods: pods)
                    totalDeleted += deleted
                } else {
                    // The clusterId annotation doesn't match any current cluster.
                    // This can happen if the cluster was deleted and re-imported.
                    // Try each cluster to find one that can delete these pods.
                    for cluster in clusterManager.clusters {
                        let deleted = await nodeShellManager.cleanupOrphanedPods(in: cluster, pods: pods)
                        if deleted > 0 {
                            totalDeleted += deleted
                            break
                        }
                    }
                }
            }

            cleanupResult = "Successfully deleted \(totalDeleted) orphaned pod\(totalDeleted == 1 ? "" : "s")."
        }
    }
}

// MARK: - Cluster Row View

struct ClusterRowView: View {
    let cluster: KubernetesCluster
    let healthStatus: ClusterHealthStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(cluster.label)
                    .font(.headline)

                Spacer()

                ClusterHealthBadge(status: healthStatus)
            }

            HStack {
                Text(cluster.contextName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if cluster.contextName != cluster.clusterName {
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(cluster.clusterName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(cluster.serverURL)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Health Badge

struct ClusterHealthBadge: View {
    let status: ClusterHealthStatus

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
                .font(.caption)

            Text(statusText)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusBackgroundColor.opacity(0.2))
        .foregroundColor(statusForegroundColor)
        .cornerRadius(8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .unknown:
            Image(systemName: "questionmark.circle")
        case .checking:
            ProgressView()
                .scaleEffect(0.6)
        case .healthy:
            Image(systemName: "checkmark.circle.fill")
        case .unhealthy:
            Image(systemName: "exclamationmark.triangle.fill")
        case .unreachable:
            Image(systemName: "xmark.circle.fill")
        }
    }

    private var statusText: String {
        switch status {
        case .unknown:
            return String(localized: "Unknown", comment: "Kubernetes cluster health status")
        case .checking:
            return String(localized: "Checking", comment: "Kubernetes cluster health status")
        case .healthy(let nodeCount, _):
            return String(localized: "\(nodeCount) Ready", comment: "Kubernetes cluster health status")
        case .unhealthy(_, let readyCount, _):
            return String(localized: "\(readyCount) Ready", comment: "Kubernetes cluster health status")
        case .unreachable:
            return String(localized: "Offline", comment: "Kubernetes cluster health status")
        }
    }

    private var statusBackgroundColor: Color {
        switch status {
        case .unknown, .checking:
            return .gray
        case .healthy:
            return .green
        case .unhealthy:
            return .orange
        case .unreachable:
            return .red
        }
    }

    private var statusForegroundColor: Color {
        switch status {
        case .unknown, .checking:
            return .secondary
        case .healthy:
            return .green
        case .unhealthy:
            return .orange
        case .unreachable:
            return .red
        }
    }
}

#Preview {
    NavigationView {
        KubernetesSettingsView()
    }
}
