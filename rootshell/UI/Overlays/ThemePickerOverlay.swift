//
//  ThemePickerOverlay.swift
//  rootshell
//
//  Floating overlay for quick theme selection with favorites and per-tab/window overrides
//

import SwiftUI

/// Floating theme picker overlay that can be opened via keyboard shortcut (Cmd+Shift+T)
struct ThemePickerOverlay: View {
    @Binding var isPresented: Bool
    let windowId: String
    let currentTabId: UUID?
    let onThemeSelected: (String, ThemePickerScope) -> Void

    var themeManager = ThemeManager.shared
    @ObservedObject private var favoriteManager = FavoriteThemesManager.shared
    var overrideManager = ThemeOverrideManager.shared

    @State private var scope: ThemePickerScope = .global
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    enum ThemePickerScope: String, CaseIterable {
        case tab = "Tab"
        case window = "Window"
        case global = "Global"

        var displayName: String {
            switch self {
            case .tab: return String(localized: "Tab", comment: "Theme picker scope: apply to current tab")
            case .window: return String(localized: "Window", comment: "Theme picker scope: apply to current window")
            case .global: return String(localized: "Global", comment: "Theme picker scope: apply globally")
            }
        }
    }

    var body: some View {
        // Positioning + (no) dragging is handled by the hosting DraggableHUDContainer.
        // A native UIKit host is required: as a plain SwiftUI overlay the search
        // field's focus made .onKeyPress steal the X-button click on macOS.
        pickerContent
            .onAppear {
                isSearchFocused = true
            }
            // Awaits the background parse if the picker is opened before it
            // lands; normally it has already finished and this returns at once.
            .task { await themeManager.ensureThemesLoaded() }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            // Header with scope picker and close button
            HStack {
                Text("Theme")
                    .font(.headline)
                    .fontWeight(.semibold)

                Spacer()

                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Scope picker
            Picker("Scope", selection: $scope) {
                ForEach(ThemePickerScope.allCases, id: \.self) { s in
                    Text(s.displayName).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search themes", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            // Theme list
            ScrollView {
                LazyVStack(spacing: 4) {
                    // Current override info (if any)
                    if let overrideInfo = currentOverrideInfo {
                        overrideInfoSection(overrideInfo)
                    }

                    // Active theme pinned first so it never has to be scrolled to
                    if searchText.isEmpty, let current = currentThemeInfo {
                        currentSection(current)
                    }

                    // Favorites section
                    if !favoriteManager.favoriteThemeIds.isEmpty && searchText.isEmpty {
                        favoritesSection
                    }

                    // All themes (filtered)
                    themesSection
                }
                .padding(.vertical, 8)
            }
            .id(searchText)
            // Fixed (not max) height: hosted in a UIHostingController, a ScrollView
            // with only a max height collapses under intrinsic sizing.
            .frame(height: 350)
        }
        .frame(width: 340)
        .themePickerBackground()
        // Cmd-Shift-T / Escape dismissal is handled by host-level UIKeyCommands in
        // DraggableHUDContainer — a SwiftUI .onKeyPress here is preempted on macOS by
        // the app's registered Cmd-Shift-T menu shortcut.
    }

    // MARK: - Current Override Info

    private var currentOverrideInfo: (themeName: String, source: ThemeOverrideManager.ThemeSource)? {
        let (themeName, source) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        if source != .global {
            return (themeName, source)
        }
        return nil
    }

    @ViewBuilder
    private func overrideInfoSection(_ info: (themeName: String, source: ThemeOverrideManager.ThemeSource)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paintbrush.fill")
                    .foregroundColor(.accentColor)
                Text("Current Override")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack {
                Text(info.themeName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("(\(info.source == .tab ? String(localized: "Tab", comment: "Theme override source: tab") : String(localized: "Window", comment: "Theme override source: window")))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Clear") {
                    clearCurrentOverride()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func clearCurrentOverride() {
        if let tabId = currentTabId, overrideManager.hasTabOverride(tabId: tabId) {
            overrideManager.clearTabOverride(tabId: tabId)
        } else if overrideManager.hasWindowOverride(windowId: windowId) {
            overrideManager.clearWindowOverride(windowId: windowId)
        }
    }

    // MARK: - Current Section

    private var currentThemeInfo: ThemeManager.ThemeInfo? {
        let (currentName, _) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        return themeManager.availableThemes.first { $0.name == currentName }
    }

    @ViewBuilder
    private func currentSection(_ theme: ThemeManager.ThemeInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Current")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            themeRow(theme, isFavorite: favoriteManager.isFavorite(theme.id))

            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Favorites Section

    @ViewBuilder
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Favorites")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            ForEach(favoriteManager.favoriteThemes()) { theme in
                themeRow(theme, isFavorite: true)
            }

            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Themes Section

    private var filteredThemes: [ThemeManager.ThemeInfo] {
        let allThemes = themeManager.availableThemes
        if searchText.isEmpty {
            return allThemes
        }
        return allThemes.filter { theme in
            theme.name.localizedCaseInsensitiveContains(searchText) ||
            theme.family.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    private var themesSection: some View {
        let themes = filteredThemes
        if themes.isEmpty {
            Text("No themes found")
                .foregroundColor(.secondary)
                .padding()
        } else {
            ForEach(themes) { theme in
                themeRow(theme, isFavorite: favoriteManager.isFavorite(theme.id))
            }
        }
    }

    // MARK: - Theme Row

    @ViewBuilder
    private func themeRow(_ theme: ThemeManager.ThemeInfo, isFavorite: Bool) -> some View {
        Button(action: { selectTheme(theme) }) {
            HStack(spacing: 12) {
                // Color preview
                colorPreview(theme)

                // Theme name
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if theme.family != theme.displayName {
                        Text(theme.family)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Current indicator
                if isCurrentTheme(theme) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }

                // Favorite button
                Button(action: { toggleFavorite(theme) }) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundColor(isFavorite ? .yellow : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.001)) // Make entire row tappable
        }
        .buttonStyle(.plain)
    }

    private func colorPreview(_ theme: ThemeManager.ThemeInfo) -> some View {
        HStack(spacing: 2) {
            // Background color
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: theme.colors.background) ?? .black)
                .frame(width: 20, height: 20)

            // Foreground color
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: theme.colors.foreground) ?? .white)
                .frame(width: 20, height: 20)

            // First palette color (if available)
            if let firstPalette = theme.colors.palette.first {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: firstPalette) ?? .gray)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }

    private func isCurrentTheme(_ theme: ThemeManager.ThemeInfo) -> Bool {
        let (currentTheme, _) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        return theme.name == currentTheme
    }

    // MARK: - Actions

    private func selectTheme(_ theme: ThemeManager.ThemeInfo) {
        onThemeSelected(theme.name, scope)
        isPresented = false
    }

    private func toggleFavorite(_ theme: ThemeManager.ThemeInfo) {
        favoriteManager.toggleFavorite(theme.id)
    }

}

private extension View {
    /// Liquid-glass panel background matching the find HUD's `searchOverlayBackground()`,
    /// at the picker's 16pt radius. `glassEffect` supplies its own elevation, so the
    /// manual shadow is only kept in the pre-26 fallback.
    @ViewBuilder
    func themePickerBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
        }
        #endif
    }
}
