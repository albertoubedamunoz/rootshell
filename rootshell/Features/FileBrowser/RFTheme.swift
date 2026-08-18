#if !targetEnvironment(macCatalyst)

import Foundation

/// Semantic color palette for the rf file browser, derived from the terminal theme.
/// All colors are 24-bit RGB tuples for truecolor rendering.
@MainActor
struct RFTheme: Sendable {
    typealias RGB = (UInt8, UInt8, UInt8)

    // nonisolated: used as a default argument, which is evaluated outside
    // the type's isolation.
    private nonisolated static let minimumTextContrast = 4.5
    private static let minimumDecorativeContrast = 3.0

    // Base colors
    let fg: RGB
    let bg: RGB
    let dimmed: RGB

    // Selection / highlighting
    let selectionBg: RGB
    let selectionFg: RGB
    let hoverBg: RGB

    // File type colors
    let directoryColor: RGB
    let executableColor: RGB
    let symlinkColor: RGB
    let mediaColor: RGB
    let archiveColor: RGB
    let hiddenColor: RGB

    // UI chrome
    let separatorColor: RGB
    let separatorHoverColor: RGB
    let headerBg: RGB
    let headerFg: RGB
    let statusBg: RGB
    let statusFg: RGB
    let errorColor: RGB

    // Tab bar
    let tabActiveBg: RGB
    let tabActiveFg: RGB
    let tabInactiveBg: RGB
    let tabInactiveFg: RGB

    // Indicators
    let selectedMarker: RGB
    let yankIndicator: RGB

    // Git status
    let gitModified: RGB
    let gitStaged: RGB
    let gitUntracked: RGB
    let gitDeleted: RGB
    let gitConflict: RGB

    // Input
    let inputCursorColor: RGB
    let inputPromptColor: RGB

    // Powerline mode colors
    let modeNormalBg: RGB
    let modeNormalFg: RGB
    let modeSelectBg: RGB
    let modeSelectFg: RGB
    let modeAltBg: RGB
    let modeAltFg: RGB

