//
//  ButterfliesEffect.swift
//  rootshell
//
//  Whimsical butterflies that occasionally visit the terminal background.
//  Rendered procedurally in a single Canvas pass; the render timeline is
//  fully paused between visits so the effect costs nothing while idle.
//

import SwiftUI
import Combine

// MARK: - Wing Colors

/// Color set for one butterfly, pre-tuned for the overlay blend mode:
/// additive (plusLighter) on dark themes wants luminous "stained glass",
/// multiply on light themes wants deep saturated "ink".
struct ButterflyWingColors {
    let fill: Color
    let edge: Color
    let accent: Color
    let body: Color
}

// MARK: - Butterflies Effect

/// Butterflies visual effect: occasional visitors drifting across the screen
final class ButterfliesEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    let id = "butterflies"
    let displayName = String(localized: "Butterflies", comment: "Background effect name: butterflies")
    let previewIcon = "camera.macro"
    let effectDescription = String(localized: "Whimsical visitors drift across occasionally", comment: "Background effect description for butterflies")

    var intensity: Double = 0.17 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 0.6 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Butterfly-Specific Configuration

    /// How often visits occur
    var visitFrequency: ButterflyVisitState.VisitFrequency = .occasional {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Larger groups per visit
    var moreButterflies: Bool = false {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Butterflies sometimes pause mid-crossing to rest
    var perchingEnabled: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Rapid wing beats during flight. Off = calm gliding only (less
    /// realistic, less distracting).
    var flutterEnabled: Bool = false {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Steer around on-screen terminal text and the cursor
    var textAvoidanceEnabled: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Color mode for theming
    enum ColorMode: String, Codable, CaseIterable {
        case garden          // Multi-color from theme palette
        case monarch         // Warm orange/amber
        case morpho          // Luminous blue
        case themeAdaptive   // Morpho on dark themes, Monarch on light
        case glasswing       // Transparent wings with dark amber borders (Greta oto)

        var displayName: String {
            switch self {
            case .garden: return String(localized: "Garden", comment: "Butterfly color mode: multi-color from theme palette")
            case .monarch: return String(localized: "Monarch", comment: "Butterfly color mode: warm orange")
            case .morpho: return String(localized: "Morpho", comment: "Butterfly color mode: luminous blue")
            case .themeAdaptive: return String(localized: "Theme Adaptive", comment: "Butterfly color mode: adapts to light/dark theme")
            case .glasswing: return String(localized: "Glasswing", comment: "Butterfly color mode: translucent clearwing with amber borders")
            }
        }
    }

    var colorMode: ColorMode = .garden {
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
        AnyView(ButterfliesView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.17
        speed = 0.6
        visitFrequency = .occasional
        moreButterflies = false
        perchingEnabled = true
        flutterEnabled = false
        textAvoidanceEnabled = true
        colorMode = .garden
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "visitFrequency": visitFrequency.rawValue,
            "moreButterflies": moreButterflies,
            "perchingEnabled": perchingEnabled,
            "flutterEnabled": flutterEnabled,
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
           let frequency = ButterflyVisitState.VisitFrequency(rawValue: frequencyRaw) {
            self.visitFrequency = frequency
        }
        if let moreButterflies = data["moreButterflies"] as? Bool {
            self.moreButterflies = moreButterflies
        }
        if let perchingEnabled = data["perchingEnabled"] as? Bool {
            self.perchingEnabled = perchingEnabled
        }
        if let flutterEnabled = data["flutterEnabled"] as? Bool {
            self.flutterEnabled = flutterEnabled
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

    private static let monarchBase = RGB(r: 1.0, g: 0.55, b: 0.15)
    private static let morphoBase = RGB(r: 0.30, g: 0.55, b: 1.0)
    // Glasswing's color identity is its border, not its (clear) membrane
    private static let glasswingBorder = RGB(r: 0.62, g: 0.42, b: 0.24)  // warm amber-brown margin

    /// Whether the current theme background is light (chooses blend tuning)
    var isLightBackground: Bool {
        guard let bg = RGB.fromHex(themeColors.background) else { return false }
        return bg.luminance > 0.5
    }

    private func baseRGB(colorIndex: Int) -> RGB {
        var base: RGB
        switch colorMode {
        case .monarch:
            base = Self.monarchBase
        case .morpho:
            base = Self.morphoBase
        case .garden:
            let paletteSize = min(themeColors.palette.count, 8)
            if paletteSize > 0, let rgb = RGB.fromHex(themeColors.palette[colorIndex % paletteSize]) {
                base = rgb
            } else {
                base = Self.morphoBase
            }
        case .themeAdaptive:
            base = isLightBackground ? Self.monarchBase : Self.morphoBase
        case .glasswing:
            // Unreachable: wingColors() short-circuits glasswing before
            // baseRGB(). Fall back to the amber border tint for safety.
            base = Self.glasswingBorder
        }

        // Keep wings visible under the overlay blend: additive blending
        // swallows dark colors, multiply swallows light ones
        if isLightBackground {
            if base.luminance > 0.7 { base = base.mixed(toward: .black, 0.4) }
        } else {
            if base.luminance < 0.3 { base = base.mixed(toward: .white, 0.35) }
        }
        return base
    }

    /// Glasswing (clearwing) color set: a near-clear membrane tint plus an
    /// amber/brown border. The membrane *opacity* is applied in the render
    /// branch — these are just the hues. Membrane and border are different
    /// hues, so this can't be derived from a single `baseRGB`.
    private func glasswingColors() -> ButterflyWingColors {
        let border = Self.glasswingBorder
        if isLightBackground {        // multiply: clear-ish membrane, deep amber margin
            return ButterflyWingColors(
                fill:   RGB(r: 0.92, g: 0.94, b: 0.96).color,     // faint cool glass
                edge:   border.mixed(toward: .black, 0.35).color, // dark amber border
                accent: border.color,                              // amber forewing-tip band
                body:   RGB(r: 0.22, g: 0.18, b: 0.15).color
            )
        } else {                      // additive: cool frost membrane, glowing amber margin
            return ButterflyWingColors(
                fill:   RGB(r: 0.80, g: 0.88, b: 0.95).color,     // cool frost (adds little)
                edge:   border.mixed(toward: .white, 0.35).color, // luminous amber border
                accent: border.mixed(toward: .white, 0.50).color, // bright amber tip
                body:   RGB(r: 0.55, g: 0.50, b: 0.46).color
            )
        }
    }

    /// Full color set for one butterfly, tuned per blend mode
    func wingColors(colorIndex: Int) -> ButterflyWingColors {
        if colorMode == .glasswing { return glasswingColors() }
        let base = baseRGB(colorIndex: colorIndex)
        if isLightBackground {
            // Multiply: deeper = more visible, accents read as ink
            return ButterflyWingColors(
                fill: base.mixed(toward: .black, 0.25).color,
                edge: base.mixed(toward: .black, 0.55).color,
                accent: base.mixed(toward: .black, 0.78).color,
                body: RGB(r: 0.25, g: 0.21, b: 0.18).color
            )
        } else {
            // Additive: stained glass with a glowing rim and bright spots
            return ButterflyWingColors(
                fill: base.color,
                edge: base.mixed(toward: .white, 0.40).color,
                accent: base.mixed(toward: .white, 0.80).color,
                body: RGB(r: 0.60, g: 0.55, b: 0.50).color
            )
        }
    }
}

// MARK: - Butterflies View

struct ButterfliesView: View {
    let effect: ButterfliesEffect
    var previewMode: Bool = false

    @StateObject private var state = ButterflyVisitState()

    /// 30fps baseline, halved in battery saver.
    private var frameInterval: Double {
        (1.0 / 30.0) * PowerManager.shared.effectIntervalScale
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: frameInterval, paused: state.isIdle)) { timeline in
                let frameTime = state.frameTime(at: timeline.date)

                Canvas { context, size in
                    for butterfly in state.butterflies {
                        drawButterfly(butterfly, at: frameTime, context: context, canvasSize: size)
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

    /// Draw one butterfly. Geometry is built in a unit space (body length 1,
    /// origin at the thorax, head toward -y) and placed with a layer
    /// transform; the wing flap is baked in by scaling wing x-coordinates.
    private func drawButterfly(_ butterfly: Butterfly, at time: TimeInterval, context: GraphicsContext, canvasSize: CGSize) {
        let position = butterfly.renderPosition(at: time, in: canvasSize)

        // Cull anything fully offscreen (entries/exits and staggered spawns).
        // Pad by the max offset (the raised text-avoidance cap) so a butterfly
        // that's veering off its lane is never culled while still visible.
        let cull = butterfly.size * 2 + 120
        guard position.x > -cull, position.x < canvasSize.width + cull,
              position.y > -cull, position.y < canvasSize.height + cull else { return }

        let heading = butterfly.renderHeading(at: time, in: canvasSize)
        // Startle/excitement opens the wings wider and jolts the body, so an
        // evasive veer or a courtship pass visibly flutters. Zero for glide-only
        // butterflies (and under Reduce Motion, where agitation never rises).
        let agitation = butterfly.glideOnly ? 0 : butterfly.agitation
        let wingBoost = 1 + 0.4 * agitation
        let foreScale = max(butterfly.wingScale(at: time) * wingBoost, 0.12)
        // Hindwings trail the forewings slightly; the lag is what makes the
        // flap read as alive rather than mechanical
        let hindScale = max(0.9 * butterfly.wingScale(at: time, lag: -0.35) * wingBoost, 0.10)
        let flapPhase = butterfly.flapPhase(at: time)
        let colors = effect.wingColors(colorIndex: butterfly.colorIndex)
        let isLight = effect.isLightBackground
        let glasswing = effect.colorMode == .glasswing

        context.drawLayer { layer in
            layer.opacity = min(effect.intensity / 0.6, 1.0)
            layer.translateBy(x: position.x, y: position.y)
            layer.rotate(by: Angle(radians: heading + .pi / 2))
            layer.scaleBy(x: butterfly.size, y: butterfly.size)
            // Body bobs against the wing beat (held still when gliding only,
            // since the flap clock keeps running underneath); a startle
            // amplifies the bob into a visible jolt.
            if !butterfly.glideOnly {
                layer.translateBy(x: 0, y: -0.03 * (1 + 1.5 * agitation) * sin(2 * flapPhase))
            }

            // Soft halo under additive blending only
            if !isLight {
                let haloRect = CGRect(x: -1.1, y: -1.15, width: 2.2, height: 2.2)
                layer.fill(Path(ellipseIn: haloRect), with: .radialGradient(
                    Gradient(colors: [colors.fill.opacity(0.12), .clear]),
                    center: CGPoint(x: 0, y: -0.05),
                    startRadius: 0,
                    endRadius: 1.1
                ))
            }

            for side in [CGFloat(-1), CGFloat(1)] {
                drawWings(side: side, foreScale: foreScale, hindScale: hindScale, colors: colors, glasswing: glasswing, in: &layer)
            }
            drawBody(colors: colors, in: &layer)
        }
    }

    private func drawWings(side: CGFloat, foreScale: Double, hindScale: Double, colors: ButterflyWingColors, glasswing: Bool, in ctx: inout GraphicsContext) {
        let fx = side * CGFloat(foreScale)
        let hx = side * CGFloat(hindScale)

        // Glasswing: a near-clear membrane fades the fill almost out and an
        // opaque, thicker amber border carries the shape. Other species keep
        // a solid wing.
        let memTop = glasswing ? 0.18 : 1.0    // membrane opacity near the shoulder
        let memBot = glasswing ? 0.06 : 0.70   // …fading to clear at the trailing edge
        let hindBorder = glasswing ? 0.052 : 0.030
        let foreBorder = glasswing ? 0.060 : 0.035
        let veinOpacity = glasswing ? 0.6 : 0.5

        // Hindwing first so the forewing overlaps its leading edge
        var hind = Path()
        hind.move(to: CGPoint(x: 0.03 * hx, y: 0.02))
        hind.addCurve(to: CGPoint(x: 0.40 * hx, y: 0.28),
                      control1: CGPoint(x: 0.30 * hx, y: 0.02),
                      control2: CGPoint(x: 0.42 * hx, y: 0.14))
        hind.addCurve(to: CGPoint(x: 0.16 * hx, y: 0.44),
                      control1: CGPoint(x: 0.36 * hx, y: 0.40),
                      control2: CGPoint(x: 0.26 * hx, y: 0.47))
        hind.addQuadCurve(to: CGPoint(x: 0.02 * hx, y: 0.14),
                          control: CGPoint(x: 0.08 * hx, y: 0.30))
        hind.closeSubpath()

        ctx.fill(hind, with: .linearGradient(
            Gradient(colors: [colors.fill.opacity(memTop), colors.fill.opacity(memBot)]),
            startPoint: CGPoint(x: 0.05 * hx, y: 0.08),
            endPoint: CGPoint(x: 0.38 * hx, y: 0.38)
        ))
        ctx.stroke(hind, with: .color(colors.edge), lineWidth: hindBorder)

        // Forewing: rounded leading edge, gently scalloped trailing edge
        var fore = Path()
        fore.move(to: CGPoint(x: 0.03 * fx, y: -0.10))
        fore.addCurve(to: CGPoint(x: 0.58 * fx, y: -0.46),
                      control1: CGPoint(x: 0.20 * fx, y: -0.42),
                      control2: CGPoint(x: 0.45 * fx, y: -0.55))
        fore.addCurve(to: CGPoint(x: 0.40 * fx, y: -0.04),
                      control1: CGPoint(x: 0.60 * fx, y: -0.30),
                      control2: CGPoint(x: 0.52 * fx, y: -0.12))
        fore.addQuadCurve(to: CGPoint(x: 0.03 * fx, y: 0.0),
                          control: CGPoint(x: 0.20 * fx, y: 0.02))
        fore.closeSubpath()

        ctx.fill(fore, with: .linearGradient(
            Gradient(colors: [colors.fill.opacity(memTop), colors.fill.opacity(glasswing ? memBot : 0.72)]),
            startPoint: CGPoint(x: 0.05 * fx, y: -0.05),
            endPoint: CGPoint(x: 0.55 * fx, y: -0.45)
        ))
        ctx.stroke(fore, with: .color(colors.edge), lineWidth: foreBorder)

        // Single vein from the shoulder toward the tip
        var vein = Path()
        vein.move(to: CGPoint(x: 0.06 * fx, y: -0.10))
        vein.addQuadCurve(to: CGPoint(x: 0.50 * fx, y: -0.38),
                          control: CGPoint(x: 0.30 * fx, y: -0.30))
        ctx.stroke(vein, with: .color(colors.edge.opacity(veinOpacity)), lineWidth: 0.015)

        // Glasswing: one extra hindwing vein so the clear cells read as a
        // veined membrane rather than an empty outline.
        if glasswing {
            var hindVein = Path()
            hindVein.move(to: CGPoint(x: 0.05 * hx, y: 0.06))
            hindVein.addQuadCurve(to: CGPoint(x: 0.30 * hx, y: 0.30),
                                  control: CGPoint(x: 0.22 * hx, y: 0.16))
            ctx.stroke(hindVein, with: .color(colors.edge.opacity(veinOpacity)), lineWidth: 0.013)
        }

        // Accent spots near the forewing tip. Width squashes with the flap
        // (a circle on the folding wing projects to an ellipse).
        let squash = CGFloat(foreScale)
        let spot1 = CGRect(x: 0.42 * fx - 0.030 * squash, y: -0.34 - 0.030,
                           width: 0.060 * squash, height: 0.060)
        let spot2 = CGRect(x: 0.48 * fx - 0.022 * squash, y: -0.27 - 0.022,
                           width: 0.044 * squash, height: 0.044)
        ctx.fill(Path(ellipseIn: spot1), with: .color(colors.accent.opacity(0.9)))
        ctx.fill(Path(ellipseIn: spot2), with: .color(colors.accent.opacity(0.9)))
    }

    private func drawBody(colors: ButterflyWingColors, in ctx: inout GraphicsContext) {
        var body = Path()
        body.addEllipse(in: CGRect(x: -0.045, y: -0.215, width: 0.090, height: 0.090))  // head
        body.addEllipse(in: CGRect(x: -0.038, y: -0.150, width: 0.076, height: 0.220))  // thorax
        body.addEllipse(in: CGRect(x: -0.026, y: 0.020, width: 0.052, height: 0.320))   // abdomen
        ctx.fill(body, with: .color(colors.body))

        for side in [CGFloat(-1), CGFloat(1)] {
            var antenna = Path()
            antenna.move(to: CGPoint(x: 0.012 * side, y: -0.19))
            antenna.addQuadCurve(to: CGPoint(x: 0.11 * side, y: -0.34),
                                 control: CGPoint(x: 0.03 * side, y: -0.31))
            ctx.stroke(antenna, with: .color(colors.body), lineWidth: 0.012)

            let club = CGRect(x: 0.11 * side - 0.018, y: -0.34 - 0.018, width: 0.036, height: 0.036)
            ctx.fill(Path(ellipseIn: club), with: .color(colors.body))
        }
    }
}
