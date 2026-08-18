//
//  MMDBDatabaseSettingsView.swift
//  rootshell
//

import SwiftUI
import UniformTypeIdentifiers

struct MMDBDatabaseSettingsView: View {
    private var mmdbManager = MMDBDatabaseManager.shared
    @Environment(\.editMode) private var editMode

    @State private var showingMMDBImporter = false
    @State private var showingMMDBError = false
    @State private var mmdbErrorMessage = ""
    @State private var showingClearMMDBAlert = false

    var body: some View {
        List {
            actionsSection
            errorSection
            prioritySection
        }
        .themedList()
        .navigationTitle("MMDB Databases")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
                    .disabled(mmdbManager.databases.isEmpty)
            }
        }
        .fileImporter(
            isPresented: $showingMMDBImporter,
            allowedContentTypes: [UTType(filenameExtension: "mmdb") ?? .data, .data],
            allowsMultipleSelection: true
        ) { result in
            handleMMDBImport(result: result)
        }
        .alert("MMDB Import", isPresented: $showingMMDBError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mmdbErrorMessage)
        }
        .alert("Clear Imported Databases", isPresented: $showingClearMMDBAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                mmdbManager.clearAll()
            }
        } message: {
            Text("This removes all imported MMDB files from the app. You can import fresh copies at any time.")
        }
    }

    private var statusText: String {
        if mmdbManager.isLoading {
            return "Loading"
        }
        if mmdbManager.loadedDatabaseCount == 0 {
            return "Not Configured"
        }
        return String(localized: "\(mmdbManager.loadedDatabaseCount) of \(mmdbManager.databases.count) loaded", comment: "GeoIP database status")
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            HStack {
                Text("Status")
                    .foregroundStyle(.secondary)
                Spacer()
                if mmdbManager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            Button {
                showingMMDBImporter = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                    Text(mmdbManager.hasDatabases ? "Import Additional MMDB Databases" : "Import MMDB Databases")
                }
            }
            .themedRow()

            if mmdbManager.hasDatabases {
                reloadButton
                clearButton
            }
        } header: {
            Text("Database Actions")
        } footer: {
            Text("Import one or more `.mmdb` files. Use Edit to drag databases into priority order. Higher-priority files are checked first, and lower-priority files are only used to fill fields still missing, so overlapping and duplicate databases are supported.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = mmdbManager.lastErrorMessage, !error.isEmpty {
            Section {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .themedRow()
            } header: {
                Text("Load Errors")
            }
        }
    }

    private var prioritySection: some View {
        Section {
            if mmdbManager.databases.isEmpty {
                Text("No MMDB files imported yet")
                    .foregroundStyle(.secondary)
                    .themedRow()
            } else {
                ForEach(Array(mmdbManager.databases.enumerated()), id: \.element.id) { index, database in
                    databaseRow(database, index: index)
                        .themedRow()
                }
                .onMove { source, destination in
                    mmdbManager.moveDatabase(from: source, to: destination)
                }
            }
        } header: {
            Text("Priority Order")
        } footer: {
            Text("Lookups stop as soon as all supported fields are filled or there are no more databases to check.")
        }
    }

    private var reloadButton: some View {
        Button {
            Task {
                await mmdbManager.reload()
            }
        } label: {
            HStack {
                Image(systemName: "arrow.clockwise")
                Text("Reload Imported Databases")
            }
        }
        .themedRow()
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            showingClearMMDBAlert = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Clear All Imported Databases")
            }
        }
        .themedRow()
    }

    private func databaseRow(_ database: MMDBDatabaseDescriptor, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(database.originalFileName)
                Text("\(database.databaseType) - IPv\(database.ipVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(database.importedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button(role: .destructive) {
                mmdbManager.removeDatabase(id: database.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .opacity(editMode?.wrappedValue.isEditing == true ? 0 : 1)
            .disabled(editMode?.wrappedValue.isEditing == true)
        }
    }

    private func handleMMDBImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                let report = try mmdbManager.importFiles(from: urls)
                if report.hasFailures {
                    mmdbErrorMessage = "Imported \(report.importedCount) database(s).\n\n\(report.failures.joined(separator: "\n"))"
                    showingMMDBError = true
                }
            } catch {
                mmdbErrorMessage = error.localizedDescription
                showingMMDBError = true
            }

        case .failure(let error):
            mmdbErrorMessage = "File selection failed: \(error.localizedDescription)"
            showingMMDBError = true
        }
    }
}
