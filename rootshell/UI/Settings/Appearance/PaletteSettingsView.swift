//
//  PaletteSettingsView.swift
//  rootshell
//
//  Settings view for configuring palette generation
//

import SwiftUI

struct PaletteSettingsView: View {
    var paletteManager = PaletteManager.shared
    var themeManager = ThemeManager.shared

    var body: some View {
        List {
            Section {
                SettingToggle(
                    Settings.Palette.generate,
                    isOn: Bindable(paletteManager).paletteGenerateEnabled,
                    title: "Generate Palette",
                    icon: "swatchpalette"
                )
                .themedRow()
            } footer: {
                Text("Generates the extended 256-color palette from your theme's base 16 colors using perceptually uniform interpolation in CIELAB color space.")
            }

            if paletteManager.paletteGenerateEnabled {
                Section {
                    SettingToggle(
                        Settings.Palette.harmonious,
                        isOn: Bindable(paletteManager).paletteHarmoniousEnabled,
                        title: "Harmonious Mode",
                        icon: "circle.lefthalf.filled"
                    )
                    .themedRow()
                } footer: {
                    Text("Preserves palette index ordering for light themes so palette-based applications display consistent colors in both light and dark modes.")
                }
            }

            palettePreviewSection
        }
        .themedList()
        .navigationTitle(String(localized: "Colors", comment: "Settings navigation title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Preview

    @ViewBuilder
    private var palettePreviewSection: some View {
        let colors = themeManager.currentThemeInfo?.colors
        let bg = colors?.background ?? "#1e1e2e"
        let fg = colors?.foreground ?? "#cdd6f4"
        let base8 = colors?.palette ?? []

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Color Cube")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PaletteCubePreview(
                    base8: base8,
                    background: bg,
                    foreground: fg,
                    generateEnabled: paletteManager.paletteGenerateEnabled,
                    harmonious: paletteManager.paletteHarmoniousEnabled
                )
            }
            .themedRow()

            VStack(alignment: .leading, spacing: 8) {
                Text("Grayscale Ramp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                GrayscaleRampPreview(
                    base8: base8,
                    background: bg,
                    foreground: fg,
                    generateEnabled: paletteManager.paletteGenerateEnabled,
                    harmonious: paletteManager.paletteHarmoniousEnabled
                )
            }
            .themedRow()
        } header: {
            Text("Preview")
        } footer: {
            Text(paletteManager.paletteGenerateEnabled
                ? "Generated from your theme's base colors."
                : "Standard xterm 256-color palette.")
        }
    }
}

// MARK: - Palette Cube Preview

/// Shows the 216-color cube (indices 16–231) as a grid.
private struct PaletteCubePreview: View {
    let base8: [String]
    let background: String
    let foreground: String
    let generateEnabled: Bool
    let harmonious: Bool

