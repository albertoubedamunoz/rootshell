//
//  ThemeGradientEffect.swift
//  rootshell
//
//  Soft drifting gradient built from the terminal theme palette, rendered
//  by the ThemeGradient.metal shader: a primary base under four radial gradients.
//

import SwiftUI
import Combine

/// Theme-colored gradient background effect
final class ThemeGradientEffect: TerminalEffect, ObservableObject {
    // MARK: - TerminalEffect Protocol

    let id: String
    let displayName = String(localized: "Theme Gradient", comment: "Background effect name: gradient from theme colors")
    let previewIcon = "paintpalette"
    let effectDescription = String(localized: "Soft drifting glow in the terminal theme's colors", comment: "Background effect description for theme gradient")

    /// Opaque window backdrop instead of a tint blended over the terminal.
    let isBackdrop: Bool

    init(isBackdrop: Bool = false) {
        self.isBackdrop = isBackdrop
        id = isBackdrop ? "themeGradientBackdrop" : "themeGradient"
    }

    var intensity: Double = 0.35 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet {
            guard themeColors != oldValue else { return }
            palette = ThemeGradientPalette(themeColors: themeColors)
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    /// Slow blob motion. Off draws a single still frame.
    var drift: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    private(set) var palette = ThemeGradientPalette(themeColors: .defaults)

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - TerminalEffect Implementation

    func createEffectView() -> AnyView {
        AnyView(ThemeGradientView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.35
        speed = 1.0
        drift = true
    }

    func encodeConfiguration() -> [String: Any] {
        [
            "intensity": intensity,
            "speed": speed,
            "drift": drift
        ]
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = intensity
        }
        if let speed = data["speed"] as? Double {
            self.speed = speed
        }
        if let drift = data["drift"] as? Bool {
            self.drift = drift
        }
    }
}

// MARK: - Palette

/// Shader colors derived once per theme: the primary, an accent with a
/// distinct hue, and a mid tone between them.
struct ThemeGradientPalette: Equatable {
    var primary: SIMD3<Double>
    var accent: SIMD3<Double>
    var mid: SIMD3<Double>
    var isLight: Bool

    var colors: [SIMD3<Double>] { [primary, accent, mid] }

    private struct HSB {
        var h: Double
        var s: Double
        var b: Double
    }

    private struct Candidate {
        var hsb: HSB
        var order: Int
        var score: Double = 0
    }

    init(themeColors: EffectThemeColors) {
        let background = Self.rgb(hex: themeColors.background) ?? SIMD3(0.1, 0.1, 0.15)
        let foreground = Self.rgb(hex: themeColors.foreground) ?? SIMD3(0.8, 0.8, 0.85)
        isLight = Color(hex: themeColors.background)?.isLight ?? false

        // ANSI 0, 7, 8 and 15 are the theme's grays
        let indices = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
        var hexes = indices.filter { $0 < themeColors.palette.count }.map { themeColors.palette[$0] }
        hexes.append(themeColors.cursor)
        var candidates = hexes.enumerated().compactMap { order, hex -> Candidate? in
            guard let rgb = Self.rgb(hex: hex) else { return nil }
            let hsb = Self.hsb(rgb)
            guard hsb.s >= 0.15, hsb.b >= 0.15 else { return nil }
            return Candidate(hsb: hsb, order: order)
        }

        guard !candidates.isEmpty else {
            // Monochrome theme: a dim wash of the foreground with a lighter glow
            let wash = foreground + (background - foreground) * 0.7
            let faint = foreground + (background - foreground) * 0.45
            self.primary = wash
            self.accent = faint
            self.mid = (wash + faint) / 2
            return
        }

        // Hue prevalence stands in for the pixel share used on artwork
        for i in candidates.indices {
            let hsb = candidates[i].hsb
            let neighbors = candidates.filter { Self.hueDistance($0.hsb.h, hsb.h) <= 0.08 }.count
            let prevalence = Double(neighbors) / Double(candidates.count)
            let brightness = 1 - abs(hsb.b - 0.5) * 2
            candidates[i].score = hsb.s * 0.4 + brightness * 0.3 + prevalence * 0.3
        }
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }

        var primary = candidates[0].hsb
        if primary.b > 0.7 {
            primary.b *= 0.7
            primary.s = min(1, primary.s * 1.1)
        } else if primary.b > 0.5 {
            primary.b *= 0.85
        }
        // Theme colors run brighter than artwork; keep dark themes rich, not pastel
        if !isLight { primary.b = min(primary.b, 0.5) }

        var accent: HSB
        if let match = candidates.dropFirst().first(where: { Self.hueDistance($0.hsb.h, primary.h) > 0.15 }) {
            accent = match.hsb
        } else {
            let b = primary.b < 0.3 ? primary.b * 1.5 : primary.b * 0.8
            accent = HSB(h: (primary.h + 0.15).truncatingRemainder(dividingBy: 1),
                         s: min(1, primary.s * 1.2),
                         b: min(max(b, 0.4), 0.8))
        }
        if !isLight { accent.b = min(accent.b, 0.7) }

