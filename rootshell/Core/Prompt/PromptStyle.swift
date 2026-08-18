#if !targetEnvironment(macCatalyst)
//
//  PromptStyle.swift
//  rootshell
//
//  Starship-style prompt generation for local shell
//

import Foundation

/// Available starship prompt themes
enum StarshipTheme: String, CaseIterable {
    case catppuccin
    case tokyoNight
    case pastelPowerline
    case gruvboxRainbow
    case dracula
    case nord
    case oneDark
    case solarizedDark
    case monokaiPro
    case kanagawaWave
    case rosePine
    case synthwave84
    case everforest

    var displayName: String {
        switch self {
        case .catppuccin: return String(localized: "Catppuccin Powerline")
        case .tokyoNight: return String(localized: "Tokyo Night")
        case .pastelPowerline: return String(localized: "Pastel Powerline")
        case .gruvboxRainbow: return String(localized: "Gruvbox Rainbow")
        case .dracula: return String(localized: "Dracula")
        case .nord: return String(localized: "Nord")
        case .oneDark: return String(localized: "One Dark")
        case .solarizedDark: return String(localized: "Solarized Dark")
        case .monokaiPro: return String(localized: "Monokai Pro")
        case .kanagawaWave: return String(localized: "Kanagawa Wave")
        case .rosePine: return String(localized: "Rosé Pine")
        case .synthwave84: return String(localized: "Synthwave '84")
        case .everforest: return String(localized: "Everforest")
        }
    }

}

/// Prompt styling utilities for local shell
struct PromptStyle {

    // MARK: - Catppuccin Mocha Palette

    private static let red = (r: 243, g: 139, b: 168)      // #f38ba8
    private static let peach = (r: 250, g: 179, b: 135)    // #fab387
    private static let lavender = (r: 180, g: 190, b: 254) // #b4befe
    private static let green = (r: 166, g: 227, b: 161)    // #a6e3a1
    private static let redError = (r: 243, g: 139, b: 168) // #f38ba8 (same as red)
    private static let crust = (r: 17, g: 17, b: 27)       // #11111b (text on segments)

    // MARK: - Tokyo Night Palette

    private static let tokyoLavender = (r: 163, g: 174, b: 210)  // #a3aed2 (first segment)
    private static let tokyoBlue = (r: 118, g: 159, b: 240)      // #769ff0 (directory segment)
    private static let tokyoDark = (r: 29, g: 34, b: 48)         // #1d2230 (time segment)
    private static let tokyoText = (r: 227, g: 229, b: 229)      // #e3e5e5 (light text)
    private static let tokyoMuted = (r: 160, g: 169, b: 203)     // #a0a9cb (time text)
    private static let tokyoCrust = (r: 9, g: 12, b: 12)         // #090c0c (dark text)
    private static let tokyoGreen = (r: 158, g: 206, b: 106)     // #9ece6a (success chevron)
    private static let tokyoRed = (r: 247, g: 118, b: 142)       // #f7768e (error chevron)

    // MARK: - Pastel Powerline Palette

    private static let pastelPurple = (r: 154, g: 52, b: 142)    // #9A348E (first segment)
    private static let pastelPink = (r: 218, g: 98, b: 125)      // #DA627D (directory segment)
    private static let pastelBlue = (r: 51, g: 101, b: 138)      // #33658A (time segment)
    private static let pastelWhite = (r: 255, g: 255, b: 255)    // #FFFFFF (text on segments)
    private static let pastelGreen = (r: 152, g: 195, b: 121)    // #98C379 (success - pastel green)
    private static let pastelRed = (r: 224, g: 108, b: 117)      // #E06C75 (error - pastel red)

    // MARK: - Gruvbox Rainbow Palette

    private static let gruvboxOrange = (r: 214, g: 93, b: 14)     // #d65d0e (first segment)
    private static let gruvboxYellow = (r: 215, g: 153, b: 33)    // #d79921 (directory segment)
    private static let gruvboxAqua = (r: 104, g: 157, b: 106)     // #689d6a (time segment)
    private static let gruvboxFg0 = (r: 251, g: 241, b: 199)      // #fbf1c7 (text on segments)
    private static let gruvboxGreen = (r: 152, g: 151, b: 26)     // #98971a (success chevron)
    private static let gruvboxRed = (r: 204, g: 36, b: 29)        // #cc241d (error chevron)

    // MARK: - Dracula Palette

    private static let draculaPurple = (r: 189, g: 147, b: 249)   // #bd93f9 (first segment)
    private static let draculaPink = (r: 255, g: 121, b: 198)     // #ff79c6 (directory segment)
    private static let draculaCyan = (r: 139, g: 233, b: 253)     // #8be9fd (time segment)
    private static let draculaBg = (r: 40, g: 42, b: 54)          // #282a36 (text on segments)
    private static let draculaGreen = (r: 80, g: 250, b: 123)     // #50fa7b (success chevron)
    private static let draculaRed = (r: 255, g: 85, b: 85)        // #ff5555 (error chevron)

    // MARK: - Nord Palette

    private static let nord10 = (r: 94, g: 129, b: 172)           // #5e81ac (first segment - deep frost)
    private static let nord9 = (r: 129, g: 161, b: 193)           // #81a1c1 (directory segment - medium frost)
    private static let nord7 = (r: 143, g: 188, b: 187)           // #8fbcbb (time segment - teal frost)
    private static let nord0 = (r: 46, g: 52, b: 64)              // #2e3440 (text on segments - polar night)
    private static let nord14 = (r: 163, g: 190, b: 140)          // #a3be8c (success chevron - aurora green)
    private static let nord11 = (r: 191, g: 97, b: 106)           // #bf616a (error chevron - aurora red)

    // MARK: - One Dark Palette

    private static let oneDarkBlue = (r: 97, g: 175, b: 239)      // #61afef (first segment)
    private static let oneDarkPurple = (r: 198, g: 120, b: 221)   // #c678dd (directory segment)
    private static let oneDarkCyan = (r: 86, g: 182, b: 194)      // #56b6c2 (time segment)
    private static let oneDarkBg = (r: 40, g: 44, b: 52)          // #282c34 (text on segments)
    private static let oneDarkGreen = (r: 152, g: 195, b: 121)    // #98c379 (success chevron)
    private static let oneDarkRed = (r: 224, g: 108, b: 117)      // #e06c75 (error chevron)

    // MARK: - Solarized Dark Palette