    var body: some View {
        let colors = cubeColors()
        // 6 R-slices, each 36 colors (6 G rows x 6 B columns)
        VStack(spacing: 1) {
            ForEach(0..<6, id: \.self) { g in
                HStack(spacing: 1) {
                    ForEach(0..<36, id: \.self) { idx in
                        let colorIdx = g * 36 + idx
                        colors[colorIdx]
                            .frame(maxWidth: .infinity, minHeight: 6, maxHeight: 6)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func cubeColors() -> [Color] {
        if generateEnabled, base8.count >= 8 {
            return PaletteGenerator.generateCube(
                base8: base8, background: background, foreground: foreground,
                harmonious: harmonious
            )
        } else {
            return PaletteGenerator.xtermCube()
        }
    }
}

// MARK: - Grayscale Ramp Preview

/// Shows the 24-step grayscale ramp (indices 232–255).
private struct GrayscaleRampPreview: View {
    let base8: [String]
    let background: String
    let foreground: String
    let generateEnabled: Bool
    let harmonious: Bool

    var body: some View {
        let colors = rampColors()
        HStack(spacing: 1) {
            ForEach(0..<24, id: \.self) { i in
                colors[i]
                    .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func rampColors() -> [Color] {
        if generateEnabled, base8.count >= 8 {
            return PaletteGenerator.generateGrayscale(
                background: background, foreground: foreground,
                harmonious: harmonious
            )
        } else {
            return PaletteGenerator.xtermGrayscale()
        }
    }
}

// MARK: - CIELAB Palette Generator

/// Swift port of Ghostty's CIELAB-based 256-color palette generation algorithm
/// from src/terminal/color.zig. Used only for the settings preview.
private enum PaletteGenerator {

    // MARK: - CIELAB

    private struct LAB {
        var l: Float
        var a: Float
        var b: Float

        static func fromRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> LAB {
            var rf = Float(r) / 255.0
            var gf = Float(g) / 255.0
            var bf = Float(b) / 255.0

            rf = rf > 0.04045 ? pow((rf + 0.055) / 1.055, 2.4) : rf / 12.92
            gf = gf > 0.04045 ? pow((gf + 0.055) / 1.055, 2.4) : gf / 12.92
            bf = bf > 0.04045 ? pow((bf + 0.055) / 1.055, 2.4) : bf / 12.92

            var x = (rf * 0.4124564 + gf * 0.3575761 + bf * 0.1804375) / 0.95047
            var y = rf * 0.2126729 + gf * 0.7151522 + bf * 0.0721750
            var z = (rf * 0.0193339 + gf * 0.1191920 + bf * 0.9503041) / 1.08883

            x = x > 0.008856 ? cbrt(x) : 7.787 * x + 16.0 / 116.0
            y = y > 0.008856 ? cbrt(y) : 7.787 * y + 16.0 / 116.0
            z = z > 0.008856 ? cbrt(z) : 7.787 * z + 16.0 / 116.0

            return LAB(l: 116.0 * y - 16.0, a: 500.0 * (x - y), b: 200.0 * (y - z))
        }

        func toColor() -> Color {
            let y = (l + 16.0) / 116.0
            let x = a / 500.0 + y
            let z = y - b / 200.0

            let x3 = x * x * x
            let y3 = y * y * y
            let z3 = z * z * z

            let xf = (x3 > 0.008856 ? x3 : (x - 16.0 / 116.0) / 7.787) * 0.95047
            let yf = y3 > 0.008856 ? y3 : (y - 16.0 / 116.0) / 7.787
            let zf = (z3 > 0.008856 ? z3 : (z - 16.0 / 116.0) / 7.787) * 1.08883

            var r = xf * 3.2404542 - yf * 1.5371385 - zf * 0.4985314
            var g = -xf * 0.9692660 + yf * 1.8760108 + zf * 0.0415560
            var bf = xf * 0.0556434 - yf * 0.2040259 + zf * 1.0572252

            r = r > 0.0031308 ? 1.055 * pow(r, 1.0 / 2.4) - 0.055 : 12.92 * r
            g = g > 0.0031308 ? 1.055 * pow(g, 1.0 / 2.4) - 0.055 : 12.92 * g
            bf = bf > 0.0031308 ? 1.055 * pow(bf, 1.0 / 2.4) - 0.055 : 12.92 * bf

            return Color(
                red: Double(min(max(r, 0), 1)),
                green: Double(min(max(g, 0), 1)),
                blue: Double(min(max(bf, 0), 1))
            )
        }

        static func lerp(_ t: Float, _ a: LAB, _ b: LAB) -> LAB {
            LAB(
                l: a.l + t * (b.l - a.l),
                a: a.a + t * (b.a - a.a),
                b: a.b + t * (b.b - a.b)
            )
        }
    }

    // MARK: - Hex Parsing

    private static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        return (UInt8((rgb >> 16) & 0xFF), UInt8((rgb >> 8) & 0xFF), UInt8(rgb & 0xFF))
    }

    // MARK: - Generated Palette

    static func generateCube(
        base8: [String], background: String, foreground: String, harmonious: Bool
    ) -> [Color] {
        let bg = parseHex(background)
        let fg = parseHex(foreground)

        var labs: [LAB] = [
            .fromRGB(bg.0, bg.1, bg.2),
            .fromRGB(parseHex(base8[1]).0, parseHex(base8[1]).1, parseHex(base8[1]).2),
            .fromRGB(parseHex(base8[2]).0, parseHex(base8[2]).1, parseHex(base8[2]).2),
            .fromRGB(parseHex(base8[3]).0, parseHex(base8[3]).1, parseHex(base8[3]).2),
            .fromRGB(parseHex(base8[4]).0, parseHex(base8[4]).1, parseHex(base8[4]).2),
            .fromRGB(parseHex(base8[5]).0, parseHex(base8[5]).1, parseHex(base8[5]).2),
            .fromRGB(parseHex(base8[6]).0, parseHex(base8[6]).1, parseHex(base8[6]).2),
            .fromRGB(fg.0, fg.1, fg.2),
        ]

        let isLightTheme = labs[7].l < labs[0].l
        let invert = isLightTheme && !harmonious
        if invert { labs.swapAt(0, 7) }

        var result: [Color] = []
        result.reserveCapacity(216)

        for ri in 0..<6 {
            let tr = Float(ri) / 5.0
            let c0 = LAB.lerp(tr, labs[0], labs[1])
            let c1 = LAB.lerp(tr, labs[2], labs[3])
            let c2 = LAB.lerp(tr, labs[4], labs[5])
            let c3 = LAB.lerp(tr, labs[6], labs[7])
            for gi in 0..<6 {
                let tg = Float(gi) / 5.0
                let c4 = LAB.lerp(tg, c0, c1)
                let c5 = LAB.lerp(tg, c2, c3)
                for bi in 0..<6 {
                    let tb = Float(bi) / 5.0
                    let c6 = LAB.lerp(tb, c4, c5)
                    result.append(c6.toColor())
                }
            }
        }
        return result
    }

    static func generateGrayscale(
        background: String, foreground: String, harmonious: Bool
    ) -> [Color] {
        let bg = parseHex(background)
        let fg = parseHex(foreground)
        var labBg = LAB.fromRGB(bg.0, bg.1, bg.2)
        var labFg = LAB.fromRGB(fg.0, fg.1, fg.2)

        let isLightTheme = labFg.l < labBg.l
        let invert = isLightTheme && !harmonious
        if invert { swap(&labBg, &labFg) }

        var result: [Color] = []
        result.reserveCapacity(24)
        for i in 0..<24 {
            let t = Float(i + 1) / 25.0
            result.append(LAB.lerp(t, labBg, labFg).toColor())
        }
        return result
    }

    // MARK: - Standard xterm Palette

    private static let xtermLevels: [UInt8] = [0, 95, 135, 175, 215, 255]

    static func xtermCube() -> [Color] {
        var result: [Color] = []
        result.reserveCapacity(216)
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    result.append(Color(
                        red: Double(xtermLevels[r]) / 255.0,
                        green: Double(xtermLevels[g]) / 255.0,
                        blue: Double(xtermLevels[b]) / 255.0
                    ))
                }
            }
        }
        return result
    }

    static func xtermGrayscale() -> [Color] {
        (0..<24).map { i in
            let v = Double(8 + i * 10) / 255.0
            return Color(red: v, green: v, blue: v)
        }
    }
}
