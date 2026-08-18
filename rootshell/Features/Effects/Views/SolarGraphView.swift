//
//  SolarGraphView.swift
//  rootshell
//
//  SwiftUI view rendering a watchOS solarGraph-inspired effect.
//  Shows full 24-hour solar arc with the sun position, golden hour glows,
//  and daytime blue atmospheric effects.
//

import SwiftUI
import CoreLocation

// MARK: - Main View

/// WatchOS solarGraph-inspired background effect
struct SolarGraphView: View {
    @ObservedObject var effect: SolarGraphEffect
    var effectManager = EffectManager.shared

    /// Combined ID for settings that should trigger immediate re-render
    private var settingsId: String {
        "\(effect.showOcean)-\(effect.showStars)-\(effect.showArcTrack)-\(effect.showSunHotspot)-\(effect.showMoon)"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: effect.animationInterval)) { timeline in
            solarContent(for: timeline.date)
        }
        // Force re-render when effect settings change (TimelineView only updates on its schedule)
        .id(settingsId)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func solarContent(for date: Date) -> some View {
        let progress = calculateProgress(at: date)
        let simulatedDate = calculateSimulatedDate(progress: progress, realDate: date)
        let solarData = effect.calculateSolarData(progress: progress, at: simulatedDate)
        let animationTime = date.timeIntervalSinceReferenceDate

        GeometryReader { geometry in
            let keyboardOffset = effectManager.keyboardOverlapHeight(in: geometry.frame(in: .global))
            let adjustedHeight = max(0, geometry.size.height - keyboardOffset)
            let adjustedSize = CGSize(
                width: geometry.size.width,
                height: adjustedHeight
            )
            let config = ArcConfiguration(size: adjustedSize, solarTimes: solarData.times)
            let location = effect.locationService.getBestLocation()
            let horizonY = config.sunrisePosition.y
            let oceanHeight = adjustedSize.height - horizonY

            ZStack {
                // Static layers in drawingGroup for performance
                ZStack {
                    // Layer 1: Ambient sky background
                    AmbientSkyLayer(solarData: solarData, intensity: effect.intensity)

                    // Layer 1.5: Milky Way (begins during civil twilight for dramatic effect)
                    if effect.showStars && solarData.sunAltitude < -6 {
                        MilkyWayLayer(
                            visibility: milkyWayVisibility(sunAltitude: solarData.sunAltitude)
                        )
                    }

                    // Layer 1.6: Nebulae (begins during nautical twilight for dramatic effect)
                    if effect.showStars && solarData.sunAltitude < -10 {
                        NebulaLayer(
                            visibility: nebulaVisibility(sunAltitude: solarData.sunAltitude)
                        )
                    }

                    // Layer 1.7: Star field (begins during civil twilight)
                    if effect.showStars && solarData.sunAltitude < 0 {
                        StarFieldLayer(
                            solarData: solarData,
                            location: CLLocationCoordinate2D(
                                latitude: location.latitude,
                                longitude: location.longitude
                            ),
                            intensity: effect.intensity,
                            animationTime: animationTime,
                            twinkleEnabled: effect.starTwinkle,
                            horizonY: horizonY,
                            simulatedDate: simulatedDate
                        )
                    }

                    // Layer 1.8: Moon (visible at night, positioned based on lunar ephemeris)
                    if effect.showMoon {
                        let moonData = effect.calculateMoonData(at: simulatedDate, progress: progress)
                        if moonData.isAboveHorizon && moonData.position.altitude > -5 {
                            MoonLayer(
                                moonData: moonData,
                                solarData: solarData,
                                config: config,
                                intensity: effect.intensity * effect.moonGlowIntensity,
                                showMaria: effect.showMaria,
                                showEarthshine: effect.showEarthshine,
                                horizonY: horizonY,
                                animationTime: animationTime
                            )
                        }
                    }

                    // Layer 2: The solar arc dial with color segments
                    SolarArcDial(
                        config: config,
                        solarData: solarData,
                        intensity: effect.intensity,
                        showTrack: effect.showArcTrack
                    )

                    // Layer 3: Sunrise glow (left side of arc)
                    SunriseGlowEffect(
                        config: config,
                        solarData: solarData,
                        intensity: effect.intensity
                    )

                    // Layer 4: Sunset glow (right side of arc)
                    SunsetGlowEffect(
                        config: config,
                        solarData: solarData,
                        intensity: effect.intensity
                    )

                    // Layer 5: Sun orb with contextual glow (clipped at horizon)
                    SunOrbWithGlow(
                        config: config,
                        solarData: solarData,
                        intensity: effect.intensity,
                        horizonY: horizonY,
                        showHotspot: effect.showSunHotspot,
                        themeColors: effect.themeColors
                    )

                    // Layer 6: Horizon ground plane (without ocean - ocean rendered separately)
                    HorizonGroundPlane(
                        config: config,
                        solarData: solarData,
                        intensity: effect.intensity,
                        effect: effect,
                        animationTime: animationTime
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .drawingGroup()

                // Layer 7: Ocean surface - OUTSIDE drawingGroup for independent 60fps animation
                // The ocean has its own TimelineView that needs to run independently
                if effect.showOcean && oceanHeight > 0 {
                    ZStack {
                        OceanAnimatedView(
                            width: adjustedSize.width,
                            height: oceanHeight,
                            horizonY: horizonY,
                            solarData: solarData,
                            config: config,
                            intensity: effect.intensity,
                            waveAmplitude: effect.oceanWaveAmplitude,
                            reflectionStrength: effect.oceanReflectionStrength,
                            waveSpeed: effect.oceanWaveSpeed,
                            effect: effect
                        )

                        // Layer 7.5: Whale animation (all modes, different intervals)
                        if effect.showWhaleAnimation {
                            WhaleAnimationLayer(
                                oceanWidth: adjustedSize.width,
                                oceanHeight: oceanHeight,
                                solarData: solarData,
                                config: config,
                                animationTime: animationTime,
                                effect: effect
                            )
                        }
                    }
                    .frame(width: adjustedSize.width, height: oceanHeight)
                    .position(x: adjustedSize.width / 2, y: horizonY + oceanHeight / 2)
                }

                // Layer 7.6: Bird migration flocks (sky area, daylight only)
                // Birds fly in the sky portion above the horizon
                if effect.showBirdMigration && horizonY > 50 {
                    BirdMigrationLayer(
                        oceanWidth: adjustedSize.width,
                        oceanHeight: horizonY,  // Use sky height (above horizon)
                        solarData: solarData,
                        config: config,
                        effect: effect
                    )
                    .frame(width: adjustedSize.width, height: horizonY)
                    .position(x: adjustedSize.width / 2, y: horizonY / 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(
                // Only animate in real-time mode (30s updates need smooth easing)
                // Demo mode at 60fps doesn't need animation - and it causes stutter at midnight wrap
                effect.speed <= 1.0 ? .easeInOut(duration: 2.0) : nil,
                value: progress
            )
        }
    }

    // MARK: - Star Layer Visibility

    /// Milky Way visibility (begins earlier for dramatic effect)
    private func milkyWayVisibility(sunAltitude: Double) -> Double {
        // Start at -6°, full at -14° (earlier than astronomical for visual appeal)
        if sunAltitude > -6 {
            return 0
        } else if sunAltitude > -14 {
            let t = (-sunAltitude - 6) / 8.0  // 0 to 1 over 8 degrees
            return ArcConfiguration.smootherstep(t)
        } else {
            return 1.0
        }
    }

    /// Nebula visibility (begins earlier for dramatic effect)
    private func nebulaVisibility(sunAltitude: Double) -> Double {
        // Start at -10°, full at -18° (earlier than full astronomical for visual appeal)
        if sunAltitude > -10 {
            return 0
        } else if sunAltitude > -18 {
            let t = (-sunAltitude - 10) / 8.0  // 0 to 1 over 8 degrees
            return ArcConfiguration.smootherstep(t)
        } else {
            return 1.0
        }
    }

    private func calculateProgress(at date: Date) -> Double {
        if effect.speed <= 1.0 {
            // Real-time: get actual position in 24-hour cycle
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute, .second], from: date)
            let totalSeconds = Double(components.hour ?? 0) * 3600 +
                               Double(components.minute ?? 0) * 60 +
                               Double(components.second ?? 0)
            return totalSeconds / 86400.0  // 0-1 over 24 hours
        } else {
            // Demo mode: accelerated cycle using shared start time from effect
            let elapsed = effect.demoStartTime.distance(to: date) * effect.speed
            return elapsed.truncatingRemainder(dividingBy: 86400) / 86400.0
        }
    }

    /// Calculate a simulated date for demo mode star positions
    private func calculateSimulatedDate(progress: Double, realDate: Date) -> Date {
        if effect.speed <= 1.0 {
            // Real-time mode: use actual date
            return realDate
        } else {
            // Demo mode: use continuous elapsed time from demo start
            // This ensures star positions move smoothly without jumps at midnight
            // The elapsed time grows continuously, so stars rotate smoothly
            let elapsed = effect.demoStartTime.distance(to: realDate) * effect.speed
            return effect.demoStartTime.addingTimeInterval(elapsed)
        }
    }
}

// MARK: - Arc Configuration

/// Shared geometry configuration for the solar arc
struct ArcConfiguration {
    let size: CGSize
    let center: CGPoint
    let radius: CGFloat
    let arcStartAngle: Double  // Radians, where sunrise begins
    let arcEndAngle: Double    // Radians, where sunset ends

    // Key positions on the arc (as progress 0-1)
    // These are now calculated from actual solar times
    let sunriseProgress: Double
    let noonProgress: Double = 0.5       // 12 PM (solar noon approximation)
    let sunsetProgress: Double

    init(size: CGSize, solarTimes: SolarTimes? = nil) {
        self.size = size
        // Arc center is at the bottom edge - the arc rises up from the "horizon"
        self.center = CGPoint(x: size.width / 2, y: size.height * 0.92)
        // Radius sized so arc spans most of the width with top visible
        self.radius = min(size.width * 0.45, size.height * 0.75)

        // Arc spans from left (sunrise) to right (sunset) going UPWARD
        // Angles: 0 = right, π/2 = down, π = left, 3π/2 = up
        // To go upward: π → 3π/2 → 2π (which visually goes left → top → right)
        self.arcStartAngle = .pi          // Left side (sunrise)
        self.arcEndAngle = 2.0 * .pi      // Right side (sunset), same as 0 but ensures upward path

        // Calculate sunrise/sunset progress from actual solar times
        if let times = solarTimes {
            let calendar = Calendar.current
            let sunriseComponents = calendar.dateComponents([.hour, .minute, .second], from: times.sunrise)
            let sunsetComponents = calendar.dateComponents([.hour, .minute, .second], from: times.sunset)

            let sunriseSeconds = Double(sunriseComponents.hour ?? 6) * 3600 +
                                 Double(sunriseComponents.minute ?? 0) * 60 +
                                 Double(sunriseComponents.second ?? 0)
            let sunsetSeconds = Double(sunsetComponents.hour ?? 18) * 3600 +
                                Double(sunsetComponents.minute ?? 0) * 60 +
                                Double(sunsetComponents.second ?? 0)

            self.sunriseProgress = sunriseSeconds / 86400.0
            self.sunsetProgress = sunsetSeconds / 86400.0
        } else {
            // Fallback to 6 AM / 6 PM
            self.sunriseProgress = 0.25
            self.sunsetProgress = 0.75
        }
    }

    /// Convert 24-hour progress (0-1) to position on arc
    /// Returns nil if sun is "below horizon" (nighttime)
    func sunPosition(for progress: Double) -> CGPoint? {
        // Daytime is between sunrise (0.25) and sunset (0.75)
        guard progress >= sunriseProgress && progress <= sunsetProgress else {
            return nil
        }

        // Map daytime progress to arc angle
        // dayProgress 0 → π (left), 0.5 → 3π/2 (top), 1 → 2π (right)
        let dayProgress = (progress - sunriseProgress) / (sunsetProgress - sunriseProgress)
        let angle = arcStartAngle + dayProgress * .pi  // Clockwise visually (upward arc)

        return CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    /// Get position for any progress (including below horizon for glow positioning)
    func extendedPosition(for progress: Double) -> CGPoint {
        // Arc goes from π (left/sunrise, normalizedProgress=0) to 2π (right/sunset, normalizedProgress=1)
        // During night, we continue the circle underneath: 2π → 3π (bottom) → back to π
        //
        // Day progress timeline:
        //   0.0 = midnight, sunriseProgress ≈ 0.25, 0.5 = noon, sunsetProgress ≈ 0.75, 1.0 = midnight
        //
        // We want continuous motion: sunset → midnight → sunrise without jumping

        let normalizedProgress: Double

        if progress >= sunriseProgress && progress <= sunsetProgress {
            // Daytime: map sunrise→sunset to 0→1 on the visible arc (π to 2π)
            normalizedProgress = (progress - sunriseProgress) / (sunsetProgress - sunriseProgress)
        } else {
            // Nighttime: continue around the full circle below the horizon
            // Night duration spans: sunsetProgress → 1.0 (evening) + 0.0 → sunriseProgress (morning)
            let nightDuration = (1.0 - sunsetProgress) + sunriseProgress

            if progress > sunsetProgress {
                // Evening (after sunset, before midnight):
                // Map sunsetProgress→1.0 to normalizedProgress 1.0→~1.5
                let timeIntoNight = progress - sunsetProgress
                normalizedProgress = 1.0 + (timeIntoNight / nightDuration)
            } else {
                // Morning (after midnight, before sunrise):
                // Map 0.0→sunriseProgress to normalizedProgress ~1.5→2.0
                // At progress=0, we should be at the "bottom" of night
                // At progress=sunriseProgress, we should approach normalizedProgress=2.0 (same as 0)
                let timeIntoNight = (1.0 - sunsetProgress) + progress
                normalizedProgress = 1.0 + (timeIntoNight / nightDuration)
            }
        }

        // Angle: normalizedProgress 0→1 maps to π→2π (daytime arc above horizon)
        //        normalizedProgress 1→2 maps to 2π→3π (nighttime arc below horizon)
        let angle = arcStartAngle + normalizedProgress * .pi
        return CGPoint(
            x: center.x + radius * CGFloat(cos(angle)),
            y: center.y + radius * CGFloat(sin(angle))
        )
    }

    /// Position for sunrise marker (left side of arc at π)
    var sunrisePosition: CGPoint {
        CGPoint(
            x: center.x - radius,  // cos(π) = -1
            y: center.y            // sin(π) = 0
        )
    }

    /// Position for sunset marker (right side of arc at 2π)
    var sunsetPosition: CGPoint {
        CGPoint(
            x: center.x + radius,  // cos(2π) = 1
            y: center.y            // sin(2π) = 0
        )
    }

    /// Position for solar noon (top of arc at 3π/2)
    var noonPosition: CGPoint {
        let noonAngle = 3.0 * .pi / 2.0  // Top of the arc
        return CGPoint(
            x: center.x + radius * CGFloat(cos(noonAngle)),
            y: center.y + radius * CGFloat(sin(noonAngle))
        )
    }

    // MARK: - Smooth Sun Visibility

    /// Get sun position with visibility and scale factors for smooth horizon transitions
    /// Returns position even near horizon with gradual fade in/out
    func sunPositionWithVisibility(for progress: Double) -> (position: CGPoint, visibility: Double, scale: Double) {
        // Define transition zone around horizon (~30 minutes on either side)
        let horizonTransitionZone = 0.02  // ~30 minutes of day time

        let sunriseStart = sunriseProgress - horizonTransitionZone
        let sunriseEnd = sunriseProgress + horizonTransitionZone
        let sunsetStart = sunsetProgress - horizonTransitionZone
        let sunsetEnd = sunsetProgress + horizonTransitionZone

        // Calculate position (always valid using extendedPosition)
        let position = extendedPosition(for: progress)

        // Calculate visibility with smooth easing
        let visibility: Double
        let scale: Double

        if progress < sunriseStart {
            // Fully below horizon (pre-sunrise)
            visibility = 0.0
            scale = 0.5
        } else if progress < sunriseProgress {
            // Rising from below horizon - gradual fade in
            let t = (progress - sunriseStart) / horizonTransitionZone
            visibility = Self.smootherstep(t) * 0.7  // Start at 70% when crossing horizon
            scale = 0.5 + t * 0.5
        } else if progress < sunriseEnd {
            // Just above horizon at sunrise - continue fade in
            let t = (progress - sunriseProgress) / horizonTransitionZone
            visibility = 0.7 + Self.smootherstep(t) * 0.3  // Complete to 100%
            scale = 1.0
        } else if progress < sunsetStart {
            // Full daytime
            visibility = 1.0
            scale = 1.0
        } else if progress < sunsetProgress {
            // Approaching horizon at sunset - begin fade out
            let t = (progress - sunsetStart) / horizonTransitionZone
            visibility = 1.0 - Self.smootherstep(t) * 0.3  // Down to 70%
            scale = 1.0
        } else if progress < sunsetEnd {
            // Crossing below horizon at sunset
            let t = (progress - sunsetProgress) / horizonTransitionZone
            visibility = 0.7 - Self.smootherstep(t) * 0.7  // Down to 0%
            scale = 1.0 - t * 0.5
        } else {
            // Fully below horizon (post-sunset)
            visibility = 0.0
            scale = 0.5
        }

        return (position, visibility, scale)
    }

    // MARK: - Easing Functions

    /// Hermite smoothstep (C1 continuous) - good for most transitions
    static func smoothstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }

    /// Perlin's smootherstep (C2 continuous) - even smoother, no velocity discontinuities
    static func smootherstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}

// MARK: - Oklab Color Space (Perceptually Uniform)

/// Oklab color space utilities for perceptually uniform gradient interpolation
/// Eliminates banding artifacts by interpolating through perceptually linear color space
enum OklabColorSpace {
    /// Convert sRGB (0-1 range) to Oklab color space
    static func sRGBToOklab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        // Linearize sRGB (remove gamma)
        func linearize(_ x: Double) -> Double {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let lr = linearize(r)
        let lg = linearize(g)
        let lb = linearize(b)

        // Convert to LMS cone responses
        let l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
        let m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
        let s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb

        // Apply cube root for perceptual uniformity
        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)

        // Convert to Oklab
        return (
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    /// Convert Oklab back to sRGB (0-1 range, clamped)
    static func oklabToSRGB(_ L: Double, _ a: Double, _ b: Double) -> (r: Double, g: Double, b: Double) {
        // Convert from Oklab to LMS (cube root space)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b

        // Cube to get LMS
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        // Convert LMS to linear RGB
        let lr = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        // Apply sRGB gamma and clamp
        func gamma(_ x: Double) -> Double {
            let clamped = max(0, min(1, x))
            return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }

        return (gamma(lr), gamma(lg), gamma(lb))
    }

    /// Interpolate between two sRGB colors in Oklab space for perceptually smooth transitions
    static func interpolate(
        from: (Double, Double, Double),
        to: (Double, Double, Double),
        t: Double
    ) -> (Double, Double, Double) {
        let okFrom = sRGBToOklab(from.0, from.1, from.2)
        let okTo = sRGBToOklab(to.0, to.1, to.2)

        // Linear interpolation in Oklab space
        let L = okFrom.L + (okTo.L - okFrom.L) * t
        let a = okFrom.a + (okTo.a - okFrom.a) * t
        let b = okFrom.b + (okTo.b - okFrom.b) * t

        return oklabToSRGB(L, a, b)
    }
}

// MARK: - Atmospheric Scattering Model

/// Physics-based atmospheric scattering for photorealistic sky colors
/// Simulates Rayleigh scattering (blue sky), Mie scattering (horizon glow),
/// and ozone absorption (deep blue zenith) based on sun elevation.
enum AtmosphericScattering {
    // MARK: - Physical Constants

    /// Rayleigh scattering coefficients at sea level (per meter)
    /// Blue scatters more strongly: coefficient ~ 1/wavelength^4
    /// Values for RGB wavelengths: 680nm (R), 550nm (G), 440nm (B)
    private static let betaR: (Double, Double, Double) = (5.8e-6, 13.5e-6, 33.1e-6)

    /// Mie scattering coefficient (wavelength-independent, aerosol scattering)
    private static let betaM: Double = 21e-6

    /// Scale height for Rayleigh scattering (meters)
    private static let scaleHeightR: Double = 8500

    /// Scale height for Mie scattering (meters)
    private static let scaleHeightM: Double = 1200

    /// Sun intensity (normalized)
    private static let sunIntensity: Double = 20.0

    // MARK: - Main API

    /// Calculate sky colors for given sun altitude using atmospheric scattering
    /// Returns (zenith color, horizon color) as RGB tuples
    static func calculateSkyColors(sunAltitude: Double) -> (top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        let sunElevation = sunAltitude * .pi / 180.0

        // Calculate zenith color (looking straight up)
        let zenithColor = calculateScattering(
            viewElevation: .pi / 2,
            sunElevation: sunElevation
        )

        // Calculate horizon color (looking at horizon)
        let horizonColor = calculateScattering(
            viewElevation: 0.05,  // Slightly above mathematical horizon
            sunElevation: sunElevation
        )

        return (zenithColor, horizonColor)
    }

    // MARK: - Scattering Calculation

    /// Calculate scattered light color for a given view direction and sun position
    private static func calculateScattering(
        viewElevation: Double,
        sunElevation: Double
    ) -> (Double, Double, Double) {
        // Angle between view direction and sun direction
        let cosTheta = sin(viewElevation) * sin(sunElevation) + cos(viewElevation) * cos(sunElevation)

        // Rayleigh phase function: 3/(16π) * (1 + cos²θ)
        let rayleighPhase = 0.75 * (1.0 + cosTheta * cosTheta)

        // Mie phase function (Henyey-Greenstein, g=0.76 for aerosols)
        let g: Double = 0.76
        let miePhase = (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * cosTheta, 1.5) / (4.0 * .pi)

        // Optical depth based on view elevation (simplified plane-parallel atmosphere)
        let opticalDepthFactor = 1.0 / max(0.05, sin(max(0.01, viewElevation)))

        // Sun intensity factor based on elevation (extinction through atmosphere)
        let sunExtinction = calculateSunExtinction(elevation: sunElevation)

        // Calculate in-scattered light for each wavelength
        var color: (Double, Double, Double) = (0, 0, 0)

        // Rayleigh contribution (blue sky)
        let rayleighR = betaR.0 * rayleighPhase * opticalDepthFactor
        let rayleighG = betaR.1 * rayleighPhase * opticalDepthFactor
        let rayleighB = betaR.2 * rayleighPhase * opticalDepthFactor

        // Mie contribution (warm horizon glow)
        let mieContribution = betaM * miePhase * opticalDepthFactor * 0.5

        // Combine scattering with sun intensity
        color.0 = (rayleighR + mieContribution) * sunIntensity * sunExtinction.0
        color.1 = (rayleighG + mieContribution) * sunIntensity * sunExtinction.1
        color.2 = (rayleighB + mieContribution) * sunIntensity * sunExtinction.2

        // Add twilight colors when sun is below horizon
        if sunElevation < 0 {
            let twilightColor = calculateTwilightColor(sunElevation: sunElevation, viewElevation: viewElevation)
            let twilightFactor = smoothstep(-sunElevation / (18.0 * .pi / 180.0))
            color.0 = color.0 * (1 - twilightFactor) + twilightColor.0 * twilightFactor
            color.1 = color.1 * (1 - twilightFactor) + twilightColor.1 * twilightFactor
            color.2 = color.2 * (1 - twilightFactor) + twilightColor.2 * twilightFactor
        }

        // Add night sky base color for deep night
        if sunElevation < -12 * .pi / 180.0 {
            let nightFactor = smoothstep((-sunElevation - 12 * .pi / 180.0) / (6.0 * .pi / 180.0))
            let nightBase: (Double, Double, Double) = (0.02, 0.02, 0.06)
            color.0 = color.0 * (1 - nightFactor) + nightBase.0 * nightFactor
            color.1 = color.1 * (1 - nightFactor) + nightBase.1 * nightFactor
            color.2 = color.2 * (1 - nightFactor) + nightBase.2 * nightFactor
        }

        // Ozone absorption (removes green, deepens blue at zenith)
        if viewElevation > 0.3 {
            let ozoneFactor = (viewElevation - 0.3) / (.pi / 2 - 0.3) * 0.15
            color.1 *= (1.0 - ozoneFactor)  // Reduce green slightly
        }

        // Tone mapping (Reinhard) to bring HDR values into displayable range
        color.0 = color.0 / (1.0 + color.0)
        color.1 = color.1 / (1.0 + color.1)
        color.2 = color.2 / (1.0 + color.2)

        // Clamp to valid range
        return (
            max(0, min(1, color.0)),
            max(0, min(1, color.1)),
            max(0, min(1, color.2))
        )
    }

    /// Calculate sun extinction through atmosphere based on elevation
    private static func calculateSunExtinction(elevation: Double) -> (Double, Double, Double) {
        // Air mass approximation (Kasten-Young formula simplified)
        let airMass: Double
        if elevation > 0 {
            airMass = 1.0 / (sin(elevation) + 0.50572 * pow(elevation * 180 / .pi + 6.07995, -1.6364))
        } else {
            // Below horizon - rapid extinction
            airMass = 40.0 * (1.0 + abs(elevation) * 10)
        }

        // Extinction = exp(-beta * airMass * scaleHeight)
        let extR = exp(-betaR.0 * airMass * scaleHeightR * 0.001)
        let extG = exp(-betaR.1 * airMass * scaleHeightR * 0.001)
        let extB = exp(-betaR.2 * airMass * scaleHeightR * 0.001)

        return (extR, extG, extB)
    }

    /// Calculate twilight colors (civil, nautical, astronomical)
    private static func calculateTwilightColor(sunElevation: Double, viewElevation: Double) -> (Double, Double, Double) {
        let sunDegrees = sunElevation * 180 / .pi

        // Twilight phases
        if sunDegrees > -6 {
            // Civil twilight: warm orange/pink glow
            let factor = (6 + sunDegrees) / 6.0
            let warmth = 1.0 - factor
            return (
                0.3 + warmth * 0.5,
                0.15 + warmth * 0.15,
                0.2 + warmth * 0.1
            )
        } else if sunDegrees > -12 {
            // Nautical twilight: purple/blue transition
            let factor = (12 + sunDegrees) / 6.0
            return (
                0.1 + factor * 0.2,
                0.08 + factor * 0.07,
                0.2 + factor * 0.1
            )
        } else if sunDegrees > -18 {
            // Astronomical twilight: deep blue
            let factor = (18 + sunDegrees) / 6.0
            return (
                0.03 + factor * 0.07,
                0.03 + factor * 0.05,
                0.08 + factor * 0.12
            )
        } else {
            // Night
            return (0.02, 0.02, 0.06)
        }
    }

    /// Simple smoothstep for transitions
    private static func smoothstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Layer 1: Ambient Sky

struct AmbientSkyLayer: View {
    let solarData: SolarData
    let intensity: Double

    var body: some View {
        // Use physics-based atmospheric scattering for photorealistic sky colors
        let scatteringColors = AtmosphericScattering.calculateSkyColors(sunAltitude: solarData.sunAltitude)
        let stops = generatePerceptualGradientStops(
            top: scatteringColors.top,
            bottom: scatteringColors.bottom,
            opacity: intensity * 0.5
        )

        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .colorEffect(ShaderLibrary.skyDither(
                .float2(1, 1),  // Size not used by shader but required
                .float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
            ))
    }

    /// Generate 24 gradient stops with perceptual Oklab interpolation to prevent banding
    private func generatePerceptualGradientStops(
        top: (Double, Double, Double),
        bottom: (Double, Double, Double),
        opacity: Double
    ) -> [Gradient.Stop] {
        let numStops = 24
        var stops: [Gradient.Stop] = []

        for i in 0..<numStops {
            let location = Double(i) / Double(numStops - 1)
            // Use smootherstep for extra-smooth perceptual transitions
            let eased = ArcConfiguration.smootherstep(location)

            // Interpolate in Oklab color space for perceptual uniformity
            let rgb = OklabColorSpace.interpolate(from: top, to: bottom, t: eased)

            stops.append(.init(
                color: Color(red: rgb.0, green: rgb.1, blue: rgb.2).opacity(opacity),
                location: location
            ))
        }

        return stops
    }
}

// MARK: - Layer 2: Solar Arc Dial

struct SolarArcDial: View {
    let config: ArcConfiguration
    let solarData: SolarData
    let intensity: Double
    let showTrack: Bool

    var body: some View {
        if showTrack {
            ZStack {
                // Subtle outer glow
                ArcShape(config: config)
                    .stroke(
                        Color.white.opacity(intensity * 0.08),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .blur(radius: 4)

                // Main arc stroke - subtle static color
                ArcShape(config: config)
                    .stroke(
                        Color.white.opacity(intensity * 0.25),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
            }
        }
    }
}

/// Shape for the solar arc
struct ArcShape: Shape {
    let config: ArcConfiguration

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Draw arc from left (π) to right (2π) going upward through top (3π/2)
        // clockwise: false = counter-clockwise in math = increasing angles
        path.addArc(
            center: config.center,
            radius: config.radius,
            startAngle: .radians(config.arcStartAngle),
            endAngle: .radians(config.arcEndAngle),
            clockwise: false
        )
        return path
    }
}

// MARK: - Layer 3: Sunrise Glow

struct SunriseGlowEffect: View {
    let config: ArcConfiguration
    let solarData: SolarData
    let intensity: Double

    // Glow window: how far (in day progress) the glow extends before/after sunrise
    // 0.04 ≈ 1 hour of 24-hour day
    private let glowWindow: Double = 0.04

    /// Only show during morning (before solar noon)
    private var isMorning: Bool {
        solarData.dayProgress < (config.sunriseProgress + config.sunsetProgress) / 2
    }

    /// Distance from sunrise point, normalized to glow window
    /// Returns -1.0 to 0.0 (approaching sunrise) and 0.0 to 1.0 (past sunrise)
    private var distanceFromSunrise: Double {
        (solarData.dayProgress - config.sunriseProgress) / glowWindow
    }

    /// Glow intensity based on distance from sunrise (synchronized with sun visibility)
    private var glowIntensity: Double {
        guard isMorning else { return 0 }

        let d = distanceFromSunrise

        if d < -1.0 {
            // More than glowWindow before sunrise - no glow
            return 0
        } else if d < 0 {
            // Approaching sunrise: fade in
            let t = d + 1.0  // 0 to 1
            return ArcConfiguration.smootherstep(t) * 0.8 * intensity
        } else if d < 1.0 {
            // Past sunrise: fade out
            let t = d  // 0 to 1
            return (1.0 - ArcConfiguration.smootherstep(t)) * 0.8 * intensity
        } else {
            // More than glowWindow after sunrise - no glow
            return 0
        }
    }

    /// Glow radius based on distance from sunrise
    private var glowRadius: Double {
        let baseRadius = config.size.width * 0.35
        let d = distanceFromSunrise

        if d < 0 {
            // Before sunrise: grows as we approach
            let t = max(0, d + 1.0)  // 0 at d=-1, 1 at d=0
            return baseRadius * (0.7 + ArcConfiguration.smootherstep(t) * 0.3)
        } else {
            // After sunrise: shrinks
            let t = min(1.0, d)
            return baseRadius * (1.0 - ArcConfiguration.smootherstep(t) * 0.5)
        }
    }

    /// Glow position tracks the sun
    private var glowPosition: CGPoint {
        config.extendedPosition(for: solarData.dayProgress)
    }

    /// Colors based on GlowBlend
    private var glowColors: (core: (Double, Double, Double), edge: (Double, Double, Double)) {
        let blend = GlowBlend.from(progress: solarData.dayProgress, config: config)

        // Sunrise colors (warm orange)
        let sunriseCore = (1.0, 0.7, 0.35)
        let sunriseEdge = (1.0, 0.3, 0.1)

        // Daytime colors (cool blue-white)
        let daytimeCore = (0.85, 0.9, 1.0)
        let daytimeEdge = (0.6, 0.75, 0.95)

        let core = (
            sunriseCore.0 * blend.sunrise + daytimeCore.0 * blend.daytime,
            sunriseCore.1 * blend.sunrise + daytimeCore.1 * blend.daytime,
            sunriseCore.2 * blend.sunrise + daytimeCore.2 * blend.daytime
        )
        let edge = (
            sunriseEdge.0 * blend.sunrise + daytimeEdge.0 * blend.daytime,
            sunriseEdge.1 * blend.sunrise + daytimeEdge.1 * blend.daytime,
            sunriseEdge.2 * blend.sunrise + daytimeEdge.2 * blend.daytime
        )

        return (core, edge)
    }

    var body: some View {
        if glowIntensity > 0.01 {
            let position = glowPosition
            let radius = glowRadius
            let frameSize = radius * 3.0
            let colors = glowColors

            Rectangle()
                .fill(Color.white)
                .frame(width: frameSize, height: frameSize)
                .colorEffect(ShaderLibrary.horizonGlow(
                    .float(Float(frameSize / 2)),
                    .float(Float(frameSize / 2)),
                    .float(Float(radius)),
                    .float(Float(glowIntensity)),
                    .float(Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))),
                    .float(Float(colors.core.0)), .float(Float(colors.core.1)), .float(Float(colors.core.2)),
                    .float(Float(colors.edge.0)), .float(Float(colors.edge.1)), .float(Float(colors.edge.2))
                ))
                .position(position)
        }
    }
}

// MARK: - Layer 4: Sunset Glow

struct SunsetGlowEffect: View {
    let config: ArcConfiguration
    let solarData: SolarData
    let intensity: Double

    // Glow window: how far (in day progress) the glow extends before/after sunset
    // 0.04 ≈ 1 hour of 24-hour day
    private let glowWindow: Double = 0.04

    /// Only show during afternoon (after solar noon)
    private var isAfternoon: Bool {
        solarData.dayProgress >= (config.sunriseProgress + config.sunsetProgress) / 2
    }

    /// Distance from sunset point, normalized to glow window
    /// Returns -1.0 to 0.0 (approaching sunset) and 0.0 to 1.0 (past sunset)
    private var distanceFromSunset: Double {
        (solarData.dayProgress - config.sunsetProgress) / glowWindow
    }

    /// Glow intensity based on distance from sunset (synchronized with sun visibility)
    private var glowIntensity: Double {
        guard isAfternoon else { return 0 }

        let d = distanceFromSunset

        if d < -1.0 {
            // More than glowWindow before sunset - no glow
            return 0
        } else if d < 0 {
            // Approaching sunset: fade in
            let t = d + 1.0  // 0 to 1
            return ArcConfiguration.smootherstep(t) * 0.8 * intensity
        } else if d < 1.0 {
            // Past sunset: fade out
            let t = d  // 0 to 1
            return (1.0 - ArcConfiguration.smootherstep(t)) * 0.8 * intensity
        } else {
            // More than glowWindow after sunset - no glow
            return 0
        }
    }

    /// Glow radius based on distance from sunset
    private var glowRadius: Double {
        let baseRadius = config.size.width * 0.35
        let d = distanceFromSunset

        if d < 0 {
            // Before sunset: grows as we approach
            let t = max(0, d + 1.0)  // 0 at d=-1, 1 at d=0
            return baseRadius * (0.7 + ArcConfiguration.smootherstep(t) * 0.3)
        } else {
            // After sunset: shrinks
            let t = min(1.0, d)
            return baseRadius * (1.0 - ArcConfiguration.smootherstep(t) * 0.5)
        }
    }

    /// Glow position tracks the sun
    private var glowPosition: CGPoint {
        config.extendedPosition(for: solarData.dayProgress)
    }

    /// Colors based on GlowBlend
    private var glowColors: (core: (Double, Double, Double), edge: (Double, Double, Double)) {
        let blend = GlowBlend.from(progress: solarData.dayProgress, config: config)

        // Daytime colors (cool blue-white)
        let daytimeCore = (0.85, 0.9, 1.0)
        let daytimeEdge = (0.6, 0.75, 0.95)

        // Sunset colors (warm red-orange to purple)
        let sunsetCore = (1.0, 0.55, 0.30)
        let sunsetEdge = (0.65, 0.22, 0.50)

        let core = (
            daytimeCore.0 * blend.daytime + sunsetCore.0 * blend.sunset,
            daytimeCore.1 * blend.daytime + sunsetCore.1 * blend.sunset,
            daytimeCore.2 * blend.daytime + sunsetCore.2 * blend.sunset
        )
        let edge = (
            daytimeEdge.0 * blend.daytime + sunsetEdge.0 * blend.sunset,
            daytimeEdge.1 * blend.daytime + sunsetEdge.1 * blend.sunset,
            daytimeEdge.2 * blend.daytime + sunsetEdge.2 * blend.sunset
        )

        return (core, edge)
    }

    var body: some View {
        if glowIntensity > 0.01 {
            let position = glowPosition
            let radius = glowRadius
            let frameSize = radius * 3.0
            let colors = glowColors

            Rectangle()
                .fill(Color.white)
                .frame(width: frameSize, height: frameSize)
                .colorEffect(ShaderLibrary.horizonGlow(
                    .float(Float(frameSize / 2)),
                    .float(Float(frameSize / 2)),
                    .float(Float(radius)),
                    .float(Float(glowIntensity)),
                    .float(Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))),
                    .float(Float(colors.core.0)), .float(Float(colors.core.1)), .float(Float(colors.core.2)),
                    .float(Float(colors.edge.0)), .float(Float(colors.edge.1)), .float(Float(colors.edge.2))
                ))
                .position(position)
        }
    }
}

// MARK: - Glow Blend for Smooth Transitions

/// Blend factors for glow types (all values 0-1)
struct GlowBlend {
    let sunrise: Double
    let daytime: Double
    let sunset: Double

    /// Create blend from day progress with smooth transitions
    static func from(progress: Double, config: ArcConfiguration) -> GlowBlend {
        // Extended transition zones (~2.5 hours each way)
        let sunriseEnd = config.sunriseProgress + 0.10
        let sunsetStart = config.sunsetProgress - 0.10

        var sunrise: Double = 0
        var daytime: Double = 0
        var sunset: Double = 0

        if progress < config.sunriseProgress {
            // Pre-sunrise: blend from sunset colors (night) to sunrise colors
            // Night spans from sunsetProgress through midnight (1.0/0.0) to sunriseProgress
            // Calculate how far through the night we are (0 = just after sunset, 1 = sunrise)
            let nightDuration = (1.0 - config.sunsetProgress) + config.sunriseProgress
            let nightProgress = ((1.0 - config.sunsetProgress) + progress) / nightDuration
            // Smooth transition from sunset glow to sunrise glow through the night
            sunset = 1.0 - ArcConfiguration.smootherstep(nightProgress)
            sunrise = ArcConfiguration.smootherstep(nightProgress)
        } else if progress < sunriseEnd {
            // Transition from sunrise to daytime
            let t = (progress - config.sunriseProgress) / (sunriseEnd - config.sunriseProgress)
            let eased = ArcConfiguration.smootherstep(t)
            sunrise = 1.0 - eased
            daytime = eased
        } else if progress < sunsetStart {
            // Full daytime
            daytime = 1.0
        } else if progress < config.sunsetProgress {
            // Transition from daytime to sunset
            let t = (progress - sunsetStart) / (config.sunsetProgress - sunsetStart)
            let eased = ArcConfiguration.smootherstep(t)
            daytime = 1.0 - eased
            sunset = eased
        } else {
            // Post-sunset: blend from sunset colors toward sunrise colors through night
            let nightDuration = (1.0 - config.sunsetProgress) + config.sunriseProgress
            let nightProgress = (progress - config.sunsetProgress) / nightDuration
            sunset = 1.0 - ArcConfiguration.smootherstep(nightProgress)
            sunrise = ArcConfiguration.smootherstep(nightProgress)
        }

        return GlowBlend(sunrise: sunrise, daytime: daytime, sunset: sunset)
    }

    /// Blend RGB colors using weights
    func blendColor(sunrise sr: (Double, Double, Double),
                    daytime dt: (Double, Double, Double),
                    sunset ss: (Double, Double, Double)) -> Color {
        let r = sr.0 * sunrise + dt.0 * daytime + ss.0 * sunset
        let g = sr.1 * sunrise + dt.1 * daytime + ss.1 * sunset
        let b = sr.2 * sunrise + dt.2 * daytime + ss.2 * sunset
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Layer 5: Sun Orb with Contextual Glow

struct SunOrbWithGlow: View {
    let config: ArcConfiguration
    let solarData: SolarData
    let intensity: Double
    let horizonY: CGFloat  // Y position of horizon for clipping
    let showHotspot: Bool  // Whether to show the 3D depth hotspot
    let themeColors: EffectThemeColors

    var body: some View {
        let sunInfo = config.sunPositionWithVisibility(for: solarData.dayProgress)

        // Show sun even at low visibility for horizon glow effect
        guard sunInfo.visibility > 0.01 else {
            return AnyView(EmptyView())
        }

        let glowBlend = GlowBlend.from(progress: solarData.dayProgress, config: config)
        let baseRadius: CGFloat = 18
        let sunRadius = baseRadius * CGFloat(sunInfo.scale)
        let effectiveIntensity = intensity * sunInfo.visibility
        let backgroundRGB = themeBackgroundRGB()

        // Size the view to contain the glow (8× radius for tighter falloff)
        let glowExtent = sunRadius * 16

        // When hotspot is disabled, move it far off-screen so it doesn't render
        let hotspotOffset: Float = showHotspot ? -0.15 : 10.0

        return AnyView(
            Rectangle()
                .fill(Color.white)  // Base for shader to transform
                .frame(width: glowExtent, height: glowExtent)
                .colorEffect(ShaderLibrary.sunGlow(
                    .float(Float(glowExtent / 2)),  // sunCenterX (relative to view)
                    .float(Float(glowExtent / 2)),  // sunCenterY (relative to view)
                    .float(Float(sunRadius)),
                    .float(Float(solarData.sunAltitude)),
                    .float(backgroundRGB.0),
                    .float(backgroundRGB.1),
                    .float(backgroundRGB.2),
                    .float(Float(effectiveIntensity)),
                    .float(Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))),
                    .float(Float(glowBlend.sunrise)),
                    .float(Float(glowBlend.daytime)),
                    .float(Float(glowBlend.sunset)),
                    .float(hotspotOffset),  // hotspotOffsetX
                    .float(hotspotOffset)   // hotspotOffsetY
                ))
                .position(sunInfo.position)
                // Clip sun and glow at horizon for realistic sunrise/sunset
                .clipShape(HorizonClipShape(horizonY: horizonY))
        )
    }

    private func themeBackgroundRGB() -> (Float, Float, Float) {
        guard let color = Color(hex: themeColors.background) else {
            return (0.0, 0.0, 0.0)
        }
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Float(r), Float(g), Float(b))
        }
        return (0.0, 0.0, 0.0)
    }
}