    static func fromTheme(themeName: String? = nil) -> RFTheme {
        let tc = themeName.flatMap(themeColors(for:)) ?? SpinnerAnimator.ThemeColors.fromThemeManager()
        let fg = tc.foreground
        let bg = tc.background
        let dim = readable(
            tc.dimmedForeground,
            on: bg,
            fallback: fg,
            minimumContrast: minimumDecorativeContrast
        )

        // Derive selection from the active palette blue, but blend with the
        // terminal background so the highlight stays legible on both dark and
        // light themes.
        let blue = tc.palette[4]
        let selBg = ensureSeparated(
            mix(bg, blue, amount: tc.isLightBackground ? 0.22 : 0.38),
            from: bg,
            toward: blue,
            minimumContrast: 1.35
        )
        let selFg = readable(fg, on: selBg, fallback: contrastingText(on: selBg))

        // Hover: slightly lighter than background
        let hoverBg: RGB
        if tc.isLightBackground {
            hoverBg = (
                UInt8(max(0, Int(bg.0) - 15)),
                UInt8(max(0, Int(bg.1) - 15)),
                UInt8(max(0, Int(bg.2) - 15))
            )
        } else {
            hoverBg = (
                UInt8(min(255, Int(bg.0) + 15)),
                UInt8(min(255, Int(bg.1) + 15)),
                UInt8(min(255, Int(bg.2) + 15))
            )
        }

        // Header/status/tab chrome should track the terminal background instead
        // of palette black. Many light themes have a dark foreground and a dark
        // palette[0], which makes black-on-dark chrome unreadable.
        let surface = mix(bg, fg, amount: tc.isLightBackground ? 0.08 : 0.10)
        let elevatedSurface = mix(bg, fg, amount: tc.isLightBackground ? 0.14 : 0.16)

        // Separator hover: midpoint between separator and foreground
        let sepHover: RGB = (
            UInt8((Int(dim.0) + Int(fg.0)) / 2),
            UInt8((Int(dim.1) + Int(fg.1)) / 2),
            UInt8((Int(dim.2) + Int(fg.2)) / 2)
        )

        // Extract palette colors to help type checker
        let paletteBlue = tc.palette[4]
        let paletteGreen = tc.palette[2]
        let paletteCyan = tc.palette[6]
        let paletteMagenta = tc.palette[5]
        let paletteRed = tc.palette[1]
        let paletteYellow = tc.palette[3]

        // Mode colors for powerline status bar
        let modeNormalBg = ensureSeparated(
            paletteBlue,
            from: bg,
            toward: tc.isLightBackground ? darken(paletteBlue, amount: 0.32) : lighten(paletteBlue, amount: 0.24),
            minimumContrast: 2.0
        )
        let modeNormalFg = readable(fg, on: modeNormalBg, fallback: contrastingText(on: modeNormalBg))
        let modeSelectBg = paletteGreen
        let modeSelectFg = readable(fg, on: modeSelectBg, fallback: contrastingText(on: modeSelectBg))
        let modeAltBg = elevatedSurface

        let headerFg = readable(fg, on: surface)
        let statusFg = readable(dim, on: surface, fallback: headerFg, minimumContrast: minimumDecorativeContrast)
        let tabInactiveFg = statusFg
        let inputPrompt = readable(paletteCyan, on: surface, fallback: headerFg)

        let t = RFTheme(
            fg: fg, bg: bg, dimmed: dim,
            selectionBg: selBg, selectionFg: selFg, hoverBg: hoverBg,
            directoryColor: readable(paletteBlue, on: bg, fallback: fg),
            executableColor: readable(paletteGreen, on: bg, fallback: fg),
            symlinkColor: readable(paletteCyan, on: bg, fallback: fg),
            mediaColor: readable(paletteMagenta, on: bg, fallback: fg),
            archiveColor: readable(paletteRed, on: bg, fallback: fg),
            hiddenColor: dim,
            separatorColor: dim, separatorHoverColor: sepHover,
            headerBg: surface, headerFg: headerFg,
            statusBg: surface, statusFg: statusFg,
            errorColor: readable(paletteRed, on: bg, fallback: fg),
            tabActiveBg: selBg, tabActiveFg: selFg,
            tabInactiveBg: surface, tabInactiveFg: tabInactiveFg,
            selectedMarker: readable(paletteGreen, on: bg, fallback: fg),
            yankIndicator: readable(paletteYellow, on: bg, fallback: fg),
            gitModified: readable(paletteYellow, on: bg, fallback: fg),
            gitStaged: readable(paletteGreen, on: bg, fallback: fg),
            gitUntracked: dim,
            gitDeleted: readable(paletteRed, on: bg, fallback: fg),
            gitConflict: readable(paletteRed, on: bg, fallback: fg),
            inputCursorColor: headerFg, inputPromptColor: inputPrompt,
            modeNormalBg: modeNormalBg, modeNormalFg: modeNormalFg,
            modeSelectBg: modeSelectBg, modeSelectFg: modeSelectFg,
            modeAltBg: modeAltBg,
            modeAltFg: readable(dim, on: modeAltBg, fallback: headerFg, minimumContrast: minimumDecorativeContrast)
        )
        return t
    }

    func readableTextColor(_ color: RGB, on background: RGB? = nil) -> RGB {
        Self.readable(
            color,
            on: background ?? bg,
            fallback: fg,
            minimumContrast: Self.minimumTextContrast
        )
    }

    func readableDecorativeColor(_ color: RGB, on background: RGB? = nil) -> RGB {
        Self.readable(
            color,
            on: background ?? bg,
            fallback: fg,
            minimumContrast: Self.minimumDecorativeContrast
        )
    }

