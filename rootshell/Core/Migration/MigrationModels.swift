//
//  MigrationModels.swift
//  rootshell
//
//  Data types used by the Ghostty config migration flow: parsed entries,
//  preview/plan, post-apply summary, and shared color normalization.
//

import Foundation

/// One non-comment, non-blank line from a parsed Ghostty config file.
struct ParsedConfigEntry: Hashable {
    let key: String
    let value: String
    let sourceFile: URL
    let lineNumber: Int
}

enum MigrationCategory: String, CaseIterable, Hashable {
    case font
    case theme
    case cursor
    case selection
    case palette
    case transparency
    case behavior
    case keybind

    var displayName: String {
        switch self {
        case .font: return String(localized: "Font", comment: "Migration category")
        case .theme: return String(localized: "Theme", comment: "Migration category")
        case .cursor: return String(localized: "Cursor", comment: "Migration category")
        case .selection: return String(localized: "Selection", comment: "Migration category")
        case .palette: return String(localized: "Palette", comment: "Migration category")
        case .transparency: return String(localized: "Transparency", comment: "Migration category")
        case .behavior: return String(localized: "Behavior", comment: "Migration category")
        case .keybind: return String(localized: "Keybinds", comment: "Migration category")
        }
    }

    var sortOrder: Int {
        switch self {
        case .font: return 0
        case .theme: return 1
        case .palette: return 2
        case .cursor: return 3
        case .selection: return 4
        case .transparency: return 5
        case .behavior: return 6
        case .keybind: return 7
        }
    }
}

/// Typed payload describing what `apply(_:)` should actually do for a given
/// recognized change. Keeps the canonical value separate from the localized
/// `summary` string used by the preview UI, so apply never has to parse
/// display text.
enum RecognizedPayload: Hashable {
    case fontFamily(String)
    case fontSize(Double)
    case ligaturesEnabled(Bool)
    /// Per-family stylistic feature toggle (`+ss01`, `-zero`, `calt`).
    /// `family` is the font family that was set in the same config; required
    /// because rootshell stores feature prefs per-family.
    case fontFeatureTag(family: String, tag: String, enabled: Bool)

    case theme(name: String)
    case dayNightTheme(day: String, night: String)
    /// Marker — the actual values live in `MigrationPlan.customThemeFields`.
    case paletteAggregated
    case backgroundAggregated
    case foregroundAggregated

    case cursorStyle(CursorStyle)
    case cursorBlinkEnabled(Bool)
    case cursorBlinkMode(CursorBlinkMode)
    case cursorColor(String)        // "#RRGGBB"
    case cursorTextColor(String)    // "#RRGGBB"

    case selectionForegroundBareHex(String) // "rrggbb" (no leading #)
    case selectionBackgroundBareHex(String)

    case backgroundOpacity(Double)
    /// `nil` = blur off, `Double` = radius (Catalyst-only).
    case backgroundBlur(radius: Double?)

    case copyOnSelect(Bool)
    /// Stored verbatim in UserDefaults; rootshell expects `on`/`off`/`left`/`right`.
    case optionAsAlt(String)

    case keybindCount(Int)
}

/// One change recognized during preview, ready to be applied.
struct RecognizedChange: Hashable {
    let category: MigrationCategory
    /// Original ghostty key (e.g. "font-family"). Display-only.
    let key: String
    /// User-facing description for the preview row. Display-only.
    let summary: String
    /// Canonical typed value. `apply(_:)` switches on this — never on `summary`.
    let payload: RecognizedPayload
}

/// A key the importer chose not to apply, plus a one-line reason.
struct UnsupportedKey: Hashable {
    let key: String
    let reason: String
}