    private static let solarizedYellow = (r: 181, g: 137, b: 0)     // #b58900 (first segment)
    private static let solarizedCyan = (r: 42, g: 161, b: 152)      // #2aa198 (directory segment)
    private static let solarizedBlue = (r: 38, g: 139, b: 210)      // #268bd2 (time segment)
    private static let solarizedBase03 = (r: 0, g: 43, b: 54)       // #002b36 (text on segments)
    private static let solarizedGreen = (r: 133, g: 153, b: 0)      // #859900 (success chevron)
    private static let solarizedRed = (r: 220, g: 50, b: 47)        // #dc322f (error chevron)

    // MARK: - Monokai Pro Palette

    private static let monokaiRed = (r: 255, g: 97, b: 136)        // #ff6188 (first segment)
    private static let monokaiYellow = (r: 255, g: 216, b: 102)     // #ffd866 (directory segment)
    private static let monokaiCyan = (r: 120, g: 220, b: 232)       // #78dce8 (time segment)
    private static let monokaiBg = (r: 45, g: 42, b: 46)            // #2d2a2e (text on segments)
    private static let monokaiGreen = (r: 169, g: 220, b: 118)      // #a9dc76 (success chevron)
    // Error chevron reuses monokaiRed

    // MARK: - Kanagawa Wave Palette

    private static let kanagawaOrange = (r: 255, g: 160, b: 102)    // #FFA066 (first segment)
    private static let kanagawaGreen = (r: 152, g: 187, b: 108)     // #98BB6C (directory segment)
    private static let kanagawaBlue = (r: 126, g: 156, b: 216)      // #7E9CD8 (time segment)
    private static let kanagawaBg = (r: 31, g: 31, b: 40)           // #1F1F28 (text on segments)
    // Success chevron reuses kanagawaGreen
    private static let kanagawaRed = (r: 195, g: 64, b: 67)         // #C34043 (error chevron)

    // MARK: - Rosé Pine Palette

    private static let roseLove = (r: 235, g: 111, b: 146)          // #eb6f92 (first segment)
    private static let roseGold = (r: 246, g: 193, b: 119)          // #f6c177 (directory segment)
    private static let roseIris = (r: 196, g: 167, b: 231)          // #c4a7e7 (time segment)
    private static let roseBase = (r: 25, g: 23, b: 36)             // #191724 (text on segments)
    private static let roseFoam = (r: 156, g: 207, b: 216)          // #9ccfd8 (success chevron)
    // Error chevron reuses roseLove

    // MARK: - Synthwave '84 Palette

    private static let synthPink = (r: 246, g: 24, b: 143)          // #f6188f (first segment)
    private static let synthYellow = (r: 253, g: 248, b: 52)        // #fdf834 (directory segment)
    private static let synthCyan = (r: 18, g: 195, b: 226)          // #12c3e2 (time segment)
    private static let synthBlack = (r: 0, g: 0, b: 0)              // #000000 (text on segments)
    private static let synthGreen = (r: 30, g: 187, b: 43)          // #1ebb2b (success chevron)
    // Error chevron reuses synthPink

    // MARK: - Everforest Palette

    private static let everforestRed = (r: 230, g: 126, b: 128)     // #e67e80 (first segment)
    private static let everforestYellow = (r: 219, g: 188, b: 127)  // #dbbc7f (directory segment)
    private static let everforestGreen = (r: 167, g: 192, b: 128)   // #a7c080 (time segment)
    private static let everforestBg = (r: 30, g: 35, b: 38)         // #1e2326 (text on segments)
    // Success chevron reuses everforestGreen
    // Error chevron reuses everforestRed

    // MARK: - Git Segment Colors (per theme)

    private static let catppuccinGit = (r: 166, g: 227, b: 161)       // #a6e3a1 green
    private static let tokyoGit = (r: 158, g: 206, b: 106)            // #9ece6a aurora green
    private static let pastelGit = (r: 106, g: 135, b: 89)            // #6a8759 muted forest
    private static let gruvboxGit = (r: 152, g: 151, b: 26)           // #98971a gruvbox green
    private static let draculaGit = (r: 80, g: 250, b: 123)           // #50fa7b dracula green
    private static let nordGit = (r: 163, g: 190, b: 140)             // #a3be8c nord14
    private static let oneDarkGit = (r: 152, g: 195, b: 121)          // #98c379 one dark green
    private static let solarizedGit = (r: 133, g: 153, b: 0)          // #859900 solarized green
    private static let monokaiGit = (r: 169, g: 220, b: 118)          // #a9dc76 monokai green
    private static let kanagawaGit = (r: 118, g: 169, b: 76)          // #76a94c spring green
    private static let roseGit = (r: 49, g: 116, b: 143)              // #31748f pine blue
    private static let synthGit = (r: 30, g: 187, b: 43)              // #1ebb2b synth green
    private static let everforestGit = (r: 131, g: 165, b: 96)        // #83a560 aqua green

    /// Branch icon (Nerd Font)
    private static let branchIcon = "\u{e0a0}"

    // MARK: - Special Characters

    /// Powerline arrow (requires Nerd Font)
    private static let arrowRight = "\u{E0B0}"  //

    /// Powerline rounded left cap (requires Nerd Font)
    private static let roundedLeft = "\u{E0B6}"  //

    /// Powerline rounded right cap (requires Nerd Font)
    private static let roundedRight = "\u{E0B4}" //

    /// Clock icon (Nerd Font)
    private static let clockIcon = "\u{F017}"   //

    /// Heart icon (for Pastel Powerline)
    private static let heartIcon = "♥"

    /// Terminal icon (Nerd Font nf-fa-terminal, for Monokai Pro)
    private static let terminalIcon = "\u{F120}"

    /// Calendar icon (Nerd Font nf-fa-calendar, for Kanagawa Wave)
    private static let calendarIcon = "\u{F073}"

    /// Star icon (Nerd Font nf-fa-star, for Rosé Pine)
    private static let starIcon = "\u{F005}"

    /// Rocket icon (Nerd Font nf-fa-rocket, for Synthwave '84)
    private static let rocketIcon = "\u{F135}"

    /// Leaf icon (Nerd Font nf-fa-leaf, for Everforest)
    private static let leafIcon = "\u{F06C}"

    /// Success chevron
    private static let chevron = "❯"

    /// Futuristic angle bracket (for Synthwave '84)
    private static let angleBracket = "⟩"

    // MARK: - ANSI Escape Helpers

    /// ANSI escape sequence start
    static let esc = "\u{1b}"