// MARK: - Ocean Animated View

/// Separate view for ocean animation with its own timeline
struct OceanAnimatedView: View {
    let width: CGFloat
    let height: CGFloat
    let horizonY: CGFloat
    let solarData: SolarData
    let config: ArcConfiguration
    let intensity: Double
    let waveAmplitude: Double
    let reflectionStrength: Double
    let waveSpeed: Double
    /// Effect reference for oceanTime() which auto-corrects for background pauses
    let effect: SolarGraphEffect

    /// 60fps baseline, halved in battery saver.
    private var frameInterval: Double {
        (1.0 / 60.0) * PowerManager.shared.effectIntervalScale
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { context in
            // Calculate moon data for ocean reflection
            // Use solarData.dayProgress so moon position syncs with sun in demo mode
            let moonData = effect.showMoon ? effect.calculateMoonData(at: context.date, progress: solarData.dayProgress) : nil

            OceanShaderView(
                width: width,
                height: height,
                horizonY: horizonY,
                solarData: solarData,
                config: config,
                intensity: intensity,
                waveAmplitude: waveAmplitude,
                reflectionStrength: reflectionStrength,
                waveSpeed: waveSpeed,
                oceanTime: effect.oceanTime(for: context.date.timeIntervalSinceReferenceDate),
                moonData: moonData
            )
        }
    }
}

