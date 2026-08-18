//
//  FontSettingsView.swift
//  rootshell
//
//  Font selection and import settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct FontSettingsView: View {
    @ObservedObject private var fontManager = FontManager.shared
    @State private var showingFileImporter = false
    @State private var importError: String?
    @State private var showingImportError = false

    var body: some View {
        List {
            // MARK: - Bundled Fonts
            Section("Bundled Fonts") {
                // Ghostty Default option
                Button(action: {
                    fontManager.currentFontFamily = nil
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ghostty Default")
                                .foregroundColor(.primary)
                            Text("The quick brown fox 0123456789")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if fontManager.currentFontFamily == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                // Bundled fonts
                ForEach(fontManager.availableFamilies) { family in
                    Button(action: {
                        fontManager.currentFontFamily = family.configName
                    }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(family.displayName)
                                    .foregroundColor(.primary)
                                // Inline sample text preview
                                if let sampleFont = family.sampleFont {
                                    Text("The quick brown fox 0123456789")
                                        .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("The quick brown fox 0123456789")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if fontManager.currentFontFamily == family.configName {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            }

            // MARK: - System Fonts
            if !fontManager.systemFontFamilies.isEmpty {
                Section {
                    ForEach(fontManager.systemFontFamilies) { family in
                        Button(action: {
                            fontManager.currentFontFamily = family.configName
                        }) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(family.displayName)
                                        .foregroundColor(.primary)
                                    if let sampleFont = family.sampleFont {
                                        Text("The quick brown fox 0123456789")
                                            .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("The quick brown fox 0123456789")
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if fontManager.currentFontFamily == family.configName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }
                } header: {
                    Text("System Fonts")
                } footer: {
                    Text("Monospace fonts installed on your device via apps like Font Case.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Custom Fonts
            Section {
                ForEach(fontManager.customFontFamilies) { family in
                    Button(action: {
                        fontManager.currentFontFamily = family.configName
                    }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(family.displayName)
                                    .foregroundColor(.primary)
                                if let sampleFont = fontManager.sampleFontForCustomFamily(family) {
                                    Text("The quick brown fox 0123456789")
                                        .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("The quick brown fox 0123456789")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                let styleCount = family.fontFiles.count
                                Text("\(styleCount) style\(styleCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if fontManager.currentFontFamily == family.configName {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let family = fontManager.customFontFamilies[index]
                        fontManager.deleteCustomFontFamily(id: family.id)
                    }
                }

                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import Font...", systemImage: "plus.circle")
                }
                .themedRow()
            } header: {
                Text("Custom Fonts")
            } footer: {
                if fontManager.customFontFamilies.isEmpty {
                    #if targetEnvironment(macCatalyst)
                    Text("Import your own TTF or OTF font files. Select multiple files at once to import all weights of a font family. If your font came as a ZIP file, extract it first using Finder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #else
                    Text("Import your own TTF or OTF font files. Select multiple files at once to import all weights of a font family. If your font came as a ZIP file, extract it first using the Files app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
                }
            }

            Section("Font Size") {
                HStack {
                    Text("\(Int(fontManager.currentFontSize))")
                        .frame(width: 40)
                        .monospacedDigit()
                    Slider(value: $fontManager.currentFontSize, in: 4...24, step: 1)
                }
                .themedRow()
            }

            cellSpacingSection

            Section {
                Toggle("Enable Ligatures", isOn: $fontManager.ligaturesEnabled)
                    .padding(.vertical, 4)
                    .themedRow()

                NavigationLink {
                    FontFeatureSettingsView()
                } label: {
                    HStack {
                        Text("Stylistic Sets")
                        Spacer()
                        let count = fontManager.enabledFeatureTags(for: fontManager.currentFontFamily).count
                        if count > 0 {
                            Text("\(count) enabled")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()
            } header: {
                Text("Font Features")
            } footer: {
                Text("Ligatures combine multiple characters into single glyphs (e.g., != becomes ≠). Stylistic sets control alternate letterforms like slashed zero and alternate characters.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Footer with font count
            Section {
                let bundledCount = fontManager.availableFamilies.count
                let systemCount = fontManager.systemFontFamilies.count
                let customCount = fontManager.customFontFamilies.count
                let parts = [
                    "\(bundledCount) bundled",
                    systemCount > 0 ? "\(systemCount) system" : nil,
                    customCount > 0 ? "\(customCount) custom" : nil
                ].compactMap { $0 }
                Text("\(parts.joined(separator: " + ")) font families")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.font, UTType(filenameExtension: "ttf")!, UTType(filenameExtension: "otf")!],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                do {
                    let imported = try fontManager.importFonts(from: urls)
                    // Auto-select the first imported family
                    if let first = imported.first {
                        fontManager.currentFontFamily = first.configName
                    }
                } catch {
                    importError = error.localizedDescription
                    showingImportError = true
                }
            case .failure(let error):
                importError = error.localizedDescription
                showingImportError = true
            }
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK") {}
        } message: {
            Text(importError ?? String(localized: "An unknown error occurred", comment: "Generic error fallback message"))
        }
    }

    // MARK: - Cell Spacing

    @ViewBuilder
    private var cellSpacingSection: some View {
        let family = fontManager.currentFontFamily
        let displayName = fontManager.currentFontFamilyDisplayName
        let current = fontManager.cellAdjustments(for: family)

        let widthBinding = Binding<Double>(
            get: { Double(fontManager.cellAdjustments(for: family).widthPercent) },
            set: { fontManager.setCellWidth(Int($0.rounded()), for: family) }
        )
        let heightBinding = Binding<Double>(
            get: { Double(fontManager.cellAdjustments(for: family).heightPercent) },
            set: { fontManager.setCellHeight(Int($0.rounded()), for: family) }
        )

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Width")
                    Spacer()
                    Text(current.widthPercent, format: .percent)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: widthBinding, in: -25...25, step: 1)
            }
            .padding(.vertical, 4)
            .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Height")
                    Spacer()
                    Text(current.heightPercent, format: .percent)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: heightBinding, in: -25...25, step: 1)
            }
            .padding(.vertical, 4)
            .themedRow()

            if !current.isZero {
                Button("Reset to \(0.formatted(.percent))") {
                    fontManager.setCellAdjustments(.zero, for: family)
                }
                .themedRow()
            }
        } header: {
            Text("Cell Spacing — \(displayName)")
        } footer: {
            Text("Adjusts the cell box around each glyph for the selected font. Negative values tighten spacing; positive values loosen it. Settings are saved per font.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Cursor Settings

