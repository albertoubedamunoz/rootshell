//
//  StarFieldLayer.swift
//  rootshell
//
//  Photo-realistic star field rendering using point spread function (PSF)
//  techniques. Stars are rendered with proper exponential falloff, subtle
//  spectral colors, and accurate diffraction patterns.
//

import SwiftUI
import CoreLocation

struct StarFieldLayer: View {
    let solarData: SolarData
    let location: CLLocationCoordinate2D
    let intensity: Double
    let animationTime: Double
    let twinkleEnabled: Bool
    let horizonY: CGFloat
    let simulatedDate: Date

    @State private var cachedStars: [VisibleStar] = []
    @State private var lastCacheKey: String = ""

    // Position interpolation state for smooth transitions when cache updates
    @State private var previousStarPositions: [Int: CGPoint] = [:]  // keyed by star ID
    @State private var lastCacheUpdateTime: Double = 0

    /// Duration over which stars interpolate from old to new positions
    private let positionTransitionDuration: Double = 2.0

    var body: some View {
        let visibility = starVisibility(sunAltitude: solarData.sunAltitude)

        if visibility > 0.01 {
            GeometryReader { geometry in
                // Use independent TimelineView for smooth twinkling animation
                // This runs at 20fps regardless of parent's slower update interval
                if twinkleEnabled {
                    TimelineView(.animation(minimumInterval: (1.0 / 20.0) * PowerManager.shared.effectIntervalScale)) { timeline in
                        let currentTime = timeline.date.timeIntervalSinceReferenceDate
                        let stars = getVisibleStars(size: geometry.size, currentTime: currentTime)
                        starCanvas(
                            stars: stars,
                            visibility: visibility,
                            time: currentTime
                        )
                    }
                } else {
                    let stars = getVisibleStars(size: geometry.size, currentTime: animationTime)
                    starCanvas(
                        stars: stars,
                        visibility: visibility,
                        time: animationTime
                    )
                }
            }
            .opacity(intensity)
            .blendMode(.plusLighter)
        }
    }

