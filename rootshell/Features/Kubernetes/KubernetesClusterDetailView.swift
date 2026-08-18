//
//  KubernetesClusterDetailView.swift
//  rootshell
//
//  Detail view for a Kubernetes cluster showing nodes and health
//

import SwiftUI

struct KubernetesClusterDetailView: View {
    let cluster: KubernetesCluster

    @StateObject private var clusterManager = KubernetesClusterManager.shared
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var nodes: [ClusterNodeInfo] = []
    @State private var isLoadingNodes = false
    @State private var loadError: String?
    @State private var isEditingLabel = false
    @State private var editedLabel = ""
    @State private var showingDeleteAlert = false
    @Environment(\.dismiss) var dismiss

    private var healthStatus: ClusterHealthStatus {
        clusterManager.clusterHealthStatus[cluster.id] ?? .unknown
    }

    var body: some View {
        List {
            // Cluster Info Section
            Section("Cluster Information") {
                LabeledContent("Label") {
                    if isEditingLabel {
                        HStack {
                            TextField("Label", text: $editedLabel)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()

                            Button("Save") {
                                clusterManager.updateClusterLabel(cluster, newLabel: editedLabel)
                                isEditingLabel = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel") {
                                editedLabel = cluster.label
                                isEditingLabel = false
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Text(cluster.label)
                            Spacer()
                            Button(action: {
                                editedLabel = cluster.label
                                isEditingLabel = true
                            }) {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .themedRow()

                LabeledContent("Context", value: cluster.contextName)
                    .themedRow()
                LabeledContent("Cluster Name", value: cluster.clusterName)
                    .themedRow()
                LabeledContent("Server", value: cluster.serverURL)
                    .themedRow()
                LabeledContent("User", value: cluster.userName)
                    .themedRow()

                if let namespace = cluster.namespace {
                    LabeledContent("Default Namespace", value: namespace)
                        .themedRow()
                }

                LabeledContent("Imported") {
                    Text(cluster.importedDate, style: .date)
                }
                .themedRow()

                if let lastAccessed = cluster.lastAccessedDate {
                    LabeledContent("Last Accessed") {
                        Text(lastAccessed, style: .relative)
                    }
                    .themedRow()
                }
            }

            // Health Status Section
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    ClusterHealthBadge(status: healthStatus)
                }
                .themedRow()

                Button(action: refreshHealth) {
                    HStack {
                        Label("Refresh Health", systemImage: "arrow.clockwise")
                        Spacer()
                        if case .checking = healthStatus {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                }
                .disabled(healthStatus == .checking)
                .themedRow()
            } header: {
                Text("Health Status")
            } footer: {
                Text(healthStatus.displayText)
            }

            // Nodes Section
            Section {
                if isLoadingNodes {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding()
                        Spacer()
                    }
                    .themedRow()
                } else if let error = loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.orange)

                        Text("Failed to load nodes")
                            .font(.headline)

                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Retry") {
                            loadNodes()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .themedRow()
                } else if nodes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.title)
                            .foregroundColor(.secondary)

                        Text("No nodes found")
                            .font(.headline)

                        Button("Load Nodes") {
                            loadNodes()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .themedRow()
                } else {
                    ForEach(nodes) { node in
                        NodeRowView(node: node)
                            .themedRow()
                    }
                }
            } header: {
                HStack {
                    Text("Nodes")
                    Spacer()
                    if !nodes.isEmpty {
                        Text("\(nodes.count)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete Cluster", systemImage: "trash")
                }
                .themedRow()
            } footer: {
                Text("Deleting this cluster will remove the kubeconfig from your device.")
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle(cluster.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshHealth()
            loadNodes()
        }
        .alert("Delete Cluster", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                clusterManager.deleteCluster(cluster)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to delete '\(cluster.label)'? This action cannot be undone.")
        }
    }

    private func refreshHealth() {
        Task {
            await clusterManager.checkClusterHealth(cluster)
        }
    }

    private func loadNodes() {
        isLoadingNodes = true
        loadError = nil

        Task {
            do {
                nodes = try await clusterManager.getClusterNodes(cluster)
                isLoadingNodes = false
            } catch {
                loadError = error.localizedDescription
                isLoadingNodes = false
            }
        }
    }
}

// MARK: - Node Row View

struct NodeRowView: View {
    let node: ClusterNodeInfo
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Node header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Image(systemName: node.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(node.isReady ? .green : .orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name)
                            .font(.headline)
                            .foregroundColor(.primary)

                        if let version = node.kubeletVersion {
                            Text("Kubelet \(version)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let osImage = node.osImage {
                        LabeledContent("OS", value: osImage)
                            .font(.caption)
                    }

                    if let arch = node.architecture {
                        LabeledContent("Architecture", value: arch)
                            .font(.caption)
                    }

                    // Conditions
                    if !node.conditions.isEmpty {
                        Divider()

                        Text("Conditions")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)

                        ForEach(node.conditions, id: \.type) { condition in
                            HStack(alignment: .top) {
                                Image(systemName: conditionIcon(for: condition))
                                    .foregroundColor(conditionColor(for: condition))
                                    .font(.caption)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(condition.type)
                                        .font(.caption.bold())

                                    Text("Status: \(condition.status)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    if let reason = condition.reason, !reason.isEmpty {
                                        Text("Reason: \(reason)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    if let message = condition.message, !message.isEmpty {
                                        Text(message)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    private func conditionIcon(for condition: ClusterNodeInfo.NodeCondition) -> String {
        if condition.type == "Ready" {
            return condition.status == "True" ? "checkmark.circle.fill" : "xmark.circle.fill"
        }

        // For other conditions, "False" is usually good (e.g., MemoryPressure: False)
        if condition.status == "False" {
            return "checkmark.circle"
        } else if condition.status == "True" {
            return "exclamationmark.circle"
        }

        return "questionmark.circle"
    }

    private func conditionColor(for condition: ClusterNodeInfo.NodeCondition) -> Color {
        if condition.type == "Ready" {
            return condition.status == "True" ? .green : .red
        }

        // For other conditions, "False" is usually good
        if condition.status == "False" {
            return .green
        } else if condition.status == "True" {
            return .orange
        }

        return .secondary
    }
}

#Preview {
    NavigationView {
        KubernetesClusterDetailView(
            cluster: KubernetesCluster(
                label: "Production",
                contextName: "prod-context",
                clusterName: "prod-cluster",
                serverURL: "https://k8s.example.com:6443",
                userName: "admin",
                namespace: "default"
            )
        )
    }
}
