//
//  FavoriteThemesManager.swift
//  rootshell
//
//  Manages favorite themes stored locally in UserDefaults
//

import Foundation
import Combine
import os

@MainActor
class FavoriteThemesManager: ObservableObject {
    static let shared = FavoriteThemesManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "FavoriteThemesManager")

    /// Set of favorite theme IDs
    @Published private(set) var favoriteThemeIds: Set<String> = []

    /// Publisher for when favorites change
    let favoritesDidChange = PassthroughSubject<Void, Never>()

    private init() {
        loadFavorites()
        SettingsRefreshHub.shared.register(keys: [Settings.Theme.favoriteIds.name]) { [weak self] _ in
            self?.loadFavorites()
            self?.favoritesDidChange.send()
        }
    }

    // MARK: - Public API

    /// Toggle a theme's favorite status
    func toggleFavorite(_ themeId: String) {
        if favoriteThemeIds.contains(themeId) {
            favoriteThemeIds.remove(themeId)
            Self.logger.info("Removed theme from favorites: \(themeId)")
        } else {
            favoriteThemeIds.insert(themeId)
            Self.logger.info("Added theme to favorites: \(themeId)")
        }
        saveFavorites()
        favoritesDidChange.send()
    }

    /// Check if a theme is favorited
    func isFavorite(_ themeId: String) -> Bool {
        favoriteThemeIds.contains(themeId)
    }

    /// Get all favorite themes as ThemeInfo objects, sorted alphabetically
    func favoriteThemes() -> [ThemeManager.ThemeInfo] {
        // Resolved one name at a time: this runs during SwiftUI body evaluation,
        // so it must not wait on (or trigger) the full catalog load.
        favoriteThemeIds
            .compactMap { ThemeManager.shared.themeInfo(for: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Add a theme to favorites (no-op if already favorite)
    func addFavorite(_ themeId: String) {
        guard !favoriteThemeIds.contains(themeId) else { return }
        favoriteThemeIds.insert(themeId)
        saveFavorites()
        favoritesDidChange.send()
    }

    /// Remove a theme from favorites (no-op if not favorite)
    func removeFavorite(_ themeId: String) {
        guard favoriteThemeIds.contains(themeId) else { return }
        favoriteThemeIds.remove(themeId)
        saveFavorites()
        favoritesDidChange.send()
    }

    /// Remove all favorites
    func clearAllFavorites() {
        favoriteThemeIds.removeAll()
        saveFavorites()
        favoritesDidChange.send()
    }

    // MARK: - Persistence

    private func loadFavorites() {
        favoriteThemeIds = Set(SettingsStore.shared.get(Settings.Theme.favoriteIds))
        Self.logger.info("Loaded \(self.favoriteThemeIds.count) favorite themes")
    }

    private func saveFavorites() {
        let array = Array(favoriteThemeIds)
        SettingsStore.shared.set(Settings.Theme.favoriteIds, array)
        Self.logger.info("Saved \(array.count) favorite themes to UserDefaults")
    }
}