        // Circular mean so red/magenta pairs don't average to green
        let angleP = primary.h * 2 * .pi
        let angleA = accent.h * 2 * .pi
        var midHue = atan2(sin(angleP) + sin(angleA), cos(angleP) + cos(angleA)) / (2 * .pi)
        if midHue < 0 { midHue += 1 }
        let mid = HSB(h: midHue, s: max(primary.s, accent.s) * 0.8, b: (primary.b + accent.b) / 2)

        self.primary = Self.rgb(primary)
        self.accent = Self.rgb(accent)
        self.mid = Self.rgb(mid)
    }

    // MARK: Color math

    private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    private static func rgb(hex: String) -> SIMD3<Double>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return SIMD3(Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)) / 255
    }

    private static func hsb(_ c: SIMD3<Double>) -> HSB {
        let maxC = c.max(), minC = c.min()
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.x {
                h = ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == c.y {
                h = (c.z - c.x) / delta + 2
            } else {
                h = (c.x - c.y) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return HSB(h: h, s: maxC > 0 ? delta / maxC : 0, b: maxC)
    }

    private static func rgb(_ hsb: HSB) -> SIMD3<Double> {
        let h = (hsb.h - floor(hsb.h)) * 6
        let c = hsb.b * hsb.s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = hsb.b - c
        let base: SIMD3<Double>
        switch Int(h) {
        case 0: base = SIMD3(c, x, 0)
        case 1: base = SIMD3(x, c, 0)
        case 2: base = SIMD3(0, c, x)
        case 3: base = SIMD3(0, x, c)
        case 4: base = SIMD3(x, 0, c)
        default: base = SIMD3(c, 0, x)
        }
        return base + m
    }
}

// MARK: - Clock

/// Advances speed-scaled phase, drifts the gradients, and crossfades palette
/// changes. A reference type so the timeline body never mutates view state.
private final class ThemeGradientClock {
    private(set) var phase: Double = 0
    private var lastDate: Date?
    private var target: ThemeGradientPalette?
    private var current: [SIMD3<Double>] = []
    private var from: [SIMD3<Double>]?
    private var transitionStart: Date?

    private static let crossfade: TimeInterval = 0.8

    /// Uv drift amplitude and periods (seconds at speed 1) per gradient, in
    /// shader order. Incommensurate periods keep the motion from visibly looping.
    private static let drifts: [(amplitude: SIMD2<Double>, period: SIMD2<Double>)] = [
        (SIMD2(0.08, 0.06), SIMD2(19, 27)),
        (SIMD2(0.10, 0.04), SIMD2(23, 31)),
        (SIMD2(0.05, 0.08), SIMD2(29, 17)),
        (SIMD2(0.09, 0.07), SIMD2(21, 37)),
    ]

    func offsets(at date: Date, speed: Double, running: Bool) -> [SIMD2<Double>] {
        if running {
            if let last = lastDate {
                phase += min(max(date.timeIntervalSince(last), 0), 0.5) * speed
            }
            lastDate = date
        } else {
            lastDate = nil
        }
        return Self.drifts.enumerated().map { index, drift in
            let offset = Double(index) * 1.7
            let angle = SIMD2(2 * .pi * phase, 2 * .pi * phase) / drift.period + SIMD2(offset, offset * 2.3)
            return drift.amplitude * SIMD2(sin(angle.x), sin(angle.y))
        }
    }

    func colors(for palette: ThemeGradientPalette, at date: Date, animated: Bool) -> [SIMD3<Double>] {
        if palette != target {
            from = animated && target != nil ? current : nil
            transitionStart = date
            target = palette
        }
        guard animated, let from, let start = transitionStart else {
            current = palette.colors
            return current
        }
        let t = min(max(date.timeIntervalSince(start) / Self.crossfade, 0), 1)
        if t >= 1 { self.from = nil }
        let eased = t * t * (3 - 2 * t)
        current = zip(from, palette.colors).map { $0 + ($1 - $0) * eased }
        return current
    }
}

// MARK: - View

/// SwiftUI view that drives the ThemeGradient.metal shader
struct ThemeGradientView: View {
    @ObservedObject var effect: ThemeGradientEffect

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var clock = ThemeGradientClock()

    private var isRunning: Bool {
        effect.drift && !reduceMotion && scenePhase != .background
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: (1.0 / 30.0) * PowerManager.shared.effectIntervalScale,
                                    paused: !isRunning)) { timeline in
                let palette = effect.palette
                let offsets = clock.offsets(at: timeline.date, speed: effect.speed, running: isRunning)
                let colors = clock.colors(for: palette, at: timeline.date, animated: isRunning)

                Rectangle()
                    .fill(Color.white.opacity(0.001))  // Nearly invisible base for shader
                    .colorEffect(
                        ShaderLibrary.themeGradient(
                            .float2(geometry.size),
                            .float4(Float(offsets[0].x), Float(offsets[0].y), Float(offsets[1].x), Float(offsets[1].y)),
                            .float4(Float(offsets[2].x), Float(offsets[2].y), Float(offsets[3].x), Float(offsets[3].y)),
                            .color(Self.color(colors[0])),
                            .color(Self.color(colors[1])),
                            .color(Self.color(colors[2])),
                            .float(Float(effect.intensity)),
                            .float(effect.isBackdrop ? 1 : 0),
                            .float(palette.isLight ? 1 : 0)
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private static func color(_ c: SIMD3<Double>) -> Color {
        Color(red: c.x, green: c.y, blue: c.z)
    }
}
