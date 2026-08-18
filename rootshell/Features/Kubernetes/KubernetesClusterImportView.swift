//
//  KubernetesClusterImportView.swift
//  rootshell
//
//  View for importing kubeconfig files via paste or file picker
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

struct KubernetesClusterImportView: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesClusterImport")

    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var clusterManager = KubernetesClusterManager.shared

    @State private var importMethod: ImportMethod = .paste
    @State private var clusterLabel = ""
    @State private var kubeconfigText = ""
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isImporting = false
    @State private var parsedInfo: ParsedKubeconfigInfo?
    @State private var selectedContexts: Set<String> = []

    enum ImportMethod: String, CaseIterable {
        case paste = "Paste"
        case file = "File"

        var displayName: String {
            switch self {
            case .paste: return String(localized: "Paste", comment: "Kubeconfig import method: paste config text")
            case .file: return String(localized: "File", comment: "Kubeconfig import method: import from file")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // Import method picker
                Section {
                    Picker("Import Method", selection: $importMethod) {
                        ForEach(ImportMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                }

                // Cluster label input
                Section {
                    TextField("Cluster Label", text: $clusterLabel)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Label")
                } footer: {
                    if let info = parsedInfo {
                        Text("Auto-filled from context: \(info.currentContext)")
                    } else {
                        Text("A friendly name for this cluster (e.g., 'Production', 'Staging')")
                    }
                }

                // Import method-specific UI
                if importMethod == .paste {
                    Section {
                        TextEditor(text: $kubeconfigText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: kubeconfigText) { _, newValue in
                                parseKubeconfigPreview(newValue)
                            }
                            .themedRow()
                    } header: {
                        Text("Kubeconfig")
                    } footer: {
                        Text("Paste the contents of your kubeconfig file (typically ~/.kube/config)")
                    }
                } else {
                    Section {
                        Button(action: { showingFilePicker = true }) {
                            HStack {
                                Image(systemName: "doc.fill")
                                Text("Select Kubeconfig File")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()

                        if !kubeconfigText.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("File loaded")
                                    .foregroundColor(.secondary)
                            }
                            .themedRow()
                        }
                    } header: {
                        Text("Kubeconfig File")
                    } footer: {
                        Text("Select a kubeconfig file (.yaml, .yml, or no extension)")
                    }
                }

                // Parsed info preview
                if let info = parsedInfo {
                    if info.hasMultipleContexts {
                        // Multi-context selection UI
                        Section {
                            HStack {
                                Button("Select All") {
                                    selectAllContexts()
                                }
                                .buttonStyle(.borderless)
                                .disabled(allSelectableContextsSelected)

                                Spacer()

                                Button("Deselect All") {
                                    selectedContexts.removeAll()
                                }
                                .buttonStyle(.borderless)
                                .disabled(selectedContexts.isEmpty)
                            }
                            .themedRow()

                            ForEach(info.contexts) { contextInfo in
                                ContextSelectionRow(
                                    contextInfo: contextInfo,
                                    isSelected: selectedContexts.contains(contextInfo.contextName),
                                    isImported: clusterManager.isContextImported(
                                        serverURL: contextInfo.serverURL,
                                        contextName: contextInfo.contextName
                                    )
                                ) {
                                    toggleContextSelection(contextInfo.contextName)
                                }
                                .themedRow()
                            }
                        } header: {
                            Text("Select Contexts to Import")
                        } footer: {
                            Text("\(selectedContexts.count) of \(selectableContextCount) context(s) selected")
                        }
                    } else {
                        // Single context display (original behavior)
                        Section("Detected Configuration") {
                            LabeledContent("Context", value: info.currentContext)
                                .themedRow()
                            LabeledContent("Cluster", value: info.clusterName)
                                .themedRow()
                            LabeledContent("Server", value: info.serverURL)
                                .themedRow()
                            LabeledContent("User", value: info.userName)
                                .themedRow()
                            if let namespace = info.namespace {
                                LabeledContent("Namespace", value: namespace)
                                    .themedRow()
                            }
                        }
                    }
                }

                // Import button
                Section {
                    Button(action: importCluster) {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(importButtonText)
                            Spacer()
                        }
                    }
                    .disabled(!canImport || isImporting)
                    .themedRow()
                }

                // Info section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Security Note", systemImage: "lock.shield")
                            .font(.caption.bold())

                        Text("Your kubeconfig will be stored securely in the system Keychain. It will not be synced to iCloud or other devices.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
            }
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Import Kubeconfig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [
                    .yaml,
                    UTType(filenameExtension: "yml") ?? .yaml,
                    .item
                ],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .alert("Import Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var canImport: Bool {
        guard !kubeconfigText.trimmingCharacters(in: .whitespaces).isEmpty,
              let info = parsedInfo else {
            return false
        }

        // For multi-context, require at least one selection
        if info.hasMultipleContexts {
            return !selectedContexts.isEmpty
        }

        return true
    }

    private var importButtonText: String {
        if isImporting {
            return String(localized: "Importing...", comment: "Kubernetes cluster import button")
        }

        guard let info = parsedInfo else {
            return String(localized: "Import Cluster", comment: "Kubernetes cluster import button")
        }

        if info.hasMultipleContexts && selectedContexts.count > 1 {
            return String(localized: "Import \(selectedContexts.count) Clusters", comment: "Kubernetes cluster import button")
        }

        return String(localized: "Import Cluster", comment: "Kubernetes cluster import button")
    }

    /// Count of contexts that can be selected (not already imported)
    private var selectableContextCount: Int {
        guard let info = parsedInfo else { return 0 }
        return info.contexts.filter { contextInfo in
            !clusterManager.isContextImported(
                serverURL: contextInfo.serverURL,
                contextName: contextInfo.contextName
            )
        }.count
    }

    /// Whether all selectable contexts are currently selected
    private var allSelectableContextsSelected: Bool {
        guard let info = parsedInfo else { return false }
        let selectableContexts = info.contexts.filter { contextInfo in
            !clusterManager.isContextImported(
                serverURL: contextInfo.serverURL,
                contextName: contextInfo.contextName
            )
        }
        return !selectableContexts.isEmpty &&
               selectableContexts.allSatisfy { selectedContexts.contains($0.contextName) }
    }

    // MARK: - Actions

    private func parseKubeconfigPreview(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            parsedInfo = nil
            selectedContexts.removeAll()
            return
        }

        do {
            let info = try clusterManager.parseKubeconfig(trimmed)
            parsedInfo = info

            // Clear previous selections when kubeconfig changes
            selectedContexts.removeAll()

            // Auto-select current context for multi-context files (if not already imported)
            if info.hasMultipleContexts {
                if !clusterManager.isContextImported(
                    serverURL: info.serverURL,
                    contextName: info.currentContext
                ) {
                    selectedContexts.insert(info.currentContext)
                }
            }

            // Auto-fill label if empty (for single context or as prefix for multi)
            if clusterLabel.isEmpty {
                clusterLabel = info.currentContext
            }
        } catch {
            parsedInfo = nil
            selectedContexts.removeAll()
        }
    }

    private func selectAllContexts() {
        guard let info = parsedInfo else { return }
        for contextInfo in info.contexts {
            // Only select contexts that aren't already imported
            if !clusterManager.isContextImported(
                serverURL: contextInfo.serverURL,
                contextName: contextInfo.contextName
            ) {
                selectedContexts.insert(contextInfo.contextName)
            }
        }
    }

    private func toggleContextSelection(_ contextName: String) {
        if selectedContexts.contains(contextName) {
            selectedContexts.remove(contextName)
        } else {
            selectedContexts.insert(contextName)
        }
    }

    private func importCluster() {
        isImporting = true

        Task {
            do {
                let trimmedKubeconfig = kubeconfigText.trimmingCharacters(in: .whitespaces)
                let labelToUse = clusterLabel.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : clusterLabel.trimmingCharacters(in: .whitespaces)

                // Check if multi-context import
                if let info = parsedInfo, info.hasMultipleContexts, !selectedContexts.isEmpty {
                    // Multi-context import
                    let contextNames = Array(selectedContexts)
                    let clusters = try clusterManager.importKubeconfig(
                        trimmedKubeconfig,
                        contextNames: contextNames,
                        labelPrefix: labelToUse
                    )

                    await MainActor.run {
                        isImporting = false
                        Self.logger.info("Successfully imported \(clusters.count) cluster(s)")
                        dismiss()
                    }
                } else {
                    // Single context import (original behavior)
                    let cluster = try clusterManager.importKubeconfig(trimmedKubeconfig, label: labelToUse)

                    await MainActor.run {
                        isImporting = false
                        Self.logger.info("Successfully imported cluster: \(cluster.label)")
                        dismiss()
                    }
                }
            } catch let error as KubernetesImportError {
                // Handle partial import success
                if case .partialImportFailure(let succeeded, _) = error, !succeeded.isEmpty {
                    // Some imports succeeded - show warning but still dismiss
                    await MainActor.run {
                        isImporting = false
                        Self.logger.warning("Partial import: \(error.localizedDescription)")
                        errorMessage = error.localizedDescription
                        showingError = true
                        // Note: We'll dismiss after user acknowledges the partial success
                    }
                } else {
                    await MainActor.run {
                        isImporting = false
                        errorMessage = error.localizedDescription
                        showingError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Unable to access the file"
                showingError = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                kubeconfigText = content

                // Auto-fill label from filename if empty
                if clusterLabel.isEmpty {
                    let filename = url.deletingPathExtension().lastPathComponent
                    if filename != "config" {
                        clusterLabel = filename
                    }
                }

                parseKubeconfigPreview(content)
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
                showingError = true
            }

        case .failure(let error):
            errorMessage = "File selection failed: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - Context Selection Row

private struct ContextSelectionRow: View {
    let contextInfo: ParsedContextInfo
    let isSelected: Bool
    let isImported: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: {
            if !isImported {
                onToggle()
            }
        }) {
            HStack(spacing: 12) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isImported ? .secondary : (isSelected ? .accentColor : .secondary))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(contextInfo.contextName)
                            .font(.body)
                            .foregroundColor(isImported ? .secondary : .primary)

                        if contextInfo.isCurrentContext {
                            Text("current")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }

                        if isImported {
                            Text("imported")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(contextInfo.clusterName) • \(contextInfo.userName)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(contextInfo.serverURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let namespace = contextInfo.namespace {
                        Text("Namespace: \(namespace)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(isImported)
        .opacity(isImported ? 0.6 : 1.0)
    }
}

#Preview {
    KubernetesClusterImportView()
}