/// Inner view that applies the ocean shader - separated to ensure SwiftUI sees the time change
private struct OceanShaderView: View {
    let width: CGFloat
    let height: CGFloat
    let horizonY: CGFloat
    let solarData: SolarData
    let config: ArcConfiguration
    let intensity: Double
    let waveAmplitude: Double
    let reflectionStrength: Double
    let waveSpeed: Double
    let oceanTime: Double
    let moonData: MoonData?

    // Computed properties for moon reflection data
    private var moonReflectionData: (x: Float, altitude: Float, illumination: Float) {
        guard let moon = moonData, moon.isAboveHorizon else {
            return (x: 0.5, altitude: -90.0, illumination: 0.0)
        }

        // Map moon azimuth to screen X (similar to sun)
        let azimuth = moon.position.azimuth
        let normalizedAzimuth: Double
        if azimuth >= 90 && azimuth <= 270 {
            normalizedAzimuth = (azimuth - 90) / 180.0
        } else if azimuth > 270 {
            normalizedAzimuth = 1.0 + (azimuth - 270) / 180.0
        } else {
            normalizedAzimuth = (azimuth + 90) / 180.0 - 1.0
        }

        return (
            x: Float(max(0, min(1, normalizedAzimuth))),
            altitude: Float(moon.position.altitude),
            illumination: Float(moon.phaseInfo.illumination)
        )
    }