/// Aggregated result of parsing + resolving a Ghostty config file.
/// Built by `GhosttyConfigImporter.preview`, applied by `apply(_:)`.
struct MigrationPlan {
    let sourceURL: URL
    var recognized: [RecognizedChange] = []
    var unsupported: [UnsupportedKey] = []
    var warnings: [String] = []
    /// Aggregated palette/background/foreground/cursor entries that should be
    /// written to a custom theme on apply. Empty when the source file did not
    /// carry any standalone color overrides.
    var customThemeFields: CustomThemeFields = .init()
    /// Flattened keybind config text aggregated from the picked file plus
    /// every resolved `config-file = …` include. When non-nil, apply pipes
    /// this through `KeybindManager.importExternalConfig(content:originalFilename:)`
    /// so include-sourced keybinds aren't silently dropped (the picker URL on
    /// its own only carries the top-level file's keybinds).
    var keybindContent: String?
    /// Display filename associated with the picked file, retained for the
    /// "imported config" label in Keyboard Shortcuts.
    var keybindOriginalFilename: String?

    var groupedRecognized: [(MigrationCategory, [RecognizedChange])] {
        let grouped = Dictionary(grouping: recognized, by: { $0.category })
        return grouped.keys
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0, grouped[$0] ?? []) }
    }

    var hasAnythingToApply: Bool {
        !recognized.isEmpty
    }
}

/// Aggregated theme-color overrides found in the source config.
/// Each field is nil when not present; on apply, a CustomTheme is registered
/// only if at least one of these fields is set.
struct CustomThemeFields: Hashable {
    var background: String?
    var foreground: String?
    var cursorColor: String?
    var cursorText: String?
    var selectionBackground: String?
    var selectionForeground: String?
    var palette: [Int: String] = [:]

    var isEmpty: Bool {
        background == nil && foreground == nil && cursorColor == nil && cursorText == nil
            && selectionBackground == nil && selectionForeground == nil && palette.isEmpty
    }
}

/// Final result returned to the UI after `apply` finishes.
struct MigrationSummary {
    let appliedCount: Int
    let unsupportedCount: Int
    let warnings: [String]
    let registeredCustomThemeName: String?
    let keybindsImported: Bool
}

// MARK: - Color Normalization

enum ColorParser {
    /// Normalize a Ghostty color literal to a `#rrggbb` (uppercase) string,
    /// or nil if the input cannot be coerced.
    ///
    /// Accepts: `#rrggbb`, `0xrrggbb`, bare `rrggbb`, and a small set of
    /// X11 names that show up in stock Ghostty themes. Quoted values are
    /// unwrapped before parsing.
    static func normalize(_ raw: String) -> String? {
        let value = unquote(raw).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        // Hex variants
        var hex = value
        if hex.hasPrefix("#") { hex.removeFirst() }
        else if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }

        if hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) {
            return "#" + hex.uppercased()
        }
        if hex.count == 3, hex.allSatisfy({ $0.isHexDigit }) {
            // Expand short form #rgb -> #rrggbb
            let chars = Array(hex)
            return "#" + String([chars[0], chars[0], chars[1], chars[1], chars[2], chars[2]]).uppercased()
        }

        // Named color fallback (small set; full X11 isn't worth shipping)
        if let named = namedColors[value.lowercased()] {
            return named
        }

        return nil
    }

    /// Same as `normalize` but returns the hex without the leading `#`.
    /// Selection colors are stored without the prefix in rootshell.
    static func normalizeBare(_ raw: String) -> String? {
        guard let withHash = normalize(raw) else { return nil }
        return String(withHash.dropFirst())
    }

    private static func unquote(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// Tiny X11 subset — the names that appear in upstream Ghostty themes.
    private static let namedColors: [String: String] = [
        "black": "#000000",
        "white": "#FFFFFF",
        "red": "#FF0000",
        "green": "#00FF00",
        "blue": "#0000FF",
        "yellow": "#FFFF00",
        "magenta": "#FF00FF",
        "cyan": "#00FFFF",
        "navy": "#000080",
        "silver": "#C0C0C0",
        "gray": "#808080",
        "grey": "#808080",
        "maroon": "#800000",
        "olive": "#808000",
        "lime": "#00FF00",
        "teal": "#008080",
        "aqua": "#00FFFF",
        "purple": "#800080",
        "fuchsia": "#FF00FF",
    ]
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