    /// Set foreground color to RGB true color
    static func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(esc)[38;2;\(r);\(g);\(b)m"
    }

    /// Set background color to RGB true color
    static func bg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(esc)[48;2;\(r);\(g);\(b)m"
    }

    /// Reset all attributes
    static let ansiReset = "\u{1b}[0m"

    // Keep private alias for existing theme code
    private static var reset: String { ansiReset }

    // MARK: - Banner Accents

    /// Signature accent color for each theme — used by the local shell welcome
    /// banner so the greeting matches the user's prompt styling.
    static func bannerAccent(for theme: StarshipTheme) -> (r: Int, g: Int, b: Int) {
        switch theme {
        case .catppuccin:      return lavender
        case .tokyoNight:      return tokyoBlue
        case .pastelPowerline: return pastelPink
        case .gruvboxRainbow:  return gruvboxYellow
        case .dracula:         return draculaPurple
        case .nord:            return nord9
        case .oneDark:         return oneDarkBlue
        case .solarizedDark:   return solarizedBlue
        case .monokaiPro:      return monokaiYellow
        case .kanagawaWave:    return kanagawaBlue
        case .rosePine:        return roseIris
        case .synthwave84:     return synthPink
        case .everforest:      return everforestGreen
        }
    }

    /// Neutral muted color that reads on every supported theme's dark background.
    /// Catppuccin Mocha `overlay1` (#7f849c).
    static let bannerDim: (r: Int, g: Int, b: Int) = (127, 132, 156)

    // MARK: - Data Helpers

    /// Get current username
    static func username() -> String {
        UserPreferences.effectiveUsername
    }

    /// Get shortened directory path with ~ substitution and truncation
    static func shortenedPath(directory: String) -> String {
        // Standardize paths to resolve symlinks (/var vs /private/var)
        let path = (directory as NSString).standardizingPath

        // Use Documents directory as HOME (same as LocalShellSession sets for ios_system)
        let homeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = (homeURL.path as NSString).standardizingPath

        // Replace home directory with ~
        var displayPath = path
        if path.hasPrefix(home) {
            let remainder = String(path.dropFirst(home.count))
            displayPath = remainder.isEmpty ? "~" : "~" + remainder
        }

        // Truncate to last 3 components if needed
        let components = displayPath.split(separator: "/", omittingEmptySubsequences: false)
        if components.count > 3 {
            let lastThree = components.suffix(3)
            displayPath = "…/" + lastThree.joined(separator: "/")
        }

        return displayPath.isEmpty ? "~" : displayPath
    }

    /// Get current time formatted per user preference
    static func currentTime() -> String {
        UserPreferences.formattedTime()
    }