    var body: some View {
        let blend = GlowBlend.from(progress: solarData.dayProgress, config: config)
        let sunInfo = config.sunPositionWithVisibility(for: solarData.dayProgress)
        let sunX = sunInfo.position.x / width

        let isNight: Float = {
            let altitude = solarData.sunAltitude
            if altitude > 0 {
                return 0.0
            } else if altitude > -12 {
                return Float(ArcConfiguration.smootherstep(-altitude / 12.0)) * 0.5
            } else {
                return Float(min(1.0, 0.5 + ArcConfiguration.smootherstep((-altitude - 12.0) / 6.0) * 0.5))
            }
        }()

        let moonRefl = moonReflectionData

        Rectangle()
            .fill(Color.white)
            .frame(width: width, height: height)
            .colorEffect(ShaderLibrary.ocean(
                .float(Float(width)),
                .float(Float(height)),
                .float(Float(horizonY)),
                .float(Float(oceanTime)),
                .float(Float(sunX)),
                .float(Float(solarData.sunAltitude)),
                .float(Float(intensity)),
                .float(Float(blend.sunrise)),
                .float(Float(blend.daytime)),
                .float(Float(blend.sunset)),
                .float(Float(waveAmplitude)),
                .float(Float(reflectionStrength)),
                .float(isNight),
                .float(Float(waveSpeed)),
                .float(moonRefl.x),
                .float(moonRefl.altitude),
                .float(moonRefl.illumination)
            ))
    }
}

