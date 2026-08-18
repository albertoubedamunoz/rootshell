//
//  FirefliesEffect.swift
//  rootshell
//
//  Glowing particles with organic flight paths using Lissajous curves
//

import SwiftUI
import Combine

// MARK: - Firefly Particle

/// Individual firefly particle state
struct Firefly: Identifiable {
    let id: UUID

    // Spawn position and path parameters
    var spawnPosition: CGPoint
    var lissajousA: Double          // Horizontal amplitude fraction (0.05-0.15)
    var lissajousB: Double          // Vertical amplitude fraction (0.03-0.10)
    var freqX: Double               // X frequency (0.1-0.3 Hz)
    var freqY: Double               // Y frequency (0.1-0.3 Hz, intentionally incommensurate)
    var phaseX: Double              // X phase offset (0-2pi)
    var phaseY: Double              // Y phase offset (0-2pi)

    // Pulse/glow parameters
    var pulsePhase: Double          // Starting phase for brightness (0-2pi)
    var pulseFrequency: Double      // Pulse rate (0.2-0.8 Hz)
    var baseAlpha: Double           // Minimum brightness (0.1-0.3)
    var peakAlpha: Double           // Maximum brightness (0.6-0.9)

    // Size parameters
    var coreSize: CGFloat           // Core glow size (2-5 points)
    var glowRadius: CGFloat         // Outer glow blur radius (8-20 points)

    // Lifecycle
    var birthTime: TimeInterval     // When particle was spawned
    var lifespan: TimeInterval      // Total lifespan (30-90 seconds)

    // Color variation for fairy lights mode
    var colorIndex: Int             // Palette index for this firefly

    /// Calculate position at given time
    func position(at time: TimeInterval, in bounds: CGSize) -> CGPoint {
        let effectiveTime = time - birthTime

        // Lissajous base motion
        let lissX = sin(freqX * effectiveTime * 2 * .pi + phaseX) * lissajousA * bounds.width
        let lissY = sin(freqY * effectiveTime * 2 * .pi + phaseY) * lissajousB * bounds.height

        return CGPoint(
            x: spawnPosition.x + lissX,
            y: spawnPosition.y + lissY
        )
    }

    /// Calculate brightness at given time (0.0-1.0)
    func brightness(at time: TimeInterval) -> Double {
        let effectiveTime = time - birthTime

        // Fade in during first 2 seconds
        let fadeIn = min(effectiveTime / 2.0, 1.0)

        // Fade out during last 3 seconds of lifespan
        let timeRemaining = lifespan - effectiveTime
        let fadeOut = min(timeRemaining / 3.0, 1.0)

        // Asymmetric pulse wave
        let phase = pulsePhase + effectiveTime * pulseFrequency * 2 * .pi
        let cyclePosition = (phase / (2 * .pi)).truncatingRemainder(dividingBy: 1.0)
        let normalizedCycle = cyclePosition < 0 ? cyclePosition + 1 : cyclePosition

        let pulse: Double
        if normalizedCycle < 0.3 {
            // Rise (30% of cycle) - quick
            pulse = smootherstep(0, 0.3, normalizedCycle)
        } else if normalizedCycle < 0.5 {
            // Hold bright (20% of cycle)
            pulse = 1.0
        } else {
            // Decay (50% of cycle) - slow
            pulse = 1.0 - smootherstep(0.5, 1.0, normalizedCycle)
        }

        // Map to alpha range
        let alpha = baseAlpha + (peakAlpha - baseAlpha) * pulse

        // Apply lifecycle fades
        return alpha * fadeIn * max(fadeOut, 0)
    }

    /// Smootherstep for smooth transitions (C2 continuous)
    private func smootherstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Check if firefly has expired
    func isExpired(at time: TimeInterval) -> Bool {
        return time - birthTime > lifespan
    }
}

// MARK: - Fireflies Effect

