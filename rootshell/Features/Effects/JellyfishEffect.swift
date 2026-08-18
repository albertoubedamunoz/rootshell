//
//  JellyfishEffect.swift
//  rootshell
//
//  Bioluminescent jellyfish that occasionally drift across the terminal
//  background — slower and calmer than any other effect. Rendered
//  procedurally in a single Canvas pass; the render timeline is fully
//  paused between visits so the effect costs nothing while idle. On dark
//  themes they glow under the additive overlay blend; on light themes they
//  read as an ink-wash drawing under multiply.
//

import SwiftUI
import Combine

// MARK: - Jellyfish Colors

/// Color set for one jellyfish, pre-tuned for the overlay blend mode:
/// additive (plusLighter) on dark themes wants luminous glow, multiply on
/// light themes wants dark sumi-e ink.
struct JellyfishColors {
    let bell: Color
    let rim: Color
    let glow: Color
    let tentacle: Color
    let oralArm: Color
    let core: Color
    let shimmer: Color
}

// MARK: - Jellyfish Effect

/// Jellyfish visual effect: occasional bioluminescent drifters
final class JellyfishEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    let id = "jellyfish"
    let displayName = String(localized: "Jellyfish", comment: "Background effect name: jellyfish")
    let previewIcon = "water.waves"
    let effectDescription = String(localized: "Bioluminescent drifters pulse across occasionally", comment: "Background effect description for jellyfish")

    var intensity: Double = 0.20 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 0.5 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Jellyfish-Specific Configuration

    /// How often visits occur
    var visitFrequency: JellyfishVisitState.VisitFrequency = .occasional {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Larger blooms per visit
    var moreJellyfish: Bool = false {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Rare brightening ripple down the tentacles (dark themes only)
    var shimmerEnabled: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Drift clear of on-screen terminal text and the cursor
    var textAvoidanceEnabled: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Color mode for theming
    enum ColorMode: String, Codable, CaseIterable {
        case moonJelly       // Pale blue-white
        case bioluminescent  // Cyan/teal glow
        case cosmic          // Violet/magenta
        case themeAdaptive   // Theme-tinted cyan on dark, indigo ink on light

        var displayName: String {
            switch self {
            case .moonJelly: return String(localized: "Moon Jelly", comment: "Jellyfish color mode: pale blue-white")
            case .bioluminescent: return String(localized: "Bioluminescent", comment: "Jellyfish color mode: cyan-teal glow")
            case .cosmic: return String(localized: "Cosmic", comment: "Jellyfish color mode: violet-magenta")
            case .themeAdaptive: return String(localized: "Theme Adaptive", comment: "Jellyfish color mode: adapts to light/dark theme")
            }
        }
    }

    var colorMode: ColorMode = .themeAdaptive {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Fired by the settings "Visit Now" button; every live view (settings
    /// preview and terminal overlay) responds by spawning a visit.
    let visitRequested = PassthroughSubject<Void, Never>()

    func requestVisit() {
        visitRequested.send()
    }

    // MARK: - TerminalEffect Implementation

    func createEffectView() -> AnyView {
        AnyView(JellyfishView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.20
        speed = 0.5
        visitFrequency = .occasional
        moreJellyfish = false
        shimmerEnabled = true
        textAvoidanceEnabled = true
        colorMode = .themeAdaptive
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "visitFrequency": visitFrequency.rawValue,
            "moreJellyfish": moreJellyfish,
            "shimmerEnabled": shimmerEnabled,
            "textAvoidanceEnabled": textAvoidanceEnabled,
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
        if let frequencyRaw = data["visitFrequency"] as? String,
           let frequency = JellyfishVisitState.VisitFrequency(rawValue: frequencyRaw) {
            self.visitFrequency = frequency
        }
        if let moreJellyfish = data["moreJellyfish"] as? Bool {
            self.moreJellyfish = moreJellyfish
        }
        if let shimmerEnabled = data["shimmerEnabled"] as? Bool {
            self.shimmerEnabled = shimmerEnabled
        }
        if let textAvoidanceEnabled = data["textAvoidanceEnabled"] as? Bool {
            self.textAvoidanceEnabled = textAvoidanceEnabled
        }
        if let colorModeRaw = data["colorMode"] as? String,
           let colorMode = ColorMode(rawValue: colorModeRaw) {
            self.colorMode = colorMode
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

    private static let moonBase = RGB(r: 0.78, g: 0.86, b: 0.96)
    private static let bioBase = RGB(r: 0.25, g: 0.85, b: 0.80)
    private static let cosmicBase = RGB(r: 0.62, g: 0.40, b: 0.95)
    private static let inkBase = RGB(r: 0.24, g: 0.28, b: 0.45)   // deep indigo for light-theme ink wash

    /// Whether the current theme background is light (chooses blend tuning)
    var isLightBackground: Bool {
        guard let bg = RGB.fromHex(themeColors.background) else { return false }
        return bg.luminance > 0.5
    }

    private func baseRGB(colorIndex: Int) -> RGB {
        var base: RGB
        switch colorMode {
        case .moonJelly:
            base = Self.moonBase
        case .bioluminescent:
            base = Self.bioBase
        case .cosmic:
            base = Self.cosmicBase
        case .themeAdaptive:
            if isLightBackground {
                base = Self.inkBase
            } else {
                // Tint the glow toward the theme's cyan when available
                base = Self.bioBase
                if themeColors.palette.count > 6, let tint = RGB.fromHex(themeColors.palette[6]) {
                    base = base.mixed(toward: tint, 0.35)
                }
            }
        }

        // Subtle per-jelly hue variation on dark themes; the light-theme ink
        // wash stays uniform
        if !isLightBackground {
            let partner = colorMode == .cosmic ? Self.bioBase : Self.cosmicBase
            base = base.mixed(toward: partner, Double(colorIndex % 3) * 0.10)
        }

        // Keep the jelly visible under the overlay blend: additive blending
        // swallows dark colors, multiply swallows light ones
        if isLightBackground {
            if base.luminance > 0.7 { base = base.mixed(toward: .black, 0.4) }
        } else {
            if base.luminance < 0.3 { base = base.mixed(toward: .white, 0.35) }
        }
        return base
    }

    /// Full color set for one jellyfish, tuned per blend mode
    func colors(colorIndex: Int) -> JellyfishColors {
        let base = baseRGB(colorIndex: colorIndex)
        if isLightBackground {
            // Multiply: sumi-e ink — a darker rim outline replaces the glow
            return JellyfishColors(
                bell: base.mixed(toward: .black, 0.30).color,
                rim: base.mixed(toward: .black, 0.65).color,
                glow: base.color,
                tentacle: base.mixed(toward: .black, 0.50).color,
                oralArm: base.mixed(toward: .black, 0.40).color,
                core: base.mixed(toward: .black, 0.75).color,
                shimmer: base.color
            )
        } else {
            // Additive: translucent luminous dome with a glowing margin
            return JellyfishColors(
                bell: base.color,
                rim: base.mixed(toward: .white, 0.45).color,
                glow: base.color,
                tentacle: base.mixed(toward: .white, 0.25).color,
                oralArm: base.mixed(toward: .white, 0.15).color,
                core: base.mixed(toward: .white, 0.60).color,
                shimmer: base.mixed(toward: .white, 0.85).color
            )
        }
    }
}

// MARK: - Jellyfish View

struct JellyfishView: View {
    let effect: JellyfishEffect
    var previewMode: Bool = false

    @StateObject private var state = JellyfishVisitState()

    /// 30fps baseline, halved in battery saver.
    private var frameInterval: Double {
        (1.0 / 30.0) * PowerManager.shared.effectIntervalScale
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: frameInterval, paused: state.isIdle)) { timeline in
                let frameTime = state.frameTime(at: timeline.date)

                Canvas { context, size in
                    for jelly in state.jellies {
                        drawJellyfish(jelly, at: frameTime, context: context, canvasSize: size)
                    }
                }
                .onChange(of: timeline.date) { _, newDate in
                    state.update(frameTime: state.frameTime(at: newDate))
                }
            }
            .onAppear {
                state.viewSize = geometry.size
                state.canvasFrameInGlobal = geometry.frame(in: .global)
                state.start(effect: effect, previewMode: previewMode)
            }
            .onChange(of: geometry.size) { _, newSize in
                state.viewSize = newSize
            }
            .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                state.canvasFrameInGlobal = newFrame
            }
            .onDisappear {
                state.stop()
            }
            .onReceive(effect.visitRequested) {
                state.forceSpawn()
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drawing

    /// Draw one jellyfish. The bell is built in a unit space (rim center at
    /// the origin, apex at (0,-1)) and placed with `bellTransform`; the
    /// tentacle chains are already in world coordinates.
    private func drawJellyfish(_ jelly: Jellyfish, at time: TimeInterval, context: GraphicsContext, canvasSize: CGSize) {
        guard time >= jelly.spawnFrameTime else { return }
        let position = jelly.renderPosition(at: time, in: canvasSize)

        // Cull fully offscreen jellies; the pad covers the trailing chains
        let cull = jelly.bellRadius * 8 + 40
        guard position.x > -cull, position.x < canvasSize.width + cull,
              position.y > -cull, position.y < canvasSize.height + cull else { return }

        let colors = effect.colors(colorIndex: jelly.colorIndex)
        let isLight = effect.isLightBackground
        let transform = jelly.bellTransform(at: time, in: canvasSize)

        context.drawLayer { layer in
            layer.opacity = min(effect.intensity / 0.6, 1.0)

            // Soft bloom under additive blending only
            if !isLight {
                let center = CGPoint(x: 0, y: -0.35).applying(transform)
                let glowR = jelly.bellRadius * 2.6
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - glowR, y: center.y - glowR,
                                           width: glowR * 2, height: glowR * 2)),
                    with: .radialGradient(
                        Gradient(colors: [colors.glow.opacity(0.16), .clear]),
                        center: center, startRadius: 0, endRadius: glowR))
            }

            // Chains draw behind the bell so their attachment stays hidden;
            // skipped until the physics has seeded them
            if jelly.lastSimTime != nil {
                drawOralArms(jelly, transform: transform, colors: colors, in: &layer)
                drawTentacles(jelly, at: time, transform: transform, colors: colors, isLight: isLight, in: &layer)
            }

            drawBell(jelly, transform: transform, colors: colors, isLight: isLight, in: &layer)
        }
    }

    /// Midpoint-smoothed path through a chain of nodes
    private func chainPath(from anchor: CGPoint, nodes: ArraySlice<CGPoint>) -> Path {
        var path = Path()
        path.move(to: anchor)
        var prev = anchor
        for node in nodes {
            let mid = CGPoint(x: (prev.x + node.x) / 2, y: (prev.y + node.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = node
        }
        path.addLine(to: prev)
        return path
    }

    private func drawOralArms(_ jelly: Jellyfish, transform: CGAffineTransform, colors: JellyfishColors, in ctx: inout GraphicsContext) {
        let r = jelly.bellRadius
        for chain in jelly.oralArmAnchorX.indices {
            let anchor = CGPoint(x: jelly.oralArmAnchorX[chain], y: 0.08).applying(transform)
            let start = chain * jelly.oralArmNodesPer
            let slice = jelly.oralArmNodes[start..<(start + jelly.oralArmNodesPer)]
            guard let tip = slice.last else { continue }
            let path = chainPath(from: anchor, nodes: slice)

            // Wide faint ribbon under a narrow brighter core reads frilly
            ctx.stroke(path, with: .color(colors.oralArm.opacity(0.18)), lineWidth: r * 0.14)
            ctx.stroke(path, with: .linearGradient(
                Gradient(colors: [colors.oralArm.opacity(0.50), colors.oralArm.opacity(0.05)]),
                startPoint: anchor, endPoint: tip),
                lineWidth: r * 0.05)
        }
    }

    private func drawTentacles(_ jelly: Jellyfish, at time: TimeInterval, transform: CGAffineTransform, colors: JellyfishColors, isLight: Bool, in ctx: inout GraphicsContext) {
        let shimmer = (!isLight && effect.shimmerEnabled) ? jelly.shimmer(at: time) : nil

        for chain in jelly.tentacleAnchorX.indices {
            let anchor = CGPoint(x: jelly.tentacleAnchorX[chain], y: 0.02).applying(transform)
            let start = chain * jelly.tentacleNodesPer
            let slice = jelly.tentacleNodes[start..<(start + jelly.tentacleNodesPer)]
            guard let tip = slice.last else { continue }
            let path = chainPath(from: anchor, nodes: slice)

            var stops: [Gradient.Stop] = [
                .init(color: colors.tentacle.opacity(isLight ? 0.50 : 0.55), location: 0),
                .init(color: colors.tentacle.opacity(0), location: 1)
            ]
            // The shimmer is one moving bright stop riding down the gradient
            if let shimmer {
                let head = min(max(shimmer.head, 0.02), 0.98)
                stops.append(.init(color: colors.shimmer.opacity(0.9 * shimmer.strength), location: head))
                stops.sort { $0.location < $1.location }
            }

            ctx.stroke(path, with: .linearGradient(
                Gradient(stops: stops), startPoint: anchor, endPoint: tip),
                lineWidth: max(jelly.bellRadius * 0.035, 0.8))
        }
    }

    private func drawBell(_ jelly: Jellyfish, transform: CGAffineTransform, colors: JellyfishColors, isLight: Bool, in ctx: inout GraphicsContext) {
        let r = jelly.bellRadius

        // Dome with a gently scalloped underside, in unit bell space
        var dome = Path()
        dome.move(to: CGPoint(x: -1, y: 0))
        dome.addCurve(to: CGPoint(x: 0, y: -1),
                      control1: CGPoint(x: -1.02, y: -0.58),
                      control2: CGPoint(x: -0.58, y: -1.0))
        dome.addCurve(to: CGPoint(x: 1, y: 0),
                      control1: CGPoint(x: 0.58, y: -1.0),
                      control2: CGPoint(x: 1.02, y: -0.58))
        dome.addQuadCurve(to: CGPoint(x: 0.5, y: 0.05), control: CGPoint(x: 0.78, y: 0.16))
        dome.addQuadCurve(to: CGPoint(x: 0.0, y: 0.05), control: CGPoint(x: 0.25, y: 0.16))
        dome.addQuadCurve(to: CGPoint(x: -0.5, y: 0.05), control: CGPoint(x: -0.25, y: 0.16))
        dome.addQuadCurve(to: CGPoint(x: -1, y: 0), control: CGPoint(x: -0.78, y: 0.16))
        dome.closeSubpath()
        let bellPath = dome.applying(transform)

        let apex = CGPoint(x: 0, y: -1).applying(transform)
        let rim = CGPoint(x: 0, y: 0.1).applying(transform)
        ctx.fill(bellPath, with: .linearGradient(
            Gradient(colors: [colors.bell.opacity(isLight ? 0.28 : 0.35), colors.bell.opacity(0.06)]),
            startPoint: apex, endPoint: rim))
        // On light themes a wider dark rim outline replaces the glow
        ctx.stroke(bellPath, with: .color(colors.rim.opacity(isLight ? 0.75 : 0.80)),
                   lineWidth: r * (isLight ? 0.05 : 0.03))

        // Four-lobed gonad ring near the apex — the detail that makes the
        // silhouette read "jellyfish" at a glance
        for lobe in 0..<4 {
            let angle = Double(lobe) * .pi / 2 + .pi / 4
            let cx = cos(angle) * 0.30
            let cy = -0.48 + sin(angle) * 0.21
            let gonad = Path(ellipseIn: CGRect(x: cx - 0.13, y: cy - 0.10, width: 0.26, height: 0.20))
                .applying(transform)
            ctx.fill(gonad, with: .color(colors.core.opacity(0.45)))
        }
    }
}
