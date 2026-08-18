import Foundation
import Combine
import SwiftUI
import os

/// Manages theme selection and application across the app.
///
/// Migrated from `ObservableObject + @Published` to `@Observable`. SwiftUI now
/// tracks per-property reads, so views that only read `currentThemeInfo` no
/// longer invalidate when the (cold-path) `availableThemes` array reloads.
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// Filter mode for theme browser
    enum ThemeFilterMode: String, CaseIterable {
        case all = "All"
        case light = "Light"
        case dark = "Dark"

        var localizedName: String {
            switch self {
            case .all: return String(localized: "All")
            case .light: return String(localized: "Light")
            case .dark: return String(localized: "Dark")
            }
        }

        var icon: String {
            switch self {
            case .all: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
            }
        }
    }

    /// Information about a theme.
    ///
    /// Boxed as a `final class` rather than a struct: previous (struct) builds
    /// caught the main thread inside `swift_cvw_initWithCopy` →
    /// `initializeWithCopy for ThemeManager.ThemeInfo` →
    /// `Array.subscript.read` during a scene-update transaction. Each
    /// `availableThemes[i]` and `themesByFamily[…][i]` access copied the
    /// struct (URL + ThemeColors with palette array). Reference semantics
    /// reduce per-access cost to a refcount op and remove the bridging
    /// `_ContiguousArrayStorage` paths the crash log captured. All properties
    /// remain `let`, so behavioral semantics are unchanged.
    final class ThemeInfo: Identifiable, Equatable, @unchecked Sendable {
        let id: String  // same as name
        let name: String
        let displayName: String
        let family: String
        let filePath: URL
        let colors: ThemeColors
        let isLight: Bool  // Pre-computed based on background luminance
        let isCustom: Bool

        struct ThemeColors: Equatable {
            let background: String
            let foreground: String
            let cursor: String
            let palette: [String]  // 16 palette colors (ANSI 0-15)

            static let `default` = ThemeColors(
                background: "#1e1e2e",
                foreground: "#cdd6f4",
                cursor: "#f5e0dc",
                palette: []
            )

            /// Returns a vibrant accent color suitable for UI tinting.
            /// If the cursor color is saturated enough (>= 0.20), uses it directly.
            /// Otherwise, picks from palette indices 1-6. When the background has
            /// appreciable hue (saturation > 0.10), prefers palette colors whose hue
            /// harmonizes with the background (within ±90°) to avoid clashing accents
            /// on chromatic backgrounds like dark teal or dark purple.
            var vibrantAccentColor: Color? {
                if let cursorColor = Color(hex: cursor), cursorColor.saturation >= 0.20 {
                    return cursorColor
                }
                // Pick from palette indices 1-6 (skip 0=black, 7=white)
                let candidates = palette.enumerated()
                    .filter { $0.offset >= 1 && $0.offset <= 6 }
                    .compactMap { (offset, hex) -> (Color, CGFloat)? in
                        guard let color = Color(hex: hex), color.saturation >= 0.20 else { return nil }
                        return (color, color.saturation)
                    }
                guard !candidates.isEmpty else { return nil }

                // If background is chromatic, prefer palette colors that harmonize with its hue
                if let bgColor = Color(hex: background), bgColor.saturation > 0.10 {
                    let harmonious = candidates.filter { $0.0.hueDifference(from: bgColor.hue) <= 0.25 }
                    if let best = harmonious.max(by: { $0.1 < $1.1 }) {
                        return best.0
                    }
                }

                // Default: most saturated
                return candidates.max(by: { $0.1 < $1.1 })?.0
            }

            /// Returns a sheet-safe accent color that preserves the theme hue
            /// but softens saturation and brightness against the sheet background.
            func sheetTintColor(for background: Color) -> Color? {
                vibrantAccentColor?.adjustedSheetTint(on: background)
            }
        }

        init(name: String, filePath: URL, colors: ThemeColors, isCustom: Bool = false) {
            self.id = name
            self.name = name
            self.displayName = name
            self.family = ThemeInfo.extractFamily(from: name)
            self.filePath = filePath
            self.colors = colors
            self.isCustom = isCustom
            // Compute isLight based on background luminance (threshold 0.5)
            self.isLight = Color(hex: colors.background)?.luminance ?? 0 > 0.5
        }

        /// Create ThemeInfo from a CustomTheme
        init(customTheme: CustomTheme) {
            self.id = customTheme.name
            self.name = customTheme.name
            self.displayName = customTheme.name
            self.family = ThemeInfo.extractFamily(from: customTheme.name)
            self.filePath = URL(fileURLWithPath: "/dev/null") // Custom themes use in-memory colors
            self.colors = customTheme.themeColors
            self.isCustom = true
            self.isLight = Color(hex: customTheme.background)?.luminance ?? 0 > 0.5
        }

        /// Extract theme family from name
        /// Examples: "Catppuccin Mocha" -> "Catppuccin", "Dracula" -> "Dracula"
        static func extractFamily(from name: String) -> String {
            // Common patterns for theme families
            let components = name.split(separator: " ")

            // If only one word, that's the family
            if components.count == 1 {
                return name
            }

            // For multi-word names, use first word as family
            // This handles: "Catppuccin Mocha", "Gruvbox Dark", "Solarized Light", etc.
            return String(components[0])
        }

        static func == (lhs: ThemeInfo, rhs: ThemeInfo) -> Bool {
            lhs.id == rhs.id
        }
    }

    private static let themeKey = "selectedTheme"

    /// All available themes
    private(set) var availableThemes: [ThemeInfo] = []

    /// Themes grouped by family
    private(set) var themesByFamily: [String: [ThemeInfo]] = [:]

    /// O(1) lookup index rebuilt with `availableThemes`. Internal cache —
    /// excluded from observation so refilling it during `loadThemes()` doesn't
    /// invalidate views that only read the `current*` properties.
    @ObservationIgnored private var themesByName: [String: ThemeInfo] = [:]

    /// Cached ThemeInfo for `currentTheme`. Updated when either the theme
    /// selection or the available themes change. This cache exists to avoid
    /// the O(n) scan + value-type copy that used to run in every body
    /// evaluation of MainView's tab bar.
    private(set) var currentThemeInfo: ThemeInfo?

    /// Currently selected theme name. `@Observable`'s synthesized accessors
    /// handle change notification — the previous manual `objectWillChange.send()`
    /// in `willSet` is no longer needed.
    var currentTheme: String {
        didSet {
            guard oldValue != currentTheme else { return }
            currentThemeInfo = themesByName[currentTheme]
            guard ProtectedDataGuard.isAvailable else { return }
            saveTheme()
            themeDidChange.send(currentTheme)
        }
    }

    /// Publisher that emits when theme changes
    @ObservationIgnored let themeDidChange = PassthroughSubject<String, Never>()

    private init() {
        // Load saved theme or default to Catppuccin Mocha
        if let savedTheme = UserDefaults.standard.string(forKey: Self.themeKey) {
            self.currentTheme = savedTheme
        } else {
            self.currentTheme = "Catppuccin Mocha"
        }

        // Load all themes from bundle
        loadThemes()
    }

    /// Save current theme to UserDefaults
    private func saveTheme() {
        UserDefaults.standard.set(currentTheme, forKey: Self.themeKey)
    }

    /// Apply the current theme to a Ghostty configuration
    /// - Parameter config: The configuration to apply the theme to
    /// - Returns: true if theme was applied successfully, false otherwise
    func applyTheme(to config: Ghostty.Config) -> Bool {
        return config.setTheme(currentTheme)
    }

    /// Get ThemeInfo for a specific theme name
    func themeInfo(for name: String) -> ThemeInfo? {
        return themesByName[name]
    }

    /// Reload all themes (built-in + custom). Called by CustomThemeManager after changes.
    func reloadThemes() {
        loadThemes()
    }

    // MARK: - Theme Loading

    private func loadThemes() {
        let fileManager = FileManager.default

        // Try multiple possible locations for themes directory
        let possiblePaths: [URL?] = [
            // Direct in bundle (based on Ghostty's log output)
            Bundle.main.bundleURL.appendingPathComponent("themes"),

            // In resources directory
            Bundle.main.resourceURL?.appendingPathComponent("themes"),

            // In Resources/ghostty subdirectory
            Bundle.main.resourceURL?
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("themes"),

            // In bundle root's Resources/ghostty
            Bundle.main.bundleURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("ghostty")
                .appendingPathComponent("themes")
        ]

        var themesURL: URL?
        for path in possiblePaths.compactMap({ $0 }) {
            Ghostty.logger.info("Checking for themes at: \(path.path)")
            if fileManager.fileExists(atPath: path.path) {
                themesURL = path
                Ghostty.logger.info("✓ Found themes directory at: \(path.path)")
                break
            }
        }

        guard let themesURL = themesURL else {
            Ghostty.logger.error("Failed to find themes directory in bundle. Checked paths:")
            for path in possiblePaths.compactMap({ $0 }) {
                Ghostty.logger.error("  - \(path.path)")
            }
            return
        }

        do {
            let themeFiles = try fileManager.contentsOfDirectory(
                at: themesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            Ghostty.logger.info("Found \(themeFiles.count) files in themes directory")

            var themes: [ThemeInfo] = []

            for fileURL in themeFiles {
                // Skip directories
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                // Use the file name as the theme name
                let themeName = fileURL.lastPathComponent

                // Parse the theme file to extract colors
                let colors = parseThemeFile(at: fileURL)

                let themeInfo = ThemeInfo(
                    name: themeName,
                    filePath: fileURL,
                    colors: colors
                )

                themes.append(themeInfo)
            }

            // Sort themes alphabetically by name
            themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // Merge custom themes
            let customThemes = CustomThemeManager.shared.customThemes.map { ThemeInfo(customTheme: $0) }
            // Remove any built-in themes that are shadowed by custom themes
            let customNames = Set(customThemes.map(\.name))
            themes = themes.filter { !customNames.contains($0.name) }
            themes.append(contentsOf: customThemes)

            // Sort themes alphabetically by name
            themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            self.availableThemes = themes

            // Rebuild name index and refresh the cached current theme info.
            var index: [String: ThemeInfo] = [:]
            index.reserveCapacity(themes.count)
            for theme in themes {
                index[theme.name] = theme
            }
            self.themesByName = index
            self.currentThemeInfo = index[currentTheme]

            // Group by family
            var grouped: [String: [ThemeInfo]] = [:]
            for theme in themes {
                grouped[theme.family, default: []].append(theme)
            }

            // Sort each family's themes alphabetically
            for (family, familyThemes) in grouped {
                grouped[family] = familyThemes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }

            self.themesByFamily = grouped

            let customCount = customThemes.count
            Ghostty.logger.info("Loaded \(themes.count) themes (\(customCount) custom) from \(grouped.count) families")

        } catch {
            Ghostty.logger.error("Failed to load themes: \(error)")
        }
    }

    private func parseThemeFile(at url: URL) -> ThemeInfo.ThemeColors {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            var background = "#1e1e2e"
            var foreground = "#cdd6f4"
            var cursor = "#f5e0dc"
            var palette: [String] = []
            var paletteEntries: [Int: String] = [:]

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines and comments
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                // Parse key = value (split on first "=" only to handle palette = 0=#hex)
                guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

                switch key {
                case "background":
                    background = value
                case "foreground":
                    foreground = value
                case "cursor-color":
                    cursor = value
                case "palette":
                    // Format: "N=#hex" e.g. "0=#45475a"
                    if let eqIdx = value.firstIndex(of: "=") {
                        let indexStr = value[value.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                        let hex = value[value.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                        if let index = Int(indexStr) {
                            paletteEntries[index] = hex
                        }
                    }
                default:
                    break
                }
            }

            // Convert palette dict to ordered array (ANSI 0-15)
            palette = (0..<16).compactMap { paletteEntries[$0] }

            // Resolve Ghostty keyword values (e.g. "cell-foreground") to concrete hex
            cursor = Color.resolveKeywordColor(cursor, foreground: foreground, background: background)

            return ThemeInfo.ThemeColors(
                background: background,
                foreground: foreground,
                cursor: cursor,
                palette: palette
            )

        } catch {
            Ghostty.logger.error("Failed to parse theme file \(url.lastPathComponent): \(error)")
            return .default
        }
    }
}