/// Fireflies visual effect with organic glowing particles
final class FirefliesEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    let id = "fireflies"
    let displayName = String(localized: "Fireflies", comment: "Background effect name: fireflies")
    let previewIcon = "sparkle"
    let effectDescription = String(localized: "Glowing particles with organic flight", comment: "Background effect description for fireflies")

    var intensity: Double = 0.35 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Firefly-Specific Configuration

    /// Number of fireflies (10-100)
    var fireflyCount: Int = 30 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Glow size multiplier (0.5-2.0)
    var glowSize: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Color mode for theming
    enum ColorMode: String, Codable, CaseIterable {
        case fireflies       // Warm amber/yellow
        case bioluminescence // Cool cyan/blue
        case fairyLights     // Multi-color from palette
        case themeAdaptive   // Picks based on light/dark theme

        var displayName: String {
            switch self {
            case .fireflies: return String(localized: "Fireflies", comment: "Fireflies color mode: warm amber/yellow")
            case .bioluminescence: return String(localized: "Bioluminescence", comment: "Fireflies color mode: cool cyan/blue")
            case .fairyLights: return String(localized: "Fairy Lights", comment: "Fireflies color mode: multi-color from palette")
            case .themeAdaptive: return String(localized: "Theme Adaptive", comment: "Fireflies color mode: adapts to light/dark theme")
            }
        }
    }

    var colorMode: ColorMode = .themeAdaptive {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    // MARK: - TerminalEffect Implementation

    func createEffectView() -> AnyView {
        AnyView(FirefliesView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.35
        speed = 1.0
        fireflyCount = 30
        glowSize = 1.0
        colorMode = .themeAdaptive
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "fireflyCount": fireflyCount,
            "glowSize": glowSize,
            "colorMode": colorMode.rawValue
        ]
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = intensity
        }
        if let speed = data["speed"] as? Double {
            self.speed = speed
        }
        if let fireflyCount = data["fireflyCount"] as? Int {
            self.fireflyCount = fireflyCount
        }
        if let glowSize = data["glowSize"] as? Double {
            self.glowSize = glowSize
        }
        if let colorModeRaw = data["colorMode"] as? String,
           let colorMode = ColorMode(rawValue: colorModeRaw) {
            self.colorMode = colorMode
        }
    }

    // MARK: - Color Derivation

    /// Check if current theme is light
    private var isLightTheme: Bool {
        guard let bgColor = Color(hex: themeColors.background) else { return false }
        return UIColor(bgColor).isLight
    }

    /// Primary firefly color based on mode
    var primaryColor: Color {
        switch colorMode {
        case .fireflies:
            // Warm amber - use palette index 3 (yellow)
            if themeColors.palette.count > 3,
               let color = Color(hex: themeColors.palette[3]) {
                return color
            }
            return Color(red: 1.0, green: 0.8, blue: 0.3)

        case .bioluminescence:
            // Cool cyan - use palette index 6 (cyan)
            if themeColors.palette.count > 6,
               let color = Color(hex: themeColors.palette[6]) {
                return color
            }
            return Color(red: 0.2, green: 0.9, blue: 0.8)

        case .fairyLights:
            // Primary used as fallback
            return Color.white

        case .themeAdaptive:
            if isLightTheme {
                // Light theme: use bioluminescence (stands out better)
                if themeColors.palette.count > 6,
                   let color = Color(hex: themeColors.palette[6]) {
                    return color
                }
                return Color(red: 0.2, green: 0.9, blue: 0.8)
            } else {
                // Dark theme: use warm fireflies
                if themeColors.palette.count > 3,
                   let color = Color(hex: themeColors.palette[3]) {
                    return color
                }
                return Color(red: 1.0, green: 0.8, blue: 0.3)
            }
        }
    }

    /// Get color for specific firefly (for fairy lights mode)
    func color(for firefly: Firefly) -> Color {
        if colorMode == .fairyLights, !themeColors.palette.isEmpty {
            let paletteSize = min(themeColors.palette.count, 8)
            let index = firefly.colorIndex % paletteSize
            if let color = Color(hex: themeColors.palette[index]) {
                return color
            }
        }
        return primaryColor
    }
}

// MARK: - UIColor Light Detection Extension

private extension UIColor {
    var isLight: Bool {
        var white: CGFloat = 0
        getWhite(&white, alpha: nil)
        return white > 0.5
    }
}

// MARK: - Fireflies View

struct FirefliesView: View {
    let effect: FirefliesEffect

