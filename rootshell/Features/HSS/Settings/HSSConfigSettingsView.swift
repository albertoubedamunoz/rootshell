//
//  HSSConfigSettingsView.swift
//  rootshell
//
//  Settings view for HSS (Host Shorthand System) configuration
//

import SwiftUI
import UniformTypeIdentifiers

struct HSSConfigSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject var hssManager = HSSConfigManager.shared

    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingClearAlert = false

    var body: some View {
        List {
            // Status Section
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HSSConfigStatusBadge(status: hssManager.status)
                }
                .themedRow()

                if let fileName = hssManager.fileName {
                    HStack {
                        Text("File")
                        Spacer()
                        Text(fileName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .themedRow()
                }

                if let lastLoad = hssManager.lastLoadDate {
                    HStack {
                        Text("Last Loaded")
                        Spacer()
                        Text(lastLoad, style: .relative)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    .themedRow()
                }
            } header: {
                Text("Configuration File")
            }

            // Actions Section
            Section {
                Button(action: { showingFilePicker = true }) {
                    HStack {
                        Image(systemName: "doc.badge.plus")
                        Text(hssManager.fileName == nil ? String(localized: "Select HSS Config File", comment: "HSS config: select file button") : String(localized: "Change Config File", comment: "HSS config: change file button"))
                    }
                }
                .themedRow()

                if case .staleBookmark = hssManager.status {
                    Button(action: { showingFilePicker = true }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Re-select File (Bookmark Stale)")
                        }
                    }
                    .foregroundColor(.orange)
                    .themedRow()
                }

                if hssManager.hasPatterns {
                    Button(action: {
                        Task {
                            await hssManager.reload()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reload Config")
                        }
                    }
                    .themedRow()
                }

                if hssManager.fileName != nil {
                    Button(role: .destructive, action: { showingClearAlert = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Config")
                        }
                    }
                    .themedRow()
                }
            }

            // Patterns Preview Section
            if !hssManager.patterns.isEmpty {
                Section {
                    ForEach(Array(hssManager.patterns.prefix(5).enumerated()), id: \.offset) { index, pattern in
                        VStack(alignment: .leading, spacing: 4) {
                            if let note = pattern.note {
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                            }

                            Text(pattern.short)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)

                            Text(pattern.long)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .themedRow()
                    }

                    if hssManager.patterns.count > 5 {
                        Text("... and \(hssManager.patterns.count - 5) more patterns")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }
                } header: {
                    Text("Patterns (\(hssManager.patterns.count))")
                }
            }

            // Help Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("About HSS", systemImage: "info.circle")
                        .font(.subheadline.bold())

                    Text("HSS (Host Shorthand System) lets you define regex patterns that expand SSH shortcuts into full connection strings.")
                        .font(.caption)

                    Text("This is a native Swift implementation targeting compatibility with the original Ruby HSS tool. Due to sandbox restrictions, exec-based features are not supported.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Link(destination: URL(string: "https://github.com/akerl/hss")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text("github.com/akerl/hss")
                        }
                        .font(.caption)
                    }

                    Text("Usage: Type !shorthand in the quick connect field")
                        .font(.caption)
                        .foregroundColor(.blue)

                    Text("Example: !prod might expand to ssh deploy@production.example.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            // External Files Info
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("External Files", systemImage: "folder")
                        .font(.subheadline.bold())

                    Text("If your HSS config uses external() to load other YAML files, place those files in the app's Documents folder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("HSS Config")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [
                UTType(filenameExtension: "yml") ?? .yaml,
                UTType(filenameExtension: "yaml") ?? .yaml,
                .yaml
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result: result)
        }
        .alert("Import Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Clear HSS Config", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                hssManager.clearConfig()
            }
        } message: {
            Text("This will remove the HSS configuration. You'll need to re-select the file to use HSS shortcuts again.")
        }
    }

    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            do {
                try hssManager.importFile(from: url)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }

        case .failure(let error):
            errorMessage = "File selection failed: \(error.localizedDescription)"
            showingError = true
        }
    }
}

// MARK: - Status Badge

struct HSSConfigStatusBadge: View {
    let status: HSSConfigStatus

    var body: some View {
        switch status {
        case .none:
            Text("Not Configured")
                .foregroundColor(.secondary)
                .font(.subheadline)

        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading...")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }

        case .loaded(let count):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(count) patterns")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }

        case .error(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Error")
                    .foregroundColor(.orange)
                    .font(.subheadline)
            }
            .help(message)

        case .staleBookmark:
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundColor(.yellow)
                Text("Re-select File")
                    .foregroundColor(.yellow)
                    .font(.subheadline)
            }
        }
    }
}

#Preview {
    NavigationView {
        HSSConfigSettingsView()
    }
}
