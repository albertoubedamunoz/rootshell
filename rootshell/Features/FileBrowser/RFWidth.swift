#if !targetEnvironment(macCatalyst)

import Foundation
import GhosttyKit

/// Display-cell width helpers for the `rf` TUI.
///
/// The cell grid is indexed in terminal display cells, not Swift Characters.
/// East-Asian-wide glyphs (CJK), most emoji, and emoji-presentation sequences
/// occupy 2 cells; combining marks occupy 0. We consult ghostty's own SIMD
/// width table (with a `wcwidth` fallback), so widths match exactly what
/// ghostty draws when hosting `rf`.
nonisolated enum RFWidth {
    /// Display-cell width of a single Unicode scalar (-1 null, 0 zero-width, 1+ cells).
    private static func scalarWidth(_ scalar: UInt32) -> Int {
        return Int(ghostty_simd_codepoint_width(scalar))
    }

    /// Display-cell width of a single grapheme cluster (1 normal, 2 wide).
    static func width(of char: Character) -> Int {
        var base = 0
        var hasVS16 = false
        for scalar in char.unicodeScalars {
            if scalar.value == 0xFE0F { hasVS16 = true; continue } // emoji presentation selector
            let w = scalarWidth(scalar.value)
            if w > 0 { base = max(base, w) }
        }
        if hasVS16 { return 2 }
        return max(base, 1) // a visible grapheme is at least 1 cell
    }

    /// Display-cell width of a string.
    static func width(of string: String) -> Int {
        var total = 0
        for ch in string { total += width(of: ch) }
        return total
    }

    /// `string` cut to `maxWidth` display cells, ending in "…" when shortened.
    static func truncate(_ string: String, to maxWidth: Int) -> String {
        guard width(of: string) > maxWidth else { return string }
        // Leave 1 cell for the ellipsis.
        var used = 0
        var truncated = ""
        for char in string {
            let w = width(of: char)
            if used + w > maxWidth - 1 { break }
            truncated.append(char)
            used += w
        }
        return truncated + "…"
    }
}

#endif
