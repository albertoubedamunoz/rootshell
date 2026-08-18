//
//  AuroraEffect.swift
//  rootshell
//
//  Aurora borealis background effect, rendered by the Aurora.metal
//  procedural shader: parallax curtain layers with a bright folding lower
//  edge, vertical ray streaks, and an altitude color ramp.
//

import SwiftUI
import Combine

/// Aurora borealis visual effect using a full-screen Metal shader
final class AuroraEffect: TerminalEffect, ObservableObject {
    // MARK: - TerminalEffect Protocol

    let id = "aurora"
    let displayName = String(localized: "Aurora", comment: "Background effect name: aurora borealis")
    let previewIcon = "sparkles"
    let effectDescription = String(localized: "Northern lights with drifting curtains and shimmering rays", comment: "Background effect description for aurora")

    /// Color palette style for the aurora
    enum ColorMode: String, CaseIterable {
        case theme
        case polarGreen
        case mysticPurple

        var displayName: String {
            switch self {
            case .theme:
                return String(localized: "Theme", comment: "Aurora color mode: derived from terminal theme")
            case .polarGreen:
                return String(localized: "Polar Green", comment: "Aurora color mode: classic green aurora")
            case .mysticPurple:
                return String(localized: "Mystic Purple", comment: "Aurora color mode: violet and pink aurora")
            }
        }
    }

    var intensity: Double = 0.3 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Palette style for the curtain colors
    var colorMode: ColorMode = .theme {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Fast per-ray flicker on top of the slow curtain drift
    var rayShimmer: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - TerminalEffect Implementation

    func createEffectView() -> AnyView {
        AnyView(AuroraView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.3
        speed = 1.0
        colorMode = .theme
        rayShimmer = true
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "colorMode": colorMode.rawValue,
            "rayShimmer": rayShimmer
        ]
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = intensity
        }
        if let speed = data["speed"] as? Double {
            self.speed = speed
        }
        if let colorModeRaw = data["colorMode"] as? String,
           let colorMode = ColorMode(rawValue: colorModeRaw) {
            self.colorMode = colorMode
        }
        if let rayShimmer = data["rayShimmer"] as? Bool {
            self.rayShimmer = rayShimmer
        }
    }

    // MARK: - Color Derivation

    /// Tiny RGB working space so all color math stays in plain doubles
    private struct RGB {
        var r: Double
        var g: Double
        var b: Double

        var color: Color { Color(red: r, green: g, blue: b) }

        /// Relative luminance (perceptual weights)
        var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

        func mixed(toward other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount,
                g: g + (other.g - g) * amount,
                b: b + (other.b - b) * amount)
        }

        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)

        static func fromHex(_ hex: String) -> RGB? {
            var s = hex.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            return RGB(r: Double((v >> 16) & 0xff) / 255,
                       g: Double((v >> 8) & 0xff) / 255,
                       b: Double(v & 0xff) / 255)
        }
    }

    // Physically anchored aurora hues: oxygen green (557nm) at the lower
    // edge, teal mid-altitude, red/magenta up high, purple lower fringe
    private static let anchorGreen = RGB(r: 0.10, g: 0.95, b: 0.45)
    private static let anchorTeal = RGB(r: 0.15, g: 0.80, b: 0.75)
    private static let anchorMagenta = RGB(r: 0.85, g: 0.25, b: 0.55)
    private static let anchorPurple = RGB(r: 0.55, g: 0.30, b: 0.90)

    /// Whether the current theme background is light (chooses blend tuning)
    var isLightBackground: Bool {
        guard let bg = RGB.fromHex(themeColors.background) else { return false }
        return bg.luminance > 0.5
    }

    private func paletteRGB(_ index: Int) -> RGB? {
        guard themeColors.palette.count > index else { return nil }
        return RGB.fromHex(themeColors.palette[index])
    }

    private func rawColors() -> (base: RGB, mid: RGB, high: RGB, fringe: RGB) {
        switch colorMode {
        case .theme:
            // Pull theme identity from the ANSI palette, then bias strongly
            // toward plausible aurora hues so any theme still reads as a sky
            let base = (paletteRGB(2) ?? Self.anchorGreen).mixed(toward: Self.anchorGreen, 0.55)
            let mid = (paletteRGB(6) ?? Self.anchorTeal).mixed(toward: Self.anchorTeal, 0.55)
            let high = (paletteRGB(5) ?? Self.anchorMagenta).mixed(toward: Self.anchorMagenta, 0.55)
            return (base, mid, high, Self.anchorPurple)
        case .polarGreen:
            return (Self.anchorGreen, Self.anchorTeal, Self.anchorMagenta, Self.anchorPurple)
        case .mysticPurple:
            return (RGB(r: 0.45, g: 0.30, b: 0.95),
                    RGB(r: 0.25, g: 0.45, b: 0.95),
                    RGB(r: 0.95, g: 0.35, b: 0.75),
                    RGB(r: 0.55, g: 0.85, b: 0.95))
        }
    }

    /// Keep the curtains visible under the overlay blend: additive blending
    /// swallows dark colors, multiply swallows light ones
    private func tuned(_ c: RGB) -> RGB {
        if isLightBackground {
            var deep = c.mixed(toward: .black, 0.45)
            if deep.luminance > 0.55 { deep = deep.mixed(toward: .black, 0.3) }
            return deep
        } else {
            if c.luminance < 0.3 { return c.mixed(toward: .white, 0.35) }
            return c
        }
    }

    /// Shader uniforms, tuned for the active blend mode
    var shaderColors: (base: Color, mid: Color, high: Color, fringe: Color) {
        let raw = rawColors()
        return (tuned(raw.base).color,
                tuned(raw.mid).color,
                tuned(raw.high).color,
                tuned(raw.fringe).color)
    }
}

// MARK: - Aurora SwiftUI View

/// Accumulates speed-scaled animation phase so live speed changes glide
/// instead of jumping the whole sky to a new point in time
private final class AuroraClock {
    private var phase: Double = 0
    private var lastDate: Date?

    func phase(at date: Date, speed: Double) -> Double {
        if let last = lastDate {
            let dt = min(max(date.timeIntervalSince(last), 0), 0.5)
            phase += dt * speed
        }
        lastDate = date
        return phase
    }
}

/// SwiftUI view that drives the Aurora.metal shader
struct AuroraView: View {
    let effect: AuroraEffect

    @State private var clock = AuroraClock()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: (1.0 / 30.0) * PowerManager.shared.effectIntervalScale)) { timeline in
                let phase = clock.phase(at: timeline.date, speed: effect.speed)
                let colors = effect.shaderColors

                Rectangle()
                    .fill(Color.white.opacity(0.001))  // Nearly invisible base for shader
                    .colorEffect(
                        ShaderLibrary.aurora(
                            .float2(geometry.size),
                            .float(Float(phase)),
                            .float(Float(effect.intensity)),
                            .color(colors.base),
                            .color(colors.mid),
                            .color(colors.high),
                            .color(colors.fringe),
                            .float(effect.isLightBackground ? 1 : 0),
                            .float(effect.rayShimmer ? 1 : 0)
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }
}
