//
//  MoonLayer.swift
//  rootshell
//
//  SwiftUI view for rendering the moon with phase shadows,
//  maria texture, glow effects, and earthshine.
//

import SwiftUI

/// Moon rendering layer for the solar graph effect
struct MoonLayer: View {
    let moonData: MoonData
    let solarData: SolarData
    let config: ArcConfiguration
    let intensity: Double
    let showMaria: Bool
    let showEarthshine: Bool
    let horizonY: CGFloat
    let animationTime: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let moonPosition = calculateMoonScreenPosition(
                moonData: moonData,
                size: geometry.size,
                horizonY: horizonY
            )

            // Orient the bright limb toward the sun as drawn by this effect.
            // Shader expects an angle measured from "north" (screen up) toward "east" (screen right).
            let sunPosition = config.extendedPosition(for: solarData.dayProgress)
            let brightLimbAngle = calculateBrightLimbAngle(moonPosition: moonPosition, sunPosition: sunPosition)

            // Only render if moon is visible
            let visibility = moonVisibility
            guard visibility > 0.01 else {
                return AnyView(EmptyView())
            }

            // Moon radius (~0.9x sun for slightly smaller apparent size)
            let baseRadius: CGFloat = 18
            let moonRadius = baseRadius * scaleFactor(altitude: moonData.position.altitude)

            // Keep the shader quad tight to avoid an unrealistic "atmospheric" halo.
            // Must be >= (2 * maxGlowRadius) used by `moonGlow` in `Views/Shaders/Moon.metal`.
            let glowExtent = moonRadius * 4.6

            // Thin crescents can become sub-pixel at this render size, especially in daytime when we
            // intentionally reduce visibility. Apply a small floor that ramps up as illumination
            // approaches new moon so the crescent stays perceptible.
            let illumination = moonData.phaseInfo.illumination
            let crescentVisibilityFloor: Double
            if illumination < 0.25 {
                let t = (0.25 - illumination) / 0.25 // 0 (quarter) → 1 (new)
                crescentVisibilityFloor = 0.25 + 0.25 * t // 0.25 → 0.5
            } else {
                crescentVisibilityFloor = 0.25
            }

            let effectiveIntensity = intensity * max(visibility, crescentVisibilityFloor)

            return AnyView(
                Rectangle()
                    .fill(Color.white)
                    .frame(width: glowExtent, height: glowExtent)
                    .colorEffect(ShaderLibrary.moonGlow(
                        .float(Float(glowExtent / 2)),  // moonCenterX (relative to view)
                        .float(Float(glowExtent / 2)),  // moonCenterY (relative to view)
                        .float(Float(moonRadius)),
                        .float(Float(effectiveIntensity)),
                        .float(Float(animationTime.truncatingRemainder(dividingBy: 1000))),
                        .float(Float(moonData.phaseInfo.illumination)),
                        .float(Float(moonData.phaseInfo.phaseAngle)),
                        .float(Float(brightLimbAngle)),
                        .float(showMaria ? 1.0 : 0.0),
                        .float(showEarthshine ? 1.0 : 0.0)
                    ))
                    .position(moonPosition)
                    .clipShape(HorizonClipShape(horizonY: horizonY))
            )
        }
    }

    // MARK: - Bright Limb Orientation

    /// Angle (degrees) from screen up (north) toward screen right (east).
    private func calculateBrightLimbAngle(moonPosition: CGPoint, sunPosition: CGPoint) -> Double {
        let dx = Double(sunPosition.x - moonPosition.x)
        let dy = Double(sunPosition.y - moonPosition.y)

        // Degenerate case: sun and moon overlap (or are extremely close).
        guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else {
            return moonData.phaseInfo.positionAngle
        }

        // Convert from screen vector (dx, dy) to "position angle" convention:
        // 0° = up, 90° = right, 180° = down, 270° = left.
        var degrees = atan2(dx, -dy) * 180.0 / .pi
        if degrees < 0 { degrees += 360.0 }
        return degrees
    }

    // MARK: - Moon Visibility

    /// Calculate moon visibility based on sun altitude
    /// Moon is more visible at night, faint during day
    private var moonVisibility: Double {
        // Not visible if below horizon
        guard moonData.isAboveHorizon else { return 0 }
        guard moonData.position.altitude > -5 else { return 0 }

        let sunAlt = solarData.sunAltitude

        if sunAlt > 0 {
            // Daytime: moon is faint but visible
            return 0.2
        } else if sunAlt > -12 {
            // Twilight: gradual brightening
            let t = -sunAlt / 12.0
            return 0.2 + 0.8 * ArcConfiguration.smootherstep(t)
        } else {
            // Night: full visibility
            return 1.0
        }
    }

    // MARK: - Position Calculation

    /// Calculate moon screen position from astronomical coordinates
    private func calculateMoonScreenPosition(
        moonData: MoonData,
        size: CGSize,
        horizonY: CGFloat
    ) -> CGPoint {
        let altitude = moonData.position.altitude
        let azimuth = moonData.position.azimuth

        // Map azimuth (0-360) to screen X position
        // 0 = North (center top area), 90 = East (right), 180 = South (center bottom), 270 = West (left)
        // For aesthetic reasons, map like the sun arc: E to W across the bottom
        // Azimuth 90 (east) -> left side, 180 (south) -> center, 270 (west) -> right side

        let normalizedAzimuth: Double
        if azimuth >= 90 && azimuth <= 270 {
            // East to West (visible arc)
            normalizedAzimuth = (azimuth - 90) / 180.0
        } else if azimuth > 270 {
            // West to North (behind horizon from perspective)
            normalizedAzimuth = 1.0 + (azimuth - 270) / 180.0
        } else {
            // North to East (behind horizon from perspective)
            normalizedAzimuth = (azimuth + 90) / 180.0 - 1.0
        }

        // Screen X: 0 = left edge, 1 = right edge
        let screenX = size.width * CGFloat(normalizedAzimuth.clamped(to: 0...1))

        // Map altitude to Y position
        // Higher altitude = higher on screen (lower Y value)
        // Altitude 0 = horizon, altitude 90 = zenith

        // Calculate how much of the view is above horizon
        let skyHeight = horizonY  // Space above horizon
        let maxAltitude = 90.0

        // Y position: horizon at horizonY, zenith approaches top
        let altitudeFraction = max(0, altitude) / maxAltitude
        let screenY = horizonY - (skyHeight * CGFloat(altitudeFraction) * 0.85)

        // If below horizon, position just below
        let finalY = altitude < 0 ? horizonY + CGFloat(-altitude) * 2 : screenY

        return CGPoint(x: screenX, y: finalY)
    }

    // MARK: - Scale Factor

    /// Scale moon size based on altitude (atmospheric perspective)
    private func scaleFactor(altitude: Double) -> CGFloat {
        if altitude < 0 {
            // Below horizon: shrink
            return max(0.5, CGFloat(1.0 + altitude / 20.0))
        } else if altitude < 15 {
            // Near horizon: slightly larger (moon illusion effect)
            return CGFloat(1.0 + (15.0 - altitude) / 100.0)
        } else {
            return 1.0
        }
    }
}

// MARK: - Clamped Extension

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
