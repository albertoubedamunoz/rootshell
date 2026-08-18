//
//  ThemeEditorView.swift
//  rootshell
//
//  Theme editor with color pickers and live terminal preview
//

import SwiftUI

struct ThemeEditorView: View {
    enum EditorMode: Identifiable {
        case new
        case edit(CustomTheme)
        case duplicate(ThemeManager.ThemeInfo)

        var id: String {
            switch self {
            case .new: return "new-\(UUID())"
            case .edit(let theme): return "edit-\(theme.id)"
            case .duplicate(let info): return "dup-\(info.id)"
            }
        }
    }

    let mode: EditorMode
    let onSave: ((CustomTheme) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var theme: CustomTheme
    @State private var showingNameWarning = false
    @State private var nameWarningMessage = ""

    private let ansiNormalLabels = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"
    ]

    init(mode: EditorMode, onSave: ((CustomTheme) -> Void)? = nil) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            _theme = State(initialValue: CustomTheme.defaultTheme())
        case .edit(let existing):
            _theme = State(initialValue: existing)
        case .duplicate(let info):
            _theme = State(initialValue: CustomThemeManager.shared.duplicateBuiltInTheme(info))
        }
    }

    var body: some View {
        NavigationView {
            Form {
                // Live preview
                Section {
                    TerminalSnippetView(colors: theme.themeColors, compact: false)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                // Theme name
                Section {
                    TextField("Theme Name", text: $theme.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    if showingNameWarning {
                        Text(nameWarningMessage)
                            .foregroundColor(.orange)
                    }
                }

                // Core colors
                Section("Colors") {
                    colorRow("Background", keyPath: \.background)
                    colorRow("Foreground", keyPath: \.foreground)
                }

                // Cursor colors
                Section("Cursor") {
                    colorRow("Cursor Color", keyPath: \.cursorColor)
                    colorRow("Cursor Text", keyPath: \.cursorText)
                }

                // Selection colors
                Section("Selection") {
                    colorRow("Selection Background", keyPath: \.selectionBackground)
                    colorRow("Selection Foreground", keyPath: \.selectionForeground)
                }

                // ANSI Normal (0-7)
                Section("ANSI Normal") {
                    ForEach(0..<8, id: \.self) { index in
                        paletteRow(index: index, label: ansiNormalLabels[index])
                    }
                }

                // ANSI Bright (8-15)
                Section("ANSI Bright") {
                    ForEach(8..<16, id: \.self) { index in
                        paletteRow(index: index, label: "Bright \(ansiNormalLabels[index - 8])")
                    }
                }

                // Extended palette indicator
                if theme.hasExtendedPalette {
                    Section {
                        Label(
                            String(localized: "This theme includes \(theme.extendedPalette.count) extended palette colors (indices 16-255) that will be preserved."),
                            systemImage: "paintpalette"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .themedRow()
                    } header: {
                        Text("Extended Palette")
                    }
                }
            }
            .themedList()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onChange(of: theme.name) { _, newName in
                validateName(newName)
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: return String(localized: "New Theme")
        case .edit: return String(localized: "Edit Theme")
        case .duplicate: return String(localized: "Duplicate Theme")
        }
    }

    // MARK: - Color Rows

    private func colorRow(_ label: String, keyPath: WritableKeyPath<CustomTheme, String>) -> some View {
        ColorPicker(label, selection: colorBinding(for: keyPath), supportsOpacity: false)
            .themedRow()
    }

    private func paletteRow(index: Int, label: String) -> some View {
        ColorPicker(label, selection: paletteBinding(index: index), supportsOpacity: false)
            .themedRow()
    }

    // MARK: - Color Bindings

    private func colorBinding(for keyPath: WritableKeyPath<CustomTheme, String>) -> Binding<Color> {
        Binding(
            get: {
                let raw = theme[keyPath: keyPath]
                if let color = Color(hex: raw) { return color }
                // Resolve Ghostty keywords like "cell-foreground"
                let resolved = Color.resolveKeywordColor(raw, foreground: theme.foreground, background: theme.background)
                return Color(hex: resolved) ?? .gray
            },
            set: { newColor in theme[keyPath: keyPath] = newColor.hexString }
        )
    }

    private func paletteBinding(index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard index < theme.palette.count else { return .gray }
                return Color(hex: theme.palette[index]) ?? .gray
            },
            set: { newColor in
                guard index < theme.palette.count else { return }
                theme.palette[index] = newColor.hexString
            }
        )
    }

    // MARK: - Validation & Save

    private func validateName(_ name: String) {
        let validation = CustomThemeManager.shared.validateName(
            name,
            excludingId: theme.id
        )
        switch validation {
        case .valid, .empty:
            showingNameWarning = false
        case .containsPathSeparator:
            showingNameWarning = true
            nameWarningMessage = String(localized: "Theme name cannot contain path separators.")
        case .conflictsWithCustom:
            showingNameWarning = true
            nameWarningMessage = String(localized: "A custom theme with this name already exists.")
        case .shadowsBuiltIn:
            showingNameWarning = true
            nameWarningMessage = String(localized: "This will override the built-in theme with the same name.")
        }
    }

    private func save() {
        let validation = CustomThemeManager.shared.validateName(
            theme.name,
            excludingId: theme.id
        )
        guard validation != .empty, validation != .containsPathSeparator, validation != .conflictsWithCustom else {
            return
        }
        CustomThemeManager.shared.saveTheme(theme)
        onSave?(theme)
        dismiss()
    }
}
