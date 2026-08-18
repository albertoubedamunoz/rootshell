//
//  BirdMigrationShaderView.swift
//  rootshell
//
//  SwiftUI view hosting the Metal-based bird flock shader.
//  Renders flocking physics, species-specific formations, and wing animation.
//

import SwiftUI

/// SwiftUI view that hosts the bird flock Metal shader
struct BirdMigrationShaderView: View {
    let width: CGFloat
    let height: CGFloat
    let flock: BirdFlock
    let solarData: SolarData
    let config: ArcConfiguration
    let effect: SolarGraphEffect

    /// Wind direction for consistent physics (matches Ocean.metal)
    private var windDirection: SIMD2<Float> {
        let windAngle: Float = 0.25  // radians, ~14 degrees
        return SIMD2<Float>(cos(windAngle), sin(windAngle))
    }

    /// Time-of-day blend weights
    private var timeOfDayBlend: GlowBlend {
        GlowBlend.from(progress: solarData.dayProgress, config: config)
    }

    /// 40fps baseline, halved in battery saver.
    private var frameInterval: Double {
        (1.0 / 40.0) * PowerManager.shared.effectIntervalScale
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            let currentTime = timeline.date
            // Birds always fly at normal speed regardless of demo mode
            // (demo mode only affects spawn frequency, not flight speed)
            let speedMultiplier = 1.0
            // Use corrected, unwrapped time for smooth progress (no background jumps)
            let correctedTime = effect.oceanTime(for: currentTime.timeIntervalSinceReferenceDate, wrap: false)
            let progress = flock.progress(atFrameTime: correctedTime, speedMultiplier: speedMultiplier)
            // Use per-flock local time so internal motion never wraps abruptly
            let shaderTime = max(0.0, correctedTime - flock.spawnFrameTime)

            Rectangle()
                .fill(Color.white.opacity(0.001))  // Need non-zero content for shader
                .frame(width: width, height: height)
                .colorEffect(
                    ShaderLibrary.birds(
                        // View parameters
                        .float(Float(width)),
                        .float(Float(height)),
                        .float(Float(shaderTime)),
                        // Flock state
                        .float(Float(flock.birdCount)),
                        .float(Float(flock.seed)),
                        .float(flock.species.shaderIndex),
                        .float(Float(progress)),
                        .float(Float(flock.altitude)),
                        .float(Float(flock.baseDirection)),
                        .float(flock.entryEdge == .left ? 0.0 : 1.0),
                        // Wind
                        .float(windDirection.x),
                        .float(windDirection.y),
                        // Environment
                        .float(Float(timeOfDayBlend.sunrise)),
                        .float(Float(timeOfDayBlend.daytime)),
                        .float(Float(timeOfDayBlend.sunset)),
                        .float(solarData.isNight ? 1.0 : 0.0)
                    )
                )
        }
    }
}
