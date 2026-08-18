//
//  WhaleShaderView.swift
//  rootshell
//
//  SwiftUI view hosting the Metal-based whale shader.
//  Renders a physics-based whale animation with SDF body, wave coupling,
//  Kelvin wake, and realistic blowhole spout.
//

import SwiftUI

/// SwiftUI view that hosts the whale Metal shader
struct WhaleShaderView: View {
    let width: CGFloat
    let height: CGFloat
    @ObservedObject var whaleState: WhaleAnimationState
    let solarData: SolarData
    let config: ArcConfiguration
    let oceanTime: Double
    let waveAmplitude: Float
    let waveSpeed: Float

    /// Wind direction for spout physics (normalized)
    private var windDirection: SIMD2<Float> {
        // Wind blows roughly toward the right with slight variation
        let windAngle: Float = 0.25  // radians, matches Ocean.metal
        return SIMD2<Float>(cos(windAngle), sin(windAngle))
    }

    /// Wind speed for spout advection (0-1)
    private var windSpeed: Float {
        // Moderate wind by default, could be connected to wave amplitude
        return min(1.0, waveAmplitude * 1.2)
    }

    /// Calculate whale scale based on view size
    private var whaleScale: Float {
        Float(min(width, height) / 400.0)
    }

    /// Get time-of-day blend weights
    private var timeOfDayBlend: GlowBlend {
        GlowBlend.from(progress: solarData.dayProgress, config: config)
    }

    /// Calculate sun X position (normalized 0-1) from day progress
    private var sunX: Float {
        let sunInfo = config.sunPositionWithVisibility(for: solarData.dayProgress)
        return Float(sunInfo.position.x / width)
    }

    /// 60fps baseline, halved in battery saver.
    private var frameInterval: Double {
        (1.0 / 60.0) * PowerManager.shared.effectIntervalScale
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            Rectangle()
                .fill(Color.white.opacity(0.001))  // Nearly invisible base for shader
                .frame(width: width, height: height)
                .colorEffect(
                    ShaderLibrary.whale(
                        // View parameters
                        .float(Float(width)),
                        .float(Float(height)),
                        .float(Float(oceanTime)),
                        // Whale state
                        .float(Float(whaleState.horizontalPosition)),
                        .float(Float(whaleState.verticalOffset)),
                        .float(Float(whaleState.diveAngle)),
                        .float(Float(whaleState.tailLift)),
                        .float(Float(whaleState.whaleOpacity)),
                        .float(Float(whaleState.depthFactor)),
                        // Phase
                        .float(Float(whaleState.phaseIndex)),
                        .float(Float(whaleState.phaseProgress)),
                        // Spout
                        .float(Float(whaleState.spoutIntensity)),
                        .float(Float(whaleState.spoutProgress)),
                        // Wind
                        .float(windDirection.x),
                        .float(windDirection.y),
                        .float(windSpeed),
                        // Environment
                        .float(Float(timeOfDayBlend.sunrise)),
                        .float(Float(timeOfDayBlend.daytime)),
                        .float(Float(timeOfDayBlend.sunset)),
                        .float(solarData.isNight ? 1.0 : 0.0),
                        .float(sunX),
                        .float(Float(solarData.sunAltitude)),
                        // Wave parameters
                        .float(waveAmplitude),
                        .float(waveSpeed),
                        // Scale
                        .float(whaleScale)
                    )
                )
        }
    }
}

// MARK: - WhaleAnimationState Extensions

extension WhaleAnimationState {
    /// Phase index for shader (0=idle, 1=emerging, 2=surfaced, 3=spouting, 4=diving)
    var phaseIndex: Int {
        switch phase {
        case .idle: return 0
        case .emerging: return 1
        case .surfaced: return 2
        case .spouting: return 3
        case .diving: return 4
        }
    }

    /// Progress within current phase (0-1)
    var phaseProgress: Double {
        switch phase {
        case .idle:
            return 0
        case .emerging(let progress):
            return progress
        case .surfaced:
            return 1.0
        case .spouting(let progress):
            return progress
        case .diving(let progress):
            return progress
        }
    }
}

// MARK: - Preview

// Preview disabled - SolarData requires complex initialization with SolarTimes
// To preview, use the full SolarGraphView which provides all necessary context