// MARK: - Layer 6: Horizon Ground Plane with Reflection

struct HorizonGroundPlane: View {
    let config: ArcConfiguration
    let solarData: SolarData
    let intensity: Double
    let effect: SolarGraphEffect
    let animationTime: TimeInterval

    var body: some View {
        let horizonY = config.sunrisePosition.y

        GeometryReader { geometry in
            ZStack {
                // Layer 6a: Ground gradient (below horizon)
                groundGradient(horizonY: horizonY, size: geometry.size)

                // Layer 6b: Atmospheric scatter at horizon
                atmosphericScatter(horizonY: horizonY, size: geometry.size)

                // Layer 6c: Atmospheric haze layer
                atmosphericHaze(horizonY: horizonY, size: geometry.size)

                // Layer 6d: Static water reflection (when ocean is disabled)
                // Note: Ocean is rendered separately outside drawingGroup for independent animation
                if !effect.showOcean {
                    let waterVisibility = waterReflectionVisibility(sunAltitude: solarData.sunAltitude)
                    if waterVisibility > 0.01 {
                        waterReflectionGlow(horizonY: horizonY, size: geometry.size, visibility: waterVisibility)
                    }
                }

                // Layer 6e: Subtle horizon line (crisp edge)
                horizonEdgeLine(horizonY: horizonY, size: geometry.size)
            }
        }
    }