    @State private var fireflies: [Firefly] = []
    @State private var startTime = Date.now
    @State private var viewSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: (1.0 / 30.0) * PowerManager.shared.effectIntervalScale)) { timeline in
                let currentTime = startTime.distance(to: timeline.date) * effect.speed

                ZStack {
                    ForEach(fireflies) { firefly in
                        if !firefly.isExpired(at: currentTime) {
                            FireflyView(
                                firefly: firefly,
                                position: firefly.position(at: currentTime, in: geometry.size),
                                brightness: firefly.brightness(at: currentTime) * effect.intensity,
                                color: effect.color(for: firefly),
                                glowMultiplier: effect.glowSize
                            )
                        }
                    }
                }
                .drawingGroup()
                .onChange(of: currentTime) { _, newTime in
                    updatePopulation(at: newTime, in: geometry.size)
                }
            }
            .onAppear {
                viewSize = geometry.size
                initializeFireflies(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                viewSize = newSize
            }
            .onChange(of: effect.fireflyCount) { _, _ in
                // Re-initialize when count changes significantly
                let time = startTime.distance(to: Date.now) * effect.speed
                updatePopulation(at: time, in: viewSize)
            }
        }
        .allowsHitTesting(false)
    }

    private func initializeFireflies(in size: CGSize) {
        fireflies = []
        for _ in 0..<effect.fireflyCount {
            fireflies.append(spawnFirefly(at: 0, in: size, staggered: true))
        }
    }

    private func updatePopulation(at time: TimeInterval, in size: CGSize) {
        // Remove expired fireflies
        fireflies.removeAll { $0.isExpired(at: time) }

        // Spawn new fireflies to maintain target count
        while fireflies.count < effect.fireflyCount {
            fireflies.append(spawnFirefly(at: time, in: size, staggered: false))
        }

        // Remove excess if count was lowered
        while fireflies.count > effect.fireflyCount {
            fireflies.removeLast()
        }
    }

    private func spawnFirefly(at time: TimeInterval, in size: CGSize, staggered: Bool) -> Firefly {
        // Random spawn position (bias slightly toward center)
        let spawnX = size.width * (0.1 + Double.random(in: 0...0.8))
        let spawnY = size.height * (0.1 + Double.random(in: 0...0.8))

        // Lissajous parameters with intentionally incommensurate frequencies
        // Use ratios near golden ratio for organic, non-repeating patterns
        let goldenRatio = 1.618033988749895
        let baseFreq = Double.random(in: 0.08...0.2)

        // Randomize lifespan - stagger initial fireflies across their lifespans
        let lifespan = Double.random(in: 30...90)
        let birthOffset = staggered ? Double.random(in: 0...lifespan) : 0

        return Firefly(
            id: UUID(),
            spawnPosition: CGPoint(x: spawnX, y: spawnY),
            lissajousA: Double.random(in: 0.05...0.15),
            lissajousB: Double.random(in: 0.03...0.10),
            freqX: baseFreq,
            freqY: baseFreq * goldenRatio * Double.random(in: 0.9...1.1),
            phaseX: Double.random(in: 0...(2 * .pi)),
            phaseY: Double.random(in: 0...(2 * .pi)),
            pulsePhase: Double.random(in: 0...(2 * .pi)),
            pulseFrequency: Double.random(in: 0.2...0.8),
            baseAlpha: Double.random(in: 0.1...0.3),
            peakAlpha: Double.random(in: 0.6...0.9),
            coreSize: CGFloat.random(in: 2...5),
            glowRadius: CGFloat.random(in: 10...20),
            birthTime: time - birthOffset,
            lifespan: lifespan,
            colorIndex: Int.random(in: 0...7)
        )
    }
}

// MARK: - Individual Firefly View

struct FireflyView: View {
    let firefly: Firefly
    let position: CGPoint
    let brightness: Double
    let color: Color
    let glowMultiplier: Double

    var body: some View {
        let scaledGlow = firefly.glowRadius * glowMultiplier
        let scaledCore = firefly.coreSize * glowMultiplier

        ZStack {
            // Outer glow (large blur)
            Circle()
                .fill(color.opacity(brightness * 0.15))
                .frame(width: scaledGlow * 3, height: scaledGlow * 3)
                .blur(radius: scaledGlow * 1.5)

            // Inner glow (medium blur)
            Circle()
                .fill(color.opacity(brightness * 0.4))
                .frame(width: scaledGlow * 1.5, height: scaledGlow * 1.5)
                .blur(radius: scaledGlow * 0.7)

            // Core (small, brightest)
            Circle()
                .fill(color.opacity(brightness * 0.8))
                .frame(width: scaledCore, height: scaledCore)
                .blur(radius: scaledCore * 0.3)
        }
        .position(position)
    }
}
