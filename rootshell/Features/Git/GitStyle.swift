#if !targetEnvironment(macCatalyst)

import Foundation

/// Backward-compatible alias — all shared ANSI infrastructure lives in
/// `TerminalStyle`.  Git-specific colors and icons are added below.
typealias GitStyle = TerminalStyle

// MARK: - Git-specific palette

extension TerminalStyle {
    static let added       = Color(r: 80,  g: 200, b: 120)
    static let deleted     = Color(r: 240, g: 80,  b: 80)
    static let modified    = Color(r: 230, g: 180, b: 60)
    static let renamed     = Color(r: 130, g: 170, b: 255)
    static let headerColor = Color(r: 180, g: 140, b: 255)
    static let hash        = Color(r: 200, g: 160, b: 100)
    static let author      = Color(r: 100, g: 200, b: 200)
    static let dateColor   = Color(r: 140, g: 140, b: 160)
    static let branch      = Color(r: 100, g: 220, b: 100)
    static let tag         = Color(r: 240, g: 200, b: 80)
    static let remote      = Color(r: 240, g: 120, b: 120)
    // errorColor, warning, info, dimColor, success → already in TerminalStyle
    // as error, warning, info, dim, success respectively.

    /// Legacy aliases so existing `GitStyle.errorColor` / `.dimColor` still compile.
    static let errorColor = TerminalStyle.error
    static let dimColor   = TerminalStyle.dim
}

// MARK: - Git-specific Nerd Font icons

extension TerminalStyle {
    static let branchIcon    = "\u{e0a0}"   //  git branch
    static let tagIcon       = "\u{f412}"   //  tag
    static let commitIcon    = "\u{e729}"   //  git commit
    static let addedIcon     = "\u{f067}"   //  plus
    static let deletedIcon   = "\u{f068}"   //  minus
    static let modifiedIcon  = "\u{f040}"   //  pencil
    static let renamedIcon   = "\u{f064}"   //  arrow-right
    static let untrackedIcon = "\u{f128}"   //  question
    static let conflictIcon  = "\u{f071}"   //  warning triangle
    static let starIcon      = "\u{f005}"   //  star (HEAD)
}

#endif