    // MARK: - Ground Gradient

    @ViewBuilder
    private func groundGradient(horizonY: CGFloat, size: CGSize) -> some View {
        let groundHeight = size.height - horizonY

        if groundHeight > 0 {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(intensity * 0.2),
                            Color.black.opacity(intensity * 0.4),
                            Color.black.opacity(intensity * 0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size.width, height: groundHeight)
                .position(x: size.width / 2, y: horizonY + groundHeight / 2)
        }
    }

    // MARK: - Keyframe Interpolation Helpers

    /// Interpolate color across altitude keyframes with smooth transitions
    private func interpolateColor(
        altitude: Double,
        keyframes: [(alt: Double, color: (r: Double, g: Double, b: Double))]
    ) -> Color {
        let sorted = keyframes.sorted { $0.alt < $1.alt }

        // Handle boundaries
        if altitude <= sorted.first!.alt {
            let c = sorted.first!.color
            return Color(red: c.r, green: c.g, blue: c.b)
        }
        if altitude >= sorted.last!.alt {
            let c = sorted.last!.color
            return Color(red: c.r, green: c.g, blue: c.b)
        }

        // Find bracketing keyframes and interpolate
        for i in 0..<(sorted.count - 1) {
            let lower = sorted[i]
            let upper = sorted[i + 1]

            if altitude >= lower.alt && altitude < upper.alt {
                let t = (altitude - lower.alt) / (upper.alt - lower.alt)
                let eased = ArcConfiguration.smootherstep(t)

                let r = lower.color.r + (upper.color.r - lower.color.r) * eased
                let g = lower.color.g + (upper.color.g - lower.color.g) * eased
                let b = lower.color.b + (upper.color.b - lower.color.b) * eased

                return Color(red: r, green: g, blue: b)
            }
        }

        // Fallback
        let c = sorted.last!.color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    /// Interpolate scalar value across altitude keyframes with smooth transitions
    private func interpolateValue(
        altitude: Double,
        keyframes: [(alt: Double, value: Double)]
    ) -> Double {
        let sorted = keyframes.sorted { $0.alt < $1.alt }

        if altitude <= sorted.first!.alt { return sorted.first!.value }
        if altitude >= sorted.last!.alt { return sorted.last!.value }

        for i in 0..<(sorted.count - 1) {
            let lower = sorted[i]
            let upper = sorted[i + 1]

            if altitude >= lower.alt && altitude < upper.alt {
                let t = (altitude - lower.alt) / (upper.alt - lower.alt)
                let eased = ArcConfiguration.smootherstep(t)
                return lower.value + (upper.value - lower.value) * eased
            }
        }

        return sorted.last!.value
    }

    // MARK: - Atmospheric Scatter

    @ViewBuilder
    private func atmosphericScatter(horizonY: CGFloat, size: CGSize) -> some View {
        let altitude = solarData.sunAltitude

        // Smooth keyframe-based color interpolation (no discrete thresholds)
        let colorKeyframes: [(alt: Double, color: (r: Double, g: Double, b: Double))] = [
            (-18, (0.1, 0.1, 0.2)),       // Deep night - dark blue
            (-12, (0.15, 0.1, 0.25)),     // Astronomical twilight
            (-6,  (0.3, 0.2, 0.4)),       // Nautical twilight - purple
            (0,   (0.9, 0.5, 0.2)),       // Civil twilight / horizon - orange
            (10,  (0.7, 0.7, 0.5)),       // Low day - warm
            (30,  (0.5, 0.6, 0.8)),       // Full day - blue
        ]
        let scatterColor = interpolateColor(altitude: altitude, keyframes: colorKeyframes)

        // Smooth keyframe-based intensity interpolation
        let intensityKeyframes: [(alt: Double, value: Double)] = [
            (-18, 0.05),   // Deep night - minimal
            (-12, 0.1),    // Astronomical twilight
            (-6,  0.25),   // Nautical twilight - building
            (0,   0.5),    // Civil twilight - peak warmth
            (10,  0.35),   // Low day
            (30,  0.15),   // Full day - reduced
        ]
        let scatterIntensity = interpolateValue(altitude: altitude, keyframes: intensityKeyframes)

        // Gradient band above and below horizon
        let bandHeight: CGFloat = 80

        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        scatterColor.opacity(scatterIntensity * intensity),
                        scatterColor.opacity(scatterIntensity * intensity * 0.5),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size.width, height: bandHeight)
            .position(x: size.width / 2, y: horizonY)
            .blur(radius: 15)
    }