    /// Get abbreviated day of week (Mon, Tue, etc.)
    static func dayOfWeek() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: Date())
    }

    // MARK: - Public Accessors for Custom Prompt Evaluator

    /// Username accessor for evaluator
    static func promptUsername() -> String { username() }

    /// Shortened path with custom truncation for evaluator
    static func promptShortenedPath(directory: String, truncationLength: Int = 3, truncationSymbol: String = "…/") -> String {
        let path = (directory as NSString).standardizingPath
        let homeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = (homeURL.path as NSString).standardizingPath

        var displayPath = path
        if path.hasPrefix(home) {
            let remainder = String(path.dropFirst(home.count))
            displayPath = remainder.isEmpty ? "~" : "~" + remainder
        }

        if truncationLength > 0 {
            let components = displayPath.split(separator: "/", omittingEmptySubsequences: false)
            if components.count > truncationLength {
                let lastN = components.suffix(truncationLength)
                displayPath = truncationSymbol + lastN.joined(separator: "/")
            }
        }

        return displayPath.isEmpty ? "~" : displayPath
    }

    /// Time accessor for evaluator
    static func promptCurrentTime() -> String { currentTime() }

    /// Strip ANSI escape sequences from text for visible width calculation
    static func stripANSI(_ text: String) -> String {
        // Remove all ANSI escape sequences: ESC[ ... m, ESC[ ... A/B/C/D/H/J/K, etc.
        var result = ""
        var inEscape = false
        var chars = text.makeIterator()

        while let ch = chars.next() {
            if ch == "\u{1b}" {
                inEscape = true
                continue
            }
            if inEscape {
                // CSI sequences end with a letter
                if ch == "[" {
                    // Consume until we hit a letter (terminator)
                    while let next = chars.next() {
                        if next.isLetter || next == "m" { break }
                    }
                } else {
                    // Non-CSI escape (e.g. ESC O ...) — consume one more char
                    _ = chars.next()
                }
                inEscape = false
                continue
            }
            result.append(ch)
        }

        return result
    }

    // MARK: - Width-Aware Content Fitting

    /// Pre-truncated prompt content that theme functions consume
    struct PromptContent {
        let username: String
        let path: String          // Already width-truncated
        let time: String
        let gitBranch: String?    // nil = hide git segment entirely
        let gitSummary: String    // "" if no git
    }

    /// Whether the theme uses a 3-char gradient cap (░▒▓) vs 1-char rounded cap
    private static func themeUsesGradientCap(_ theme: StarshipTheme) -> Bool {
        theme == .tokyoNight || theme == .synthwave84
    }

    /// Whether the theme shows username in segment 1
    private static func themeShowsUsername(_ theme: StarshipTheme) -> Bool {
        switch theme {
        case .tokyoNight, .pastelPowerline, .rosePine: return false
        default: return true
        }
    }

    /// Truncate a display path to fit within `maxWidth` visible characters.
    /// Removes leading path components progressively, replacing with "…/".
    private static func truncatePath(_ path: String, toWidth maxWidth: Int) -> String {
        guard path.count > maxWidth, maxWidth >= 1 else { return path }
        if maxWidth <= 2 { return String(path.suffix(maxWidth)) }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        // Try progressively fewer components
        for drop in 1..<components.count {
            let kept = components.suffix(components.count - drop)
            let candidate = "…/" + kept.joined(separator: "/")
            if candidate.count <= maxWidth { return candidate }
        }
        // Last resort: just the last component, possibly truncated
        let last = String(components.last ?? Substring(path))
        if last.count <= maxWidth { return last }
        return String(last.prefix(maxWidth - 1)) + "…"
    }

    /// Truncate a git branch name to fit within `maxWidth`, appending "…".
    private static func truncateBranch(_ branch: String, toWidth maxWidth: Int) -> String {
        guard branch.count > maxWidth, maxWidth >= 2 else { return branch }
        return String(branch.prefix(maxWidth - 1)) + "…"
    }

    /// Compute pre-truncated prompt content that fits within terminal columns.
    /// Truncation priority: path first, then git branch, then hide git entirely.
    static func fitContent(
        columns: Int,
        theme: StarshipTheme,
        directory: String,
        gitInfo: PromptGitInfo?,
        showTime: Bool = true
    ) -> PromptContent {
        let user = username()
        let time = showTime ? ((theme == .kanagawaWave) ? dayOfWeek() : currentTime()) : ""
        let fullPath = shortenedPath(directory: directory)

        // For very narrow terminals, skip truncation logic
        guard columns >= 20 else {
            return PromptContent(
                username: user, path: fullPath, time: time,
                gitBranch: gitInfo?.branchName, gitSummary: gitInfo?.formattedSummary() ?? "")
        }

        // Calculate fixed overhead (everything except path text and git branch+summary text)
        let leftCapWidth = themeUsesGradientCap(theme) ? 3 : 1
        let seg1Width = themeShowsUsername(theme) ? (user.count + 4) : 3
        // leftCap + seg1 + arrow(seg1→seg2) + pathPadding(2 spaces) + timeSegment(icon+time+3spaces) + rightCap
        let timeWidth = showTime ? (time.count + 4) : 0  // " icon time " or nothing
        let fixedBase = leftCapWidth + seg1Width + 1 + 2 + timeWidth + 1

        if let git = gitInfo {
            let branch = git.branchName
            let summary = git.formattedSummary()
            // Git overhead: arrow(dir→git) + " icon " + branch + summary + " " + arrow(git→time)
            let gitOverhead = 1 + 3 + 1 + 1  // arrows(2) + space-icon-space(3) + trailing-space(1) = 7
            let totalWithGit = fixedBase + fullPath.count + gitOverhead + branch.count + summary.count

            if totalWithGit <= columns {
                // Everything fits
                return PromptContent(
                    username: user, path: fullPath, time: time,
                    gitBranch: branch, gitSummary: summary)
            }

            // Level 1: Truncate path, keep full git
            let availForPath = columns - fixedBase - gitOverhead - branch.count - summary.count
            if availForPath >= 4 {
                let truncPath = truncatePath(fullPath, toWidth: availForPath)
                return PromptContent(
                    username: user, path: truncPath, time: time,
                    gitBranch: branch, gitSummary: summary)
            }

            // Level 2: Truncate both path and branch
            // Give path a minimum of 4 chars, allocate rest to branch
            let availForBoth = columns - fixedBase - gitOverhead - summary.count
            if availForBoth >= 7 {  // at least 4 for path + 3 for branch
                let pathBudget = max(4, availForBoth * 2 / 3)
                let branchBudget = availForBoth - pathBudget
                if branchBudget >= 3 {
                    let truncPath = truncatePath(fullPath, toWidth: pathBudget)
                    let truncBranch = truncateBranch(branch, toWidth: branchBudget)
                    return PromptContent(
                        username: user, path: truncPath, time: time,
                        gitBranch: truncBranch, gitSummary: summary)
                }
            }

            // Level 3: Drop git entirely
            // Without git: single arrow transition (1 char) instead of git segment
            let noGitTotal = fixedBase + 1 + fullPath.count
            if noGitTotal <= columns {
                return PromptContent(
                    username: user, path: fullPath, time: time,
                    gitBranch: nil, gitSummary: "")
            }
            let availPathNoGit = columns - fixedBase - 1
            let finalPath = truncatePath(fullPath, toWidth: max(1, availPathNoGit))
            return PromptContent(
                username: user, path: finalPath, time: time,
                gitBranch: nil, gitSummary: "")
        }

        // No git info — just fit path
        let noGitTotal = fixedBase + 1 + fullPath.count  // +1 for single transition arrow
        if noGitTotal <= columns {
            return PromptContent(
                username: user, path: fullPath, time: time,
                gitBranch: nil, gitSummary: "")
        }
        let availForPath = columns - fixedBase - 1
        let fittedPath = truncatePath(fullPath, toWidth: max(1, availForPath))
        return PromptContent(
            username: user, path: fittedPath, time: time,
            gitBranch: nil, gitSummary: "")
    }

    // MARK: - Prompt Generation

    /// Result of prompt generation
    struct PromptResult {
        /// The full prompt text with ANSI escape codes
        let text: String
        /// Visible width of the second line prefix (for cursor positioning)
        let secondLinePrefix: Int
        /// Right-aligned prompt ANSI text (empty = no right prompt)
        var rightPromptText: String = ""
        /// Visible width of the right prompt (for cursor positioning)
        var rightPromptWidth: Int = 0
        /// Number of visible lines in the info bar (above the input line)
        var infoLineCount: Int = 1
    }

    /// Generate Starship-style two-line prompt
    /// - Parameters:
    ///   - lastCommandSucceeded: Whether the last command succeeded (affects chevron color)
    ///   - theme: The visual theme to use for the prompt
    ///   - directory: The session's current working directory (avoids reading process-global CWD)
    ///   - gitInfo: Optional git repository state for git segment display
    ///   - columns: Terminal width in columns (used to truncate segments to prevent wrapping)
    /// - Returns: PromptResult with text and cursor positioning info
    static func starship(lastCommandSucceeded: Bool = true, theme: StarshipTheme = .catppuccin, directory: String, gitInfo: PromptGitInfo? = nil, columns: Int = 80, showTime: Bool = true) -> PromptResult {
        let content = fitContent(columns: columns, theme: theme, directory: directory, gitInfo: gitInfo, showTime: showTime)
        let effectiveGit = content.gitBranch != nil ? gitInfo : nil
        switch theme {
        case .catppuccin:
            return starshipCatppuccin(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .tokyoNight:
            return starshipTokyoNight(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .pastelPowerline:
            return starshipPastelPowerline(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .gruvboxRainbow:
            return starshipGruvboxRainbow(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .dracula:
            return starshipDracula(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .nord:
            return starshipNord(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .oneDark:
            return starshipOneDark(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .solarizedDark:
            return starshipSolarizedDark(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .monokaiPro:
            return starshipMonokaiPro(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .kanagawaWave:
            return starshipKanagawaWave(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .rosePine:
            return starshipRosePine(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .synthwave84:
            return starshipSynthwave84(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        case .everforest:
            return starshipEverforest(lastCommandSucceeded: lastCommandSucceeded, content: content, gitInfo: effectiveGit, showTime: showTime)
        }
    }

    /// Generate a themed right-prompt segment (time in theme colors with Powerline caps)
    static func starshipRightPrompt(theme: StarshipTheme, directory: String) -> (text: String, visibleWidth: Int) {
        let time = (theme == .kanagawaWave) ? dayOfWeek() : currentTime()
        let icon = (theme == .kanagawaWave) ? calendarIcon : (theme == .pastelPowerline ? heartIcon : clockIcon)
        let colors = themeTimeColors(theme)

        var text = ""
        text += fg(colors.bg.r, colors.bg.g, colors.bg.b)
        text += roundedLeft
        text += fg(colors.fg.r, colors.fg.g, colors.fg.b)
        text += bg(colors.bg.r, colors.bg.g, colors.bg.b)
        text += " \(icon) \(time) "
        text += reset
        text += fg(colors.bg.r, colors.bg.g, colors.bg.b)
        text += roundedRight
        text += reset

        // visible: roundedLeft(1) + " icon time "(1+1+1+time+1) + roundedRight(1)
        let visibleWidth = 1 + 4 + time.count + 1
        return (text, visibleWidth)
    }

    /// Returns (foreground, background) colors for the time segment of each theme
    private static func themeTimeColors(_ theme: StarshipTheme) -> (fg: (r: Int, g: Int, b: Int), bg: (r: Int, g: Int, b: Int)) {
        switch theme {
        case .catppuccin: return (crust, lavender)
        case .tokyoNight: return (tokyoMuted, tokyoDark)
        case .pastelPowerline: return (pastelWhite, pastelBlue)
        case .gruvboxRainbow: return (gruvboxFg0, gruvboxAqua)
        case .dracula: return (draculaBg, draculaCyan)
        case .nord: return (nord0, nord7)
        case .oneDark: return (oneDarkBg, oneDarkCyan)
        case .solarizedDark: return (solarizedBase03, solarizedBlue)
        case .monokaiPro: return (monokaiBg, monokaiCyan)
        case .kanagawaWave: return (kanagawaBg, kanagawaBlue)
        case .rosePine: return (roseBase, roseIris)
        case .synthwave84: return (synthBlack, synthCyan)
        case .everforest: return (everforestBg, everforestGreen)
        }
    }

    /// Render the git segment between directory and time segments.
    /// - Parameters:
    ///   - prompt: The prompt string being built (mutated in place)
    ///   - gitInfo: Git repo state (if nil, no segment is rendered)
    ///   - branchText: Pre-truncated branch name (overrides gitInfo.branchName when provided)
    ///   - summaryText: Pre-truncated summary (overrides gitInfo.formattedSummary() when provided)
    ///   - prevColor: Background color of the previous segment (directory)
    ///   - gitColor: Background color for the git segment
    ///   - textColor: Foreground text color on the git segment
    ///   - nextColor: Background color of the next segment (time)
    /// - Returns: The actual background color to use as "previous" for the next segment transition
    @discardableResult
    private static func renderGitSegment(
        prompt: inout String,
        gitInfo: PromptGitInfo?,
        branchText: String? = nil,
        summaryText: String? = nil,
        prevColor: (r: Int, g: Int, b: Int),
        gitColor: (r: Int, g: Int, b: Int),
        textColor: (r: Int, g: Int, b: Int),
        nextColor: (r: Int, g: Int, b: Int),
        isLastSegment: Bool = false
    ) -> (r: Int, g: Int, b: Int) {
        guard let git = gitInfo else {
            if isLastSegment {
                // No git, no next segment — close bar with rounded cap
                prompt += reset
                prompt += fg(prevColor.r, prevColor.g, prevColor.b)
                prompt += roundedRight
                prompt += reset
            } else {
                // No git info — transition directly from prev to next
                prompt += fg(prevColor.r, prevColor.g, prevColor.b)
                prompt += bg(nextColor.r, nextColor.g, nextColor.b)
                prompt += arrowRight
            }
            return prevColor
        }

        let branch = branchText ?? git.branchName
        let summary = summaryText ?? git.formattedSummary()

        // Transition: prev → git
        prompt += fg(prevColor.r, prevColor.g, prevColor.b)
        prompt += bg(gitColor.r, gitColor.g, gitColor.b)
        prompt += arrowRight

        // Git content
        prompt += fg(textColor.r, textColor.g, textColor.b)
        prompt += bg(gitColor.r, gitColor.g, gitColor.b)
        prompt += " \(branchIcon) \(branch)\(summary) "

        if isLastSegment {
            // Git is the last segment — close bar with rounded cap
            prompt += reset
            prompt += fg(gitColor.r, gitColor.g, gitColor.b)
            prompt += roundedRight
            prompt += reset
        } else {
            // Transition: git → next
            prompt += fg(gitColor.r, gitColor.g, gitColor.b)
            prompt += bg(nextColor.r, nextColor.g, nextColor.b)
            prompt += arrowRight
        }

        return gitColor
    }

    /// Catppuccin Powerline theme prompt
    private static func starshipCatppuccin(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Line 1: Segments
        // [rounded-left] [red bg] OS+user [red→peach] dir [peach→git?→lavender] time [lavender→reset]

        // Rounded left cap: red foreground on default background
        prompt += fg(red.r, red.g, red.b)
        prompt += roundedLeft

        // Segment 1: OS icon + username (red background, crust text)
        prompt += fg(crust.r, crust.g, crust.b)
        prompt += bg(red.r, red.g, red.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: red fg on peach bg
        prompt += fg(red.r, red.g, red.b)
        prompt += bg(peach.r, peach.g, peach.b)
        prompt += arrowRight

        // Segment 2: Directory (peach background, crust text)
        prompt += fg(crust.r, crust.g, crust.b)
        prompt += bg(peach.r, peach.g, peach.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: peach, gitColor: catppuccinGit, textColor: crust, nextColor: lavender,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (lavender background, crust text)
            prompt += fg(crust.r, crust.g, crust.b)
            prompt += bg(lavender.r, lavender.g, lavender.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap: lavender fg on default bg
            prompt += reset
            prompt += fg(lavender.r, lavender.g, lavender.b)
            prompt += roundedRight
            prompt += reset
        }

        // Line break (CRLF to ensure cursor goes to column 1)
        prompt += "\r\n"

        // Line 2: Chevron (green for success, red for error)
        let chevronColor = lastCommandSucceeded ? green : redError
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        // Second line visible prefix is "❯ " = 2 characters
        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Tokyo Night theme prompt
    private static func starshipTokyoNight(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Line 1: Segments with Tokyo Night gradient style
        // [░▒▓] [lavender bg] OS [→] [blue bg] dir [→git?→] [dark bg] time [ ]

        // Gradient left cap: lavender foreground on default background
        prompt += fg(tokyoLavender.r, tokyoLavender.g, tokyoLavender.b)
        prompt += "░▒▓"

        // Segment 1: OS icon (lavender background, dark text)
        prompt += fg(tokyoCrust.r, tokyoCrust.g, tokyoCrust.b)
        prompt += bg(tokyoLavender.r, tokyoLavender.g, tokyoLavender.b)
        prompt += " \(starIcon) "

        // Transition arrow: lavender fg on blue bg
        prompt += fg(tokyoLavender.r, tokyoLavender.g, tokyoLavender.b)
        prompt += bg(tokyoBlue.r, tokyoBlue.g, tokyoBlue.b)
        prompt += arrowRight

        // Segment 2: Directory (blue background, light text)
        prompt += fg(tokyoText.r, tokyoText.g, tokyoText.b)
        prompt += bg(tokyoBlue.r, tokyoBlue.g, tokyoBlue.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: tokyoBlue, gitColor: tokyoGit, textColor: tokyoCrust, nextColor: tokyoDark,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (dark background, muted text)
            prompt += fg(tokyoMuted.r, tokyoMuted.g, tokyoMuted.b)
            prompt += bg(tokyoDark.r, tokyoDark.g, tokyoDark.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final fade cap: dark fg on default bg
            prompt += reset
            prompt += fg(tokyoDark.r, tokyoDark.g, tokyoDark.b)
            prompt += roundedRight
            prompt += reset
        }

        // Line break (CRLF to ensure cursor goes to column 1)
        prompt += "\r\n"

        // Line 2: Chevron (Tokyo Night green for success, red for error)
        let chevronColor = lastCommandSucceeded ? tokyoGreen : tokyoRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        // Second line visible prefix is "❯ " = 2 characters
        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Pastel Powerline theme prompt
    private static func starshipPastelPowerline(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Line 1: Segments with Pastel Powerline style
        // [rounded-left] [purple bg] OS [→] [pink bg] dir [→git?→] [blue bg] ♥ time [rounded-right]

        // Rounded left cap: purple foreground on default background
        prompt += fg(pastelPurple.r, pastelPurple.g, pastelPurple.b)
        prompt += roundedLeft

        // Segment 1: OS icon (purple background, white text)
        prompt += fg(pastelWhite.r, pastelWhite.g, pastelWhite.b)
        prompt += bg(pastelPurple.r, pastelPurple.g, pastelPurple.b)
        prompt += " \(starIcon) "

        // Transition arrow: purple fg on pink bg
        prompt += fg(pastelPurple.r, pastelPurple.g, pastelPurple.b)
        prompt += bg(pastelPink.r, pastelPink.g, pastelPink.b)
        prompt += arrowRight

        // Segment 2: Directory (pink background, white text)
        prompt += fg(pastelWhite.r, pastelWhite.g, pastelWhite.b)
        prompt += bg(pastelPink.r, pastelPink.g, pastelPink.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: pastelPink, gitColor: pastelGit, textColor: pastelWhite, nextColor: pastelBlue,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time with heart (blue background, white text)
            prompt += fg(pastelWhite.r, pastelWhite.g, pastelWhite.b)
            prompt += bg(pastelBlue.r, pastelBlue.g, pastelBlue.b)
            prompt += " \(heartIcon) \(content.time) "

            // Final rounded cap: blue fg on default bg
            prompt += reset
            prompt += fg(pastelBlue.r, pastelBlue.g, pastelBlue.b)
            prompt += roundedRight
            prompt += reset
        }

        // Line break (CRLF to ensure cursor goes to column 1)
        prompt += "\r\n"

        // Line 2: Chevron (light blue for success, pink for error)
        let chevronColor = lastCommandSucceeded ? pastelGreen : pastelRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        // Second line visible prefix is "❯ " = 2 characters
        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Gruvbox Rainbow theme prompt
    private static func starshipGruvboxRainbow(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap: orange foreground on default background
        prompt += fg(gruvboxOrange.r, gruvboxOrange.g, gruvboxOrange.b)
        prompt += roundedLeft

        // Segment 1: OS icon + username (orange background, cream text)
        prompt += fg(gruvboxFg0.r, gruvboxFg0.g, gruvboxFg0.b)
        prompt += bg(gruvboxOrange.r, gruvboxOrange.g, gruvboxOrange.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: orange fg on yellow bg
        prompt += fg(gruvboxOrange.r, gruvboxOrange.g, gruvboxOrange.b)
        prompt += bg(gruvboxYellow.r, gruvboxYellow.g, gruvboxYellow.b)
        prompt += arrowRight

        // Segment 2: Directory (yellow background, cream text)
        prompt += fg(gruvboxFg0.r, gruvboxFg0.g, gruvboxFg0.b)
        prompt += bg(gruvboxYellow.r, gruvboxYellow.g, gruvboxYellow.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: gruvboxYellow, gitColor: gruvboxGit, textColor: gruvboxFg0, nextColor: gruvboxAqua,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (aqua background, cream text)
            prompt += fg(gruvboxFg0.r, gruvboxFg0.g, gruvboxFg0.b)
            prompt += bg(gruvboxAqua.r, gruvboxAqua.g, gruvboxAqua.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap: aqua fg on default bg
            prompt += reset
            prompt += fg(gruvboxAqua.r, gruvboxAqua.g, gruvboxAqua.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? gruvboxGreen : gruvboxRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Dracula theme prompt
    private static func starshipDracula(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap: purple foreground on default background
        prompt += fg(draculaPurple.r, draculaPurple.g, draculaPurple.b)
        prompt += roundedLeft

        // Segment 1: OS icon + username (purple background, dark text)
        prompt += fg(draculaBg.r, draculaBg.g, draculaBg.b)
        prompt += bg(draculaPurple.r, draculaPurple.g, draculaPurple.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: purple fg on pink bg
        prompt += fg(draculaPurple.r, draculaPurple.g, draculaPurple.b)
        prompt += bg(draculaPink.r, draculaPink.g, draculaPink.b)
        prompt += arrowRight

        // Segment 2: Directory (pink background, dark text)
        prompt += fg(draculaBg.r, draculaBg.g, draculaBg.b)
        prompt += bg(draculaPink.r, draculaPink.g, draculaPink.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: draculaPink, gitColor: draculaGit, textColor: draculaBg, nextColor: draculaCyan,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (cyan background, dark text)
            prompt += fg(draculaBg.r, draculaBg.g, draculaBg.b)
            prompt += bg(draculaCyan.r, draculaCyan.g, draculaCyan.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap: cyan fg on default bg
            prompt += reset
            prompt += fg(draculaCyan.r, draculaCyan.g, draculaCyan.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? draculaGreen : draculaRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Nord theme prompt
    private static func starshipNord(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap: deep frost foreground on default background
        prompt += fg(nord10.r, nord10.g, nord10.b)
        prompt += roundedLeft

        // Segment 1: OS icon + username (deep frost background, polar night text)
        prompt += fg(nord0.r, nord0.g, nord0.b)
        prompt += bg(nord10.r, nord10.g, nord10.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: deep frost fg on medium frost bg
        prompt += fg(nord10.r, nord10.g, nord10.b)
        prompt += bg(nord9.r, nord9.g, nord9.b)
        prompt += arrowRight

        // Segment 2: Directory (medium frost background, polar night text)
        prompt += fg(nord0.r, nord0.g, nord0.b)
        prompt += bg(nord9.r, nord9.g, nord9.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: nord9, gitColor: nordGit, textColor: nord0, nextColor: nord7,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (teal frost background, polar night text)
            prompt += fg(nord0.r, nord0.g, nord0.b)
            prompt += bg(nord7.r, nord7.g, nord7.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap: teal frost fg on default bg
            prompt += reset
            prompt += fg(nord7.r, nord7.g, nord7.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? nord14 : nord11
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// One Dark theme prompt
    private static func starshipOneDark(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap: blue foreground on default background
        prompt += fg(oneDarkBlue.r, oneDarkBlue.g, oneDarkBlue.b)
        prompt += roundedLeft

        // Segment 1: OS icon + username (blue background, dark text)
        prompt += fg(oneDarkBg.r, oneDarkBg.g, oneDarkBg.b)
        prompt += bg(oneDarkBlue.r, oneDarkBlue.g, oneDarkBlue.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: blue fg on purple bg
        prompt += fg(oneDarkBlue.r, oneDarkBlue.g, oneDarkBlue.b)
        prompt += bg(oneDarkPurple.r, oneDarkPurple.g, oneDarkPurple.b)
        prompt += arrowRight

        // Segment 2: Directory (purple background, dark text)
        prompt += fg(oneDarkBg.r, oneDarkBg.g, oneDarkBg.b)
        prompt += bg(oneDarkPurple.r, oneDarkPurple.g, oneDarkPurple.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: oneDarkPurple, gitColor: oneDarkGit, textColor: oneDarkBg, nextColor: oneDarkCyan,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Time (cyan background, dark text)
            prompt += fg(oneDarkBg.r, oneDarkBg.g, oneDarkBg.b)
            prompt += bg(oneDarkCyan.r, oneDarkCyan.g, oneDarkCyan.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap: cyan fg on default bg
            prompt += reset
            prompt += fg(oneDarkCyan.r, oneDarkCyan.g, oneDarkCyan.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? oneDarkGreen : oneDarkRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Solarized Dark theme prompt — classic, professional
    private static func starshipSolarizedDark(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap
        prompt += fg(solarizedYellow.r, solarizedYellow.g, solarizedYellow.b)
        prompt += roundedLeft

        // Segment 1: Apple icon + username (yellow background, base03 text)
        prompt += fg(solarizedBase03.r, solarizedBase03.g, solarizedBase03.b)
        prompt += bg(solarizedYellow.r, solarizedYellow.g, solarizedYellow.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: yellow fg on cyan bg
        prompt += fg(solarizedYellow.r, solarizedYellow.g, solarizedYellow.b)
        prompt += bg(solarizedCyan.r, solarizedCyan.g, solarizedCyan.b)
        prompt += arrowRight

        // Segment 2: Directory (cyan background, base03 text)
        prompt += fg(solarizedBase03.r, solarizedBase03.g, solarizedBase03.b)
        prompt += bg(solarizedCyan.r, solarizedCyan.g, solarizedCyan.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: solarizedCyan, gitColor: solarizedGit, textColor: solarizedBase03, nextColor: solarizedBlue,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Clock + time (blue background, base03 text)
            prompt += fg(solarizedBase03.r, solarizedBase03.g, solarizedBase03.b)
            prompt += bg(solarizedBlue.r, solarizedBlue.g, solarizedBlue.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(solarizedBlue.r, solarizedBlue.g, solarizedBlue.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? solarizedGreen : solarizedRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Monokai Pro theme prompt — developer-focused with terminal icon
    private static func starshipMonokaiPro(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap
        prompt += fg(monokaiRed.r, monokaiRed.g, monokaiRed.b)
        prompt += roundedLeft

        // Segment 1: Terminal icon + username (red background, dark text)
        prompt += fg(monokaiBg.r, monokaiBg.g, monokaiBg.b)
        prompt += bg(monokaiRed.r, monokaiRed.g, monokaiRed.b)
        prompt += " \(terminalIcon) \(content.username) "

        // Transition arrow: red fg on yellow bg
        prompt += fg(monokaiRed.r, monokaiRed.g, monokaiRed.b)
        prompt += bg(monokaiYellow.r, monokaiYellow.g, monokaiYellow.b)
        prompt += arrowRight

        // Segment 2: Directory (yellow background, dark text)
        prompt += fg(monokaiBg.r, monokaiBg.g, monokaiBg.b)
        prompt += bg(monokaiYellow.r, monokaiYellow.g, monokaiYellow.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: monokaiYellow, gitColor: monokaiGit, textColor: monokaiBg, nextColor: monokaiCyan,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Clock + time (cyan background, dark text)
            prompt += fg(monokaiBg.r, monokaiBg.g, monokaiBg.b)
            prompt += bg(monokaiCyan.r, monokaiCyan.g, monokaiCyan.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(monokaiCyan.r, monokaiCyan.g, monokaiCyan.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? monokaiGreen : monokaiRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Kanagawa Wave theme prompt — shows day of week instead of time
    private static func starshipKanagawaWave(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap
        prompt += fg(kanagawaOrange.r, kanagawaOrange.g, kanagawaOrange.b)
        prompt += roundedLeft

        // Segment 1: Apple icon + username (orange background, dark text)
        prompt += fg(kanagawaBg.r, kanagawaBg.g, kanagawaBg.b)
        prompt += bg(kanagawaOrange.r, kanagawaOrange.g, kanagawaOrange.b)
        prompt += " \(starIcon) \(content.username) "

        // Transition arrow: orange fg on green bg
        prompt += fg(kanagawaOrange.r, kanagawaOrange.g, kanagawaOrange.b)
        prompt += bg(kanagawaGreen.r, kanagawaGreen.g, kanagawaGreen.b)
        prompt += arrowRight

        // Segment 2: Directory (green background, dark text)
        prompt += fg(kanagawaBg.r, kanagawaBg.g, kanagawaBg.b)
        prompt += bg(kanagawaGreen.r, kanagawaGreen.g, kanagawaGreen.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: kanagawaGreen, gitColor: kanagawaGit, textColor: kanagawaBg, nextColor: kanagawaBlue,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Calendar icon + day of week (blue background, dark text)
            prompt += fg(kanagawaBg.r, kanagawaBg.g, kanagawaBg.b)
            prompt += bg(kanagawaBlue.r, kanagawaBlue.g, kanagawaBlue.b)
            prompt += " \(calendarIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(kanagawaBlue.r, kanagawaBlue.g, kanagawaBlue.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? kanagawaGreen : kanagawaRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Rosé Pine theme prompt — minimal, dreamy (star icon, no username)
    private static func starshipRosePine(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap
        prompt += fg(roseLove.r, roseLove.g, roseLove.b)
        prompt += roundedLeft

        // Segment 1: Star icon only, no username (love background, dark text)
        prompt += fg(roseBase.r, roseBase.g, roseBase.b)
        prompt += bg(roseLove.r, roseLove.g, roseLove.b)
        prompt += " \(starIcon) "

        // Transition arrow: love fg on gold bg
        prompt += fg(roseLove.r, roseLove.g, roseLove.b)
        prompt += bg(roseGold.r, roseGold.g, roseGold.b)
        prompt += arrowRight

        // Segment 2: Directory (gold background, dark text)
        prompt += fg(roseBase.r, roseBase.g, roseBase.b)
        prompt += bg(roseGold.r, roseGold.g, roseGold.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: roseGold, gitColor: roseGit, textColor: (r: 224, g: 222, b: 244), nextColor: roseIris,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Clock + time (iris background, dark text)
            prompt += fg(roseBase.r, roseBase.g, roseBase.b)
            prompt += bg(roseIris.r, roseIris.g, roseIris.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(roseIris.r, roseIris.g, roseIris.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? roseFoam : roseLove
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Synthwave '84 theme prompt — retro-futuristic with gradient cap and angle bracket
    private static func starshipSynthwave84(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Gradient left cap (░▒▓) like Tokyo Night
        prompt += fg(synthPink.r, synthPink.g, synthPink.b)
        prompt += "░▒▓"

        // Segment 1: Rocket icon + username (pink background, black text)
        prompt += fg(synthBlack.r, synthBlack.g, synthBlack.b)
        prompt += bg(synthPink.r, synthPink.g, synthPink.b)
        prompt += " \(rocketIcon) \(content.username) "

        // Transition arrow: pink fg on yellow bg
        prompt += fg(synthPink.r, synthPink.g, synthPink.b)
        prompt += bg(synthYellow.r, synthYellow.g, synthYellow.b)
        prompt += arrowRight

        // Segment 2: Directory (yellow background, black text)
        prompt += fg(synthBlack.r, synthBlack.g, synthBlack.b)
        prompt += bg(synthYellow.r, synthYellow.g, synthYellow.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: synthYellow, gitColor: synthGit, textColor: synthBlack, nextColor: synthCyan,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Clock + time (cyan background, black text)
            prompt += fg(synthBlack.r, synthBlack.g, synthBlack.b)
            prompt += bg(synthCyan.r, synthCyan.g, synthCyan.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(synthCyan.r, synthCyan.g, synthCyan.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        // Futuristic angle bracket prompt
        let chevronColor = lastCommandSucceeded ? synthGreen : synthPink
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += angleBracket
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Everforest theme prompt — nature-inspired with leaf icon
    private static func starshipEverforest(lastCommandSucceeded: Bool, content: PromptContent, gitInfo: PromptGitInfo?, showTime: Bool = true) -> PromptResult {
        var prompt = ""

        // Rounded left cap
        prompt += fg(everforestRed.r, everforestRed.g, everforestRed.b)
        prompt += roundedLeft

        // Segment 1: Leaf icon + username (red background, dark text)
        prompt += fg(everforestBg.r, everforestBg.g, everforestBg.b)
        prompt += bg(everforestRed.r, everforestRed.g, everforestRed.b)
        prompt += " \(leafIcon) \(content.username) "

        // Transition arrow: red fg on yellow bg
        prompt += fg(everforestRed.r, everforestRed.g, everforestRed.b)
        prompt += bg(everforestYellow.r, everforestYellow.g, everforestYellow.b)
        prompt += arrowRight

        // Segment 2: Directory (yellow background, dark text)
        prompt += fg(everforestBg.r, everforestBg.g, everforestBg.b)
        prompt += bg(everforestYellow.r, everforestYellow.g, everforestYellow.b)
        prompt += " \(content.path) "

        // Git segment (optional) + transition to time
        renderGitSegment(prompt: &prompt, gitInfo: gitInfo,
                         branchText: content.gitBranch, summaryText: content.gitSummary,
                         prevColor: everforestYellow, gitColor: everforestGit, textColor: everforestBg, nextColor: everforestGreen,
                         isLastSegment: !showTime)

        if showTime {
            // Segment 3: Clock + time (green background, dark text)
            prompt += fg(everforestBg.r, everforestBg.g, everforestBg.b)
            prompt += bg(everforestGreen.r, everforestGreen.g, everforestGreen.b)
            prompt += " \(clockIcon) \(content.time) "

            // Final rounded cap
            prompt += reset
            prompt += fg(everforestGreen.r, everforestGreen.g, everforestGreen.b)
            prompt += roundedRight
            prompt += reset
        }

        prompt += "\r\n"

        let chevronColor = lastCommandSucceeded ? everforestGreen : everforestRed
        prompt += fg(chevronColor.r, chevronColor.g, chevronColor.b)
        prompt += chevron
        prompt += reset
        prompt += " "

        return PromptResult(text: prompt, secondLinePrefix: 2)
    }

    /// Simple prompt for when Starship style is disabled
    static func simple() -> String {
        "$ "
    }
}

#endif
