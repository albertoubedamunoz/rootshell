//
//  ConfigFileSettingsView.swift
//  rootshell
//
//  Status, contents, and diagnostics of the user-facing text config file.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConfigFileSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var manager = ConfigOverlayManager.shared
    @State private var store = SettingsStore.shared
    @State private var showEditor = false
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var showCreateWarning = false
    @State private var exportDocument: ConfigTextDocument?

    private let registry = SettingsRegistry.shared

    var body: some View {
        List {
            statusSection
            actionsSection
            if !manager.boundEntries.isEmpty { boundSection }
            if !manager.diagnostics.isEmpty { diagnosticsSection }
            optionsSection
            exportSection
        }
        .themedList()
        .navigationTitle("Config File")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showEditor) {
            ConfigFileEditorSheet(url: manager.activeURL) { manager.reload() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .data, .item]) { result in
            if case .success(let url) = result { manager.setExternalFile(url) }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: .plainText,
                      defaultFilename: "rootshell.conf") { _ in }
        .alert("Create Config File?", isPresented: $showCreateWarning) {
            Button("Create") { manager.createTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file starts with every setting commented out. Any line you uncomment is kept on this device and stops following iCloud until you remove it.")
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text("Path")
                Spacer()
                Text(manager.shellDisplayPath)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .themedRow()
            HStack {
                Text("Status")
                Spacer()
                Text(statusText)
                    .foregroundColor(statusColor)
            }
            .themedRow()
            if let loaded = manager.lastLoaded {
                HStack {
                    Text("Last Loaded")
                    Spacer()
                    Text(loaded, style: .relative)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } header: {
            Text("Config File")
        } footer: {
            Text("A ghostty-style text file: one `key = value` per line, `#` for comments. Every key in the file is kept on this device and ignores iCloud until you remove it. This is separate from the terminal engine's generated config, which rootshell rebuilds from your settings automatically.")
        }
    }

    private var actionsSection: some View {
        Section {
            if !manager.fileExists && !manager.isExternal {
                Button {
                    showCreateWarning = true
                } label: {
                    Label("Create Config File", systemImage: "doc.badge.plus")
                }
                .themedRow()
            }
            if manager.fileExists {
                Button {
                    showEditor = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .themedRow()
                Button {
                    manager.reload()
                } label: {
                    Label("Reload Now", systemImage: "arrow.clockwise")
                }
                .themedRow()
            }
            Button {
                showImporter = true
            } label: {
                Label("Choose External File…", systemImage: "folder")
            }
            .themedRow()
            if manager.isExternal {
                Button(role: .destructive) {
                    manager.clearExternalFile()
                } label: {
                    Label("Stop Using External File", systemImage: "xmark.circle")
                }
                .themedRow()
            }
        } footer: {
            Text("An external file in iCloud Drive or a dotfile repo lets you edit with any editor; note that a shared file pins its keys on every device that uses it.")
        }
    }

    private var boundSection: some View {
        Section {
            ForEach(manager.boundEntries.values.sorted { $0.line < $1.line }, id: \.key) { entry in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.configKey)
                            .font(.system(.body, design: .monospaced))
                        Text(registry.definition(for: entry.key).map { $0.display(store.codableValue(entry.key)) } ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(entry.file.lastPathComponent):\(entry.line)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .themedRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        manager.removeFromFile(entry.key)
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } header: {
            Text("Settings From This File (\(manager.boundEntries.count))")
        } footer: {
            Text("Swipe to comment a line out; the setting then follows iCloud again.")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            ForEach(manager.diagnostics) { diag in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(for: diag.severity))
                        .foregroundColor(color(for: diag.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diag.message)
                            .font(.footnote)
                        if let location = diag.location {
                            Text(location)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()
            }
        } header: {
            Text("Diagnostics")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Allow Settings to Edit This File", isOn: Binding(
                get: { manager.writeBackEnabled },
                set: { manager.writeBackEnabled = $0 }
            ))
            .themedRow()
        } footer: {
            Text("When on, changing a file-bound setting in Settings rewrites just that line and keeps your comments. When off, those settings are read-only here.")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                exportDocument = ConfigTextDocument(text: ConfigFileExporter.render(includeDefaults: true))
                showExporter = true
            } label: {
                Label("Export Current Settings…", systemImage: "square.and.arrow.up")
            }
            .themedRow()
        } footer: {
            Text("Writes every setting with its current value: changed settings live, defaults commented. Placing the file pins every uncommented key on that device.")
        }
    }

    private var statusText: String {
        switch manager.status {
        case .notFound: String(localized: "Not found", comment: "Config file status")
        case .active(let count): String(localized: "Active, \(count) settings", comment: "Config file status")
        case .error(let message): message
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .notFound: .secondary
        case .active: .green
        case .error: .red
        }
    }

    private func symbol(for severity: ConfigOverlayDiagnostic.Severity) -> String {
        switch severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func color(for severity: ConfigOverlayDiagnostic.Severity) -> Color {
        switch severity {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Plain-text document for the export sheet.
struct ConfigTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