    // MARK: - Atmospheric Haze

    @ViewBuilder
    private func atmosphericHaze(horizonY: CGFloat, size: CGSize) -> some View {
        let altitude = solarData.sunAltitude

        // Smooth keyframe-based haze color
        let colorKeyframes: [(alt: Double, color: (r: Double, g: Double, b: Double))] = [
            (-12, (0.15, 0.15, 0.25)),    // Deep twilight - cool blue-purple
            (-6,  (0.15, 0.15, 0.25)),    // Nautical twilight
            (0,   (0.4, 0.25, 0.2)),      // Horizon - warm brown
            (6,   (0.7, 0.45, 0.3)),      // Golden hour - warm orange
            (15,  (0.6, 0.7, 0.85)),      // Day - cool blue
        ]
        let hazeColor = interpolateColor(altitude: altitude, keyframes: colorKeyframes)

        // Smooth keyframe-based haze intensity
        let intensityKeyframes: [(alt: Double, value: Double)] = [
            (-12, 0.1),    // Deep twilight - minimal
            (-6,  0.1),    // Nautical twilight
            (0,   0.2),    // Horizon - building
            (6,   0.3),    // Golden hour - peak haze
            (15,  0.1),    // Day - reduced
        ]
        let hazeIntensity = interpolateValue(altitude: altitude, keyframes: intensityKeyframes)

        let hazeHeight: CGFloat = 120

        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        hazeColor.opacity(hazeIntensity * intensity * 0.3),
                        hazeColor.opacity(hazeIntensity * intensity * 0.6),
                        hazeColor.opacity(hazeIntensity * intensity * 0.3),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size.width, height: hazeHeight)
            .position(x: size.width / 2, y: horizonY + 20)
            .blur(radius: 25)
    }

    // MARK: - Water Reflection Visibility

    /// Smooth water reflection visibility with faded boundaries (no hard cutoff)
    private func waterReflectionVisibility(sunAltitude: Double) -> Double {
        // Fade in: +18° to +12° (high sun, subdued reflection)
        // Full: +12° to -6° (golden hour through civil twilight)
        // Fade out: -6° to -10° (into nautical twilight)

        if sunAltitude > 18 { return 0 }
        else if sunAltitude > 12 {
            let t = (18 - sunAltitude) / 6.0
            return ArcConfiguration.smootherstep(t) * 0.3  // Max 30% at high sun
        }
        else if sunAltitude > -6 {
            // Interpolate from 30% (at +12°) to 100% (at -6°)
            let t = (12 - sunAltitude) / 18.0
            return 0.3 + ArcConfiguration.smootherstep(t) * 0.7
        }
        else if sunAltitude > -10 {
            let t = (-sunAltitude - 6) / 4.0
            return 1.0 - ArcConfiguration.smootherstep(t)
        }
        else { return 0 }
    }

    // MARK: - Water Reflection Glow

    @ViewBuilder
    private func waterReflectionGlow(horizonY: CGFloat, size: CGSize, visibility: Double = 1.0) -> some View {
        // Calculate sun's horizontal position
        let sunInfo = config.sunPositionWithVisibility(for: solarData.dayProgress)
        let sunX = sunInfo.position.x

        // Reflection intensity based on sun altitude, modulated by visibility
        let reflectionIntensity: Double = {
            let base: Double
            if solarData.sunAltitude < 0 {
                base = max(0, (solarData.sunAltitude + 6) / 6) * 0.6
            } else if solarData.sunAltitude < 10 {
                base = 0.6 - (solarData.sunAltitude / 10) * 0.4
            } else {
                base = 0.2 - min(0.2, (solarData.sunAltitude - 10) / 50)
            }
            return base * visibility
        }()

        if reflectionIntensity > 0.01 {
            // Color matches current glow blend
            let blend = GlowBlend.from(progress: solarData.dayProgress, config: config)
            let reflectionColor = blend.blendColor(
                sunrise: (1.0, 0.6, 0.3),
                daytime: (0.7, 0.85, 1.0),
                sunset: (1.0, 0.5, 0.25)
            )

            // Elliptical glow below horizon (water reflection)
            let glowWidth = size.width * 0.5
            let glowHeight: CGFloat = 80

            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                reflectionColor.opacity(reflectionIntensity * intensity),
                                reflectionColor.opacity(reflectionIntensity * intensity * 0.5),
                                reflectionColor.opacity(reflectionIntensity * intensity * 0.2),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: glowWidth / 2
                        )
                    )
                    .frame(width: glowWidth, height: glowHeight)
                    .position(x: sunX, y: horizonY + glowHeight * 0.4)
                    .blur(radius: 20)

                // Secondary wider, softer reflection
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                reflectionColor.opacity(reflectionIntensity * intensity * 0.3),
                                reflectionColor.opacity(reflectionIntensity * intensity * 0.1),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: glowWidth * 0.8
                        )
                    )
                    .frame(width: glowWidth * 1.5, height: glowHeight * 0.6)
                    .position(x: sunX, y: horizonY + glowHeight * 0.6)
                    .blur(radius: 30)
            }
        }
    }

    // MARK: - Horizon Edge Line

    @ViewBuilder
    private func horizonEdgeLine(horizonY: CGFloat, size: CGSize) -> some View {
        ZStack {
            // Outer glow
            Canvas { context, _ in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: horizonY))
                path.addLine(to: CGPoint(x: size.width, y: horizonY))

                context.stroke(
                    path,
                    with: .color(Color.white.opacity(intensity * 0.1)),
                    style: StrokeStyle(lineWidth: 4)
                )
            }
            .blur(radius: 2)

            // Sharp line
            Canvas { context, _ in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: horizonY))
                path.addLine(to: CGPoint(x: size.width, y: horizonY))

                context.stroke(
                    path,
                    with: .color(Color.white.opacity(intensity * 0.12)),
                    style: StrokeStyle(lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Horizon Clip Shape

/// Shape that clips content above the horizon line (for sun clipping at sunrise/sunset)
struct HorizonClipShape: Shape {
    let horizonY: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Rectangle from top of view to horizon line only
        path.addRect(CGRect(x: 0, y: 0, width: rect.width, height: horizonY))
        return path
    }
}

// MARK: - Preview

#Preview("Solar Graph - Day") {
    ZStack {
        Color.black
        SolarGraphView(effect: {
            let effect = SolarGraphEffect()
            effect.intensity = 0.5
            effect.speed = 100
            return effect
        }())
    }
}