    private static func readable(
        _ color: RGB,
        on background: RGB,
        fallback: RGB? = nil,
        minimumContrast: Double = minimumTextContrast
    ) -> RGB {
        if contrastRatio(color, background) >= minimumContrast {
            return color
        }

        let fallbackColor = fallback ?? contrastingText(on: background)
        let candidates = [
            mix(color, fallbackColor, amount: 0.45),
            mix(color, fallbackColor, amount: 0.65),
            fallbackColor,
            contrastingText(on: background)
        ]

        if let readableCandidate = candidates.first(where: { contrastRatio($0, background) >= minimumContrast }) {
            return readableCandidate
        }

        return candidates.max { contrastRatio($0, background) < contrastRatio($1, background) } ?? fallbackColor
    }

    private static func ensureSeparated(
        _ color: RGB,
        from background: RGB,
        toward target: RGB,
        minimumContrast: Double
    ) -> RGB {
        if contrastRatio(color, background) >= minimumContrast {
            return color
        }

        var best = color
        var bestContrast = contrastRatio(color, background)
        for step in 1...8 {
            let candidate = mix(color, target, amount: Double(step) / 8.0)
            let contrast = contrastRatio(candidate, background)
            if contrast > bestContrast {
                best = candidate
                bestContrast = contrast
            }
            if contrast >= minimumContrast {
                return candidate
            }
        }
        return best
    }

    private static func contrastingText(on background: RGB) -> RGB {
        contrastRatio((0, 0, 0), background) >= contrastRatio((255, 255, 255), background)
            ? (0, 0, 0)
            : (255, 255, 255)
    }

    private static func mix(_ a: RGB, _ b: RGB, amount: Double) -> RGB {
        let t = max(0, min(1, amount))
        func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(x) + (Double(y) - Double(x)) * t).rounded()))
        }
        return (channel(a.0, b.0), channel(a.1, b.1), channel(a.2, b.2))
    }

    private static func lighten(_ color: RGB, amount: Double) -> RGB {
        mix(color, (255, 255, 255), amount: amount)
    }

    private static func darken(_ color: RGB, amount: Double) -> RGB {
        mix(color, (0, 0, 0), amount: amount)
    }

    private static func contrastRatio(_ lhs: RGB, _ rhs: RGB) -> Double {
        let l1 = luminance(lhs) + 0.05
        let l2 = luminance(rhs) + 0.05
        return max(l1, l2) / min(l1, l2)
    }

    private static func luminance(_ color: RGB) -> Double {
        func component(_ value: UInt8) -> Double {
            let c = Double(value) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * component(color.0) + 0.7152 * component(color.1) + 0.0722 * component(color.2)
    }

    private static func themeColors(for themeName: String) -> SpinnerAnimator.ThemeColors? {
        guard let info = ThemeManager.shared.themeInfo(for: themeName) else { return nil }
        let colors = info.colors
        let fg = parseHex(colors.foreground) ?? SpinnerAnimator.ThemeColors.default.foreground
        let bg = parseHex(colors.background) ?? SpinnerAnimator.ThemeColors.default.background

        var palette: [RGB] = []
        palette.reserveCapacity(16)
        for hexColor in colors.palette {
            let colorPart = hexColor.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? hexColor
            if let rgb = parseHex(colorPart) {
                palette.append(rgb)
            }
        }
        while palette.count < 16 {
            palette.append(SpinnerAnimator.ThemeColors.default.palette[palette.count])
        }

        return SpinnerAnimator.ThemeColors(
            foreground: fg,
            background: bg,
            palette: palette,
            isLightBackground: info.isLight
        )
    }

    private static func parseHex(_ hex: String) -> RGB? {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgbValue: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgbValue) else { return nil }

        return (
            UInt8((rgbValue & 0xFF0000) >> 16),
            UInt8((rgbValue & 0x00FF00) >> 8),
            UInt8(rgbValue & 0x0000FF)
        )
    }

    // MARK: - ANSI Helpers

    func fgSeq(_ c: RGB) -> String {
        "\u{1b}[38;2;\(c.0);\(c.1);\(c.2)m"
    }

    func bgSeq(_ c: RGB) -> String {
        "\u{1b}[48;2;\(c.0);\(c.1);\(c.2)m"
    }
}

#endif