    @ViewBuilder
    private func starCanvas(stars: [VisibleStar], visibility: Double, time: Double) -> some View {
        // TimelineView drives 60fps updates; Canvas re-renders each frame
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, _ in
            // Render in LOD order: tertiary (dimmest) first, primary (brightest) last
            let sortedStars = stars.sorted { $0.catalogStar.magnitude > $1.catalogStar.magnitude }

            for star in sortedStars {
                renderStar(
                    context: &context,
                    star: star,
                    visibility: visibility,
                    time: time
                )
            }
        }
    }

    // MARK: - Star Visibility Calculation

    /// Smooth star visibility with faster fade-in (full by -12° instead of -18°)
    private func starVisibility(sunAltitude: Double) -> Double {
        if sunAltitude > 0 {
            return 0
        } else if sunAltitude > -12 {
            // Faster S-curve: full visibility by -12° to overlap with twilight glow
            let t = -sunAltitude / 12.0  // 0 to 1 over 12 degrees (was 18)
            return smootherstep(t)
        } else {
            return 1.0
        }
    }

    /// Perlin's smootherstep for C2-continuous transitions
    private func smootherstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    private func getVisibleStars(size: CGSize, currentTime: Double) -> [VisibleStar] {
        // Create a cache key based on simulated date (rounded to minute for demo mode performance)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: simulatedDate)
        let cacheKey = "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)-\(components.hour ?? 0)-\(components.minute ?? 0)-\(Int(size.width))x\(Int(size.height))"

        if cacheKey != lastCacheKey || cachedStars.isEmpty {
            Task { @MainActor in
                // Save current star positions before updating for smooth interpolation
                if !cachedStars.isEmpty {
                    var positions: [Int: CGPoint] = [:]
                    for star in cachedStars {
                        positions[star.catalogStar.id] = star.screenPosition
                    }
                    previousStarPositions = positions
                    lastCacheUpdateTime = currentTime
                }

                lastCacheKey = cacheKey
                cachedStars = StarCatalog.shared.calculateVisibleStars(
                    date: simulatedDate,
                    location: location,
                    viewSize: size,
                    horizonY: horizonY
                )
            }
        }
        return cachedStars
    }

    // MARK: - Position Interpolation

    /// Calculate interpolated position for a star during cache transition
    private func interpolatedPosition(for star: VisibleStar, at time: Double) -> CGPoint {
        // If no previous position exists, use current position
        guard let previousPosition = previousStarPositions[star.catalogStar.id] else {
            return star.screenPosition
        }

        // Calculate interpolation progress (0 = previous, 1 = current)
        let elapsed = time - lastCacheUpdateTime
        guard elapsed < positionTransitionDuration && elapsed > 0 else {
            return star.screenPosition
        }

        let t = elapsed / positionTransitionDuration
        let easedT = smootherstep(t)

        // Linearly interpolate between previous and current positions
        return CGPoint(
            x: previousPosition.x + (star.screenPosition.x - previousPosition.x) * easedT,
            y: previousPosition.y + (star.screenPosition.y - previousPosition.y) * easedT
        )
    }

    // MARK: - Photo-Realistic Star Rendering

    private func renderStar(
        context: inout GraphicsContext,
        star: VisibleStar,
        visibility: Double,
        time: Double
    ) {
        let magnitude = star.catalogStar.magnitude
        let position = interpolatedPosition(for: star, at: time)

        // Calculate atmospheric and visibility factors
        let extinction = star.atmosphericExtinction
        let magVis = magnitudeVisibility(magnitude, twilightVisibility: visibility)
        guard magVis > 0.01 else { return }

        // Twinkling (scintillation) - realistic atmospheric brightness flickering
        let scintillation = twinkleEnabled
            ? calculateScintillation(star, time: time)
            : ScintillationResult(brightness: 1.0, colorShift: 0.0)

        // Combined brightness factor
        let brightness = visibility * extinction * magVis * scintillation.brightness
        let colorShift = scintillation.colorShift

        // Get star color (subtle, not vivid)
        let spectralColor = star.catalogStar.spectralClass.color

        // Calculate size based on magnitude using proper logarithmic scaling
        // Each magnitude is 2.512x brightness difference
        // Sirius (-1.46) should be prominent, mag 5 stars tiny
        let baseBrightness = pow(2.512, (1.0 - magnitude))
        let coreRadius = max(0.5, min(6.0, 1.0 + baseBrightness * 0.8))

        // Render based on LOD tier
        switch star.catalogStar.lodTier {
        case .primary:
            renderPrimaryStar(
                context: &context,
                position: position,
                coreRadius: coreRadius,
                brightness: brightness,
                color: spectralColor,
                magnitude: magnitude,
                starId: star.catalogStar.id,
                altitude: star.altitude,
                colorShift: colorShift
            )
        case .secondary:
            renderSecondaryStar(
                context: &context,
                position: position,
                coreRadius: coreRadius,
                brightness: brightness,
                color: spectralColor
            )
        case .tertiary:
            renderTertiaryStar(
                context: &context,
                position: position,
                coreRadius: coreRadius,
                brightness: brightness,
                color: spectralColor
            )
        }
    }

    // MARK: - Primary Stars (mag < 1.5) - Full Detail

    private func renderPrimaryStar(
        context: inout GraphicsContext,
        position: CGPoint,
        coreRadius: CGFloat,
        brightness: Double,
        color: (r: Double, g: Double, b: Double),
        magnitude: Double,
        starId: Int,
        altitude: Double,
        colorShift: Double
    ) {
        // Apply chromatic scintillation - shifts color temperature during twinkling
        let shiftedColor = (
            r: min(1.0, max(0.0, color.r + colorShift * 0.3)),
            g: color.g,
            b: min(1.0, max(0.0, color.b - colorShift * 0.3))
        )
        let starColor = Color(red: shiftedColor.r, green: shiftedColor.g, blue: shiftedColor.b)

        // Atmospheric chromatic dispersion for stars near horizon
        // Stars < 15° altitude show vertical red/blue color split
        let dispersion: CGFloat = altitude < 15 ? CGFloat(2.0 * (15 - altitude) / 15) : 0

        if dispersion > 0.5 {
            // Blue-shifted component rendered slightly above
            let bluePosition = CGPoint(x: position.x, y: position.y - dispersion)
            let blueColor = Color(
                red: color.r * 0.7,
                green: color.g * 0.8,
                blue: min(1.0, color.b * 1.2)
            )
            let dispersionRadius = coreRadius * 0.6

            context.fill(
                Circle().path(in: CGRect(
                    x: bluePosition.x - dispersionRadius,
                    y: bluePosition.y - dispersionRadius,
                    width: dispersionRadius * 2,
                    height: dispersionRadius * 2
                )),
                with: .color(blueColor.opacity(brightness * 0.4))
            )

            // Red-shifted component rendered slightly below
            let redPosition = CGPoint(x: position.x, y: position.y + dispersion)
            let redColor = Color(
                red: min(1.0, color.r * 1.2),
                green: color.g * 0.8,
                blue: color.b * 0.6
            )

            context.fill(
                Circle().path(in: CGRect(
                    x: redPosition.x - dispersionRadius,
                    y: redPosition.y - dispersionRadius,
                    width: dispersionRadius * 2,
                    height: dispersionRadius * 2
                )),
                with: .color(redColor.opacity(brightness * 0.4))
            )
        }

        // Layer 1: Outer atmospheric glow (large, soft, colored)
        let outerGlowRadius = coreRadius * 16
        let outerGlowStops: [Gradient.Stop] = [
            .init(color: starColor.opacity(brightness * 0.12), location: 0.0),
            .init(color: starColor.opacity(brightness * 0.06), location: 0.2),
            .init(color: starColor.opacity(brightness * 0.02), location: 0.5),
            .init(color: starColor.opacity(brightness * 0.005), location: 0.75),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - outerGlowRadius,
                y: position.y - outerGlowRadius,
                width: outerGlowRadius * 2,
                height: outerGlowRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: outerGlowStops),
                center: position,
                startRadius: 0,
                endRadius: outerGlowRadius
            )
        )

        // Layer 2: Mid glow (PSF-like exponential falloff)
        let midGlowRadius = coreRadius * 8
        let midGlowStops: [Gradient.Stop] = [
            .init(color: Color.white.opacity(brightness * 0.3), location: 0.0),
            .init(color: starColor.opacity(brightness * 0.2), location: 0.15),
            .init(color: starColor.opacity(brightness * 0.08), location: 0.35),
            .init(color: starColor.opacity(brightness * 0.02), location: 0.6),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - midGlowRadius,
                y: position.y - midGlowRadius,
                width: midGlowRadius * 2,
                height: midGlowRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: midGlowStops),
                center: position,
                startRadius: 0,
                endRadius: midGlowRadius
            )
        )

        // Layer 3: Inner core halo (bright, white-dominated)
        let haloRadius = coreRadius * 3.5
        let haloStops: [Gradient.Stop] = [
            .init(color: Color.white.opacity(brightness * 0.8), location: 0.0),
            .init(color: Color.white.opacity(brightness * 0.5), location: 0.3),
            .init(color: starColor.opacity(brightness * 0.25), location: 0.6),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - haloRadius,
                y: position.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: haloStops),
                center: position,
                startRadius: 0,
                endRadius: haloRadius
            )
        )

        // Layer 4: Sharp core (the actual point of light)
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - coreRadius,
                y: position.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: .color(Color.white.opacity(min(1.0, brightness * 0.95)))
        )

        // Layer 5: Overexposed center for very bright stars
        if magnitude < 0.5 {
            let hotspotRadius = coreRadius * 0.5
            context.fill(
                Circle().path(in: CGRect(
                    x: position.x - hotspotRadius,
                    y: position.y - hotspotRadius,
                    width: hotspotRadius * 2,
                    height: hotspotRadius * 2
                )),
                with: .color(Color.white.opacity(brightness))
            )
        }

        // Layer 6: Diffraction spikes (optical artifact)
        if magnitude < 1.0 {
            renderDiffractionSpikes(
                context: &context,
                position: position,
                magnitude: magnitude,
                brightness: brightness,
                color: starColor,
                rotation: Double(starId) * 0.1
            )
        }
    }

    // MARK: - Secondary Stars (1.5 <= mag < 3.5)

    private func renderSecondaryStar(
        context: inout GraphicsContext,
        position: CGPoint,
        coreRadius: CGFloat,
        brightness: Double,
        color: (r: Double, g: Double, b: Double)
    ) {
        let starColor = Color(red: color.r, green: color.g, blue: color.b)

        // Outer glow
        let glowRadius = coreRadius * 6
        let glowStops: [Gradient.Stop] = [
            .init(color: Color.white.opacity(brightness * 0.35), location: 0.0),
            .init(color: starColor.opacity(brightness * 0.15), location: 0.25),
            .init(color: starColor.opacity(brightness * 0.04), location: 0.6),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - glowRadius,
                y: position.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: glowStops),
                center: position,
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        // Core with halo
        let haloRadius = coreRadius * 2.5
        let haloStops: [Gradient.Stop] = [
            .init(color: Color.white.opacity(brightness * 0.85), location: 0.0),
            .init(color: Color.white.opacity(brightness * 0.4), location: 0.4),
            .init(color: starColor.opacity(brightness * 0.1), location: 0.8),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - haloRadius,
                y: position.y - haloRadius,
                width: haloRadius * 2,
                height: haloRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: haloStops),
                center: position,
                startRadius: 0,
                endRadius: haloRadius
            )
        )

        // Sharp core
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - coreRadius,
                y: position.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: .color(Color.white.opacity(brightness * 0.9))
        )
    }

    // MARK: - Tertiary Stars (mag >= 3.5)

    private func renderTertiaryStar(
        context: inout GraphicsContext,
        position: CGPoint,
        coreRadius: CGFloat,
        brightness: Double,
        color: (r: Double, g: Double, b: Double)
    ) {
        let starColor = Color(red: color.r, green: color.g, blue: color.b)
        let adjustedRadius = max(0.6, coreRadius * 0.8)

        // Simple glow
        let glowRadius = adjustedRadius * 3
        let glowStops: [Gradient.Stop] = [
            .init(color: Color.white.opacity(brightness * 0.7), location: 0.0),
            .init(color: starColor.opacity(brightness * 0.2), location: 0.5),
            .init(color: .clear, location: 1.0)
        ]
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - glowRadius,
                y: position.y - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(stops: glowStops),
                center: position,
                startRadius: 0,
                endRadius: glowRadius
            )
        )

        // Core point
        context.fill(
            Circle().path(in: CGRect(
                x: position.x - adjustedRadius,
                y: position.y - adjustedRadius,
                width: adjustedRadius * 2,
                height: adjustedRadius * 2
            )),
            with: .color(Color.white.opacity(brightness * 0.8))
        )
    }

    // MARK: - Diffraction Spikes

    private func renderDiffractionSpikes(
        context: inout GraphicsContext,
        position: CGPoint,
        magnitude: Double,
        brightness: Double,
        color: Color,
        rotation: Double
    ) {
        // Spike intensity based on star brightness
        let spikeIntensity = (1.0 - magnitude) / 2.5
        guard spikeIntensity > 0.1 else { return }

        // Spike length based on brightness
        let baseLength: CGFloat = CGFloat(45 + (1.0 - magnitude) * 35)

        // 4-point diffraction pattern (Newtonian telescope style)
        let angles: [Double] = [
            rotation,
            rotation + .pi / 2,
            rotation + .pi,
            rotation + 3 * .pi / 2
        ]

        for angle in angles {
            // Main spike ray
            let endX = position.x + baseLength * CGFloat(cos(angle))
            let endY = position.y + baseLength * CGFloat(sin(angle))

            // Spike with gradient falloff
            var spikePath = Path()
            spikePath.move(to: position)
            spikePath.addLine(to: CGPoint(x: endX, y: endY))

            // Primary spike (bright, thin)
            context.stroke(
                spikePath,
                with: .linearGradient(
                    Gradient(colors: [
                        Color.white.opacity(spikeIntensity * brightness * 0.7),
                        color.opacity(spikeIntensity * brightness * 0.4),
                        color.opacity(spikeIntensity * brightness * 0.15),
                        color.opacity(spikeIntensity * brightness * 0.03),
                        .clear
                    ]),
                    startPoint: position,
                    endPoint: CGPoint(x: endX, y: endY)
                ),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )

            // Secondary spike (dimmer, thinner, extends further)
            let farEndX = position.x + baseLength * 1.8 * CGFloat(cos(angle))
            let farEndY = position.y + baseLength * 1.8 * CGFloat(sin(angle))

            var thinSpikePath = Path()
            thinSpikePath.move(to: CGPoint(x: endX * 0.7 + position.x * 0.3, y: endY * 0.7 + position.y * 0.3))
            thinSpikePath.addLine(to: CGPoint(x: farEndX, y: farEndY))

            context.stroke(
                thinSpikePath,
                with: .linearGradient(
                    Gradient(colors: [
                        color.opacity(spikeIntensity * brightness * 0.12),
                        color.opacity(spikeIntensity * brightness * 0.03),
                        .clear
                    ]),
                    startPoint: position,
                    endPoint: CGPoint(x: farEndX, y: farEndY)
                ),
                style: StrokeStyle(lineWidth: 0.8, lineCap: .round)
            )
        }
    }

    // MARK: - Scintillation (Twinkling)

    /// Result of scintillation calculation - brightness only (real stars don't change size)
    private struct ScintillationResult {
        let brightness: Double
        let colorShift: Double  // For chromatic scintillation on bright stars
    }

    /// Visually appealing star twinkling optimized for 60fps display
    ///
    /// Design goals:
    /// - Bright stars twinkle most noticeably (they're the visual focus)
    /// - Perceivable frequencies (2-6 Hz, not the 10-30 Hz of real scintillation)
    /// - Chaotic but smooth variation (multiple non-harmonic frequencies)
    /// - Stronger effect near horizon
    private func calculateScintillation(_ star: VisibleStar, time: Double) -> ScintillationResult {
        let phase = star.twinklePhase
        let magnitude = star.catalogStar.magnitude

        // Altitude factor: stars near horizon twinkle more (longer atmospheric path)
        let altitudeFactor = max(0.3, min(1.0, 1.0 - star.altitude / 50.0))

        // Bright stars should twinkle MORE visibly (they're what you look at)
        // Sirius (mag -1.46) gets strongest effect, dim stars fade to subtle
        let brightnessFactor: Double
        if magnitude < 1.5 {
            // Primary stars: strong, dramatic twinkling
            brightnessFactor = 0.9 + (1.5 - magnitude) * 0.15  // 0.9 to 1.35
        } else if magnitude < 3.5 {
            // Secondary stars: moderate twinkling
            brightnessFactor = 0.5 + (3.5 - magnitude) * 0.2   // 0.5 to 0.9
        } else {
            // Tertiary stars: subtle twinkling
            brightnessFactor = 0.3
        }

        // Combined strength
        let strength = 0.25 * brightnessFactor * (0.6 + 0.4 * altitudeFactor)

        // Perceivable frequencies for 60fps (2-6 Hz range)
        // Using non-harmonic ratios to avoid obvious patterns
        let f1 = 2.3    // Base slow oscillation
        let f2 = 3.7    // Medium oscillation
        let f3 = 5.1    // Faster flutter
        let f4 = 1.3    // Very slow envelope

        // Unique phase per star
        let p1 = phase
        let p2 = phase * 1.618  // Golden ratio for max decorrelation
        let p3 = phase * 2.414  // Silver ratio
        let p4 = phase * 0.414

        // Layered oscillation with varying weights
        let wave1 = sin(time * f1 + p1)
        let wave2 = sin(time * f2 + p2) * 0.7
        let wave3 = sin(time * f3 + p3) * 0.4
        let envelope = 0.5 + 0.5 * sin(time * f4 + p4)  // 0 to 1 modulation

        // Combine waves with envelope modulation
        let combined = (wave1 + wave2 + wave3) / 2.1  // Normalize to roughly -1 to 1
        let modulated = combined * (0.6 + 0.4 * envelope)

        // Convert to brightness: center at 1.0, vary by strength
        // Range for bright stars: ~0.65 to 1.0
        let brightness = 1.0 - strength * (0.5 - modulated * 0.5)

        // Chromatic shift for very bright stars (mag < 0.5)
        let colorShift: Double
        if magnitude < 0.5 {
            let chromatic = sin(time * f2 * 1.1 + p3)
            colorShift = chromatic * 0.12 * altitudeFactor
        } else {
            colorShift = 0
        }

        return ScintillationResult(
            brightness: max(0.55, min(1.0, brightness)),
            colorShift: colorShift
        )
    }

    // MARK: - Magnitude-Based Visibility

    private func magnitudeVisibility(_ magnitude: Double, twilightVisibility: Double) -> Double {
        // Brightest stars appear first during twilight
        // Full visibility means mag 5+ visible, low visibility only shows bright stars
        let threshold = (twilightVisibility - 0.3) / 0.7
        let magnitudeLimit = threshold * 6.0

        if magnitude > magnitudeLimit {
            let fadeRange = 1.0
            return max(0, (magnitudeLimit - magnitude + fadeRange) / fadeRange)
        }
        return 1.0
    }
}

// MARK: - Preview

#Preview("Photo-Realistic Stars") {
    ZStack {
        Color(red: 0.02, green: 0.02, blue: 0.05)
            .ignoresSafeArea()

        StarFieldLayer(
            solarData: SolarData(
                dayProgress: 0.1,
                sunAltitude: -25,
                sunAzimuth: 0,
                phase: .night,
                times: SolarTimes(
                    sunrise: Date(),
                    sunset: Date(),
                    solarNoon: Date(),
                    civilDawn: Date(),
                    civilDusk: Date()
                ),
                isNight: true
            ),
            location: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            intensity: 1.0,
            animationTime: 0,
            twinkleEnabled: true,
            horizonY: 700,
            simulatedDate: Date()
        )
    }
}
