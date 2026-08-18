//
//  GhosttyConfigImportView.swift
//  rootshell
//
//  Migrate-from-desktop-Ghostty entry point. Picks a config file, parses it,
//  shows a per-category preview, applies on confirmation, and reports a
//  summary. Live-source keybind import is delegated to KeybindManager.
//

import SwiftUI
import UniformTypeIdentifiers

struct GhosttyConfigImportView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var showFilePicker = false
    @State private var pickerError: String?

    @State private var pendingPlan: MigrationPlan?
    @State private var planError: String?
    @State private var summary: MigrationSummary?

    #if STANDALONE
    @State private var defaultConfigs: [URL] = []
    #endif

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Migrate from Ghostty")
                        .font(.headline)
                    Text("Pick a Ghostty config file (config or config.ghostty) and rootshell will read the settings it supports — fonts, theme, cursor, palette, keybinds — into your existing settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            #if STANDALONE
            if !defaultConfigs.isEmpty {
                Section {
                    ForEach(defaultConfigs, id: \.self) { url in
                        Button {
                            handleDirectURL(url)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text.magnifyingglass")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.body)
                                    Text(displayPath(for: url))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Default Locations")
                } footer: {
                    Text("Detected Ghostty config files in standard locations on this Mac.")
                }
            }
            #endif

            Section {
                Button {
                    showFilePicker = true
                } label: {
                    HStack {
                        Image(systemName: "doc.badge.arrow.up")
                        Text("Select Ghostty Config File...")
                    }
                }
                .themedRow()
            } footer: {
                Text("Your existing rootshell settings stay editable in the Settings UI after import. Keybinds are imported to ~/.ghostty/imported_keybinds.conf and managed under Keyboard Shortcuts.")
            }
        }
        .themedList()
        .navigationTitle("Import from Ghostty")
        #if STANDALONE
        .onAppear {
            defaultConfigs = GhosttyConfigImporter.discoverDefaultConfigs()
        }
        #endif
        .fileImporter(
            isPresented: $showFilePicker,
            // Ghostty's canonical config file is extensionless ("config"), which
            // many document pickers report as `public.data`. Including `.data`
            // alongside the text/.conf/.ghostty types makes that file pickable;
            // we validate by parsing — empty or malformed files surface a clear
            // error.
            allowedContentTypes: [
                .plainText,
                .text,
                .data,
                UTType(filenameExtension: "conf") ?? .text,
                UTType(filenameExtension: "ghostty") ?? .text,
            ],
            onCompletion: handleFileSelection
        )
        .sheet(item: planBinding) { plan in
            NavigationStack {
                MigrationPreviewSheet(
                    plan: plan,
                    onCancel: { pendingPlan = nil },
                    onApply: {
                        let result = GhosttyConfigImporter.apply(plan)
                        pendingPlan = nil
                        summary = result
                    }
                )
            }
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(item: summaryBinding) { result in
            NavigationStack {
                MigrationSummarySheet(summary: result, onDismiss: { summary = nil })
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Import Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {
                pickerError = nil
                planError = nil
            }
        } message: {
            Text(pickerError ?? planError ?? "")
        }
    }

    // MARK: - Bindings

    private var planBinding: Binding<MigrationPlan?> {
        Binding(get: { pendingPlan }, set: { pendingPlan = $0 })
    }

    private var summaryBinding: Binding<MigrationSummary?> {
        Binding(get: { summary }, set: { summary = $0 })
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { pickerError != nil || planError != nil },
            set: { if !$0 { pickerError = nil; planError = nil } }
        )
    }

    // MARK: - File Selection

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                let plan = try GhosttyConfigImporter.preview(from: url)
                pendingPlan = plan
            } catch {
                planError = error.localizedDescription
            }
        case .failure(let error):
            pickerError = error.localizedDescription
        }
    }

    /// One-tap import from a known-good URL on Standalone Catalyst — no file
    /// picker, no security-scoped resource grant required since the build is
    /// non-sandboxed and can read the user's home directory directly.
    private func handleDirectURL(_ url: URL) {
        do {
            let plan = try GhosttyConfigImporter.preview(from: url)
            pendingPlan = plan
        } catch {
            planError = error.localizedDescription
        }
    }

    /// Compact form of an absolute path for the row subtitle (e.g.
    /// `~/Library/Application Support/com.mitchellh.ghostty/config`).
    private func displayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

// MARK: - Preview Sheet

private struct MigrationPreviewSheet: View {
    let plan: MigrationPlan
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.sourceURL.lastPathComponent)
                        .font(.headline)
                    Text("\(plan.recognized.count) setting(s) ready to import • \(plan.unsupported.count) skipped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            ForEach(plan.groupedRecognized, id: \.0) { (category, changes) in
                Section(category.displayName) {
                    ForEach(changes, id: \.self) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                            Text(change.key)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }

            if !plan.unsupported.isEmpty {
                Section("Skipped") {
                    ForEach(plan.unsupported, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.key)
                                .font(.subheadline)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }

            if !plan.warnings.isEmpty {
                Section("Notes") {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Review Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply", action: onApply)
                    .disabled(!plan.hasAnythingToApply)
            }
        }
    }
}

// MARK: - Summary Sheet

private struct MigrationSummarySheet: View {
    let summary: MigrationSummary
    let onDismiss: () -> Void

    var body: some View {
        List {
            Section {
                Label {
                    Text("Imported \(summary.appliedCount) setting(s)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                .themedRow()

                if summary.unsupportedCount > 0 {
                    Label {
                        Text("Skipped \(summary.unsupportedCount) unsupported key(s)")
                    } icon: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                if let themeName = summary.registeredCustomThemeName {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Registered custom theme")
                                .font(.subheadline)
                            Text(themeName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "paintpalette")
                    }
                    .themedRow()
                }

                if summary.keybindsImported {
                    Label {
                        Text("Keybinds imported — manage under Settings → Keyboard Shortcuts")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "keyboard")
                    }
                    .themedRow()
                }
            }

            if !summary.warnings.isEmpty {
                Section("Notes") {
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption)
                            .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Import Complete")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
            }
        }
    }
}

// MARK: - Identifiable adaptors for `.sheet(item:)`

extension MigrationPlan: Identifiable {
    var id: URL { sourceURL }
}

extension MigrationSummary: Identifiable {
    var id: Int {
        // Distinct identity per-apply. AppliedCount + warningsHash is enough
        // for the UI to re-show the sheet on repeated imports.
        var hasher = Hasher()
        hasher.combine(appliedCount)
        hasher.combine(unsupportedCount)
        for w in warnings { hasher.combine(w) }
        hasher.combine(registeredCustomThemeName)
        hasher.combine(keybindsImported)
        return hasher.finalize()
    }
}
