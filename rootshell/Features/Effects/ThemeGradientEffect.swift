//
//  ThemeGradientEffect.swift
//  rootshell
//
//  Soft drifting gradient built from the terminal theme palette, rendered
//  by the ThemeGradient.metal shader: a primary base under four radial gradients.
//  ThemeGradientPalette picks the colors.
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
            palette = ThemeGradientPalette(themeColors: themeColors, look: look)
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    /// Style, custom colors and adjustments.
    var look = ThemeGradientLook() {
        didSet {
            guard look != oldValue else { return }
            palette = ThemeGradientPalette(themeColors: themeColors, look: look)
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
        isBackdrop ? AnyView(ThemeGradientBackdropView(effect: self)) : AnyView(ThemeGradientView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.35
        speed = 1.0
        drift = true
        look = ThemeGradientLook()
    }

    func encodeConfiguration() -> [String: Any] {
        var data: [String: Any] = [
            "intensity": intensity,
            "speed": speed,
            "drift": drift
        ]
        look.encode(into: &data)
        return data
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
        look = ThemeGradientLook(configuration: data)
    }
}

// MARK: - Clock

/// Advances speed-scaled phase, drifts the gradients, and crossfades palette
/// changes. A reference type so the timeline body never mutates view state.
final class ThemeGradientClock {
    private(set) var phase: Double = 0
    private var lastDate: Date?
    private var target: ThemeGradientPalette?
    private var current: [SIMD3<Double>] = []
    private var from: [SIMD3<Double>]?
    private var transitionStart: Date?

    private static let crossfade: TimeInterval = 0.8

    var isCrossfading: Bool { from != nil }

    /// Freeze the drift so the next running frame resumes without a jump.
    func hold() { lastDate = nil }

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
    @Environment(\.terminalEffectBottomInset) private var bottomInset

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
                // The glow fits above the keyboard and carries on beneath it.
                let area = CGSize(width: geometry.size.width,
                                  height: max(1, geometry.size.height - bottomInset))

                Rectangle()
                    .fill(Color.white.opacity(0.001))  // Nearly invisible base for shader
                    .colorEffect(
                        ShaderLibrary.themeGradient(
                            .float2(area),
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
