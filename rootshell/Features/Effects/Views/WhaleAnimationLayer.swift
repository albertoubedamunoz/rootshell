//
//  WhaleAnimationLayer.swift
//  rootshell
//
//  Renders a physics-based whale animation using Metal shaders.
//  The whale occasionally surfaces in the ocean during the Solar background effect.
//  Features SDF-based body, Gerstner wave coupling, Kelvin wake, and realistic spout.
//

import SwiftUI
import Combine

/// Animated whale layer for the Solar ocean effect
/// Uses Metal shader for physics-based rendering
struct WhaleAnimationLayer: View {
    let oceanWidth: CGFloat
    let oceanHeight: CGFloat
    let solarData: SolarData
    let config: ArcConfiguration
    let animationTime: Double
    let effect: SolarGraphEffect

    @StateObject private var whaleState = WhaleAnimationState()
    @State private var timer: Timer?

    /// Wave amplitude passed to shader (matches ocean settings)
    private var waveAmplitude: Float {
        Float(effect.oceanWaveAmplitude)
    }

    /// Wave speed multiplier
    private var waveSpeed: Float {
        Float(effect.speed)
    }

    var body: some View {
        WhaleShaderView(
            width: oceanWidth,
            height: oceanHeight,
            whaleState: whaleState,
            solarData: solarData,
            config: config,
            oceanTime: animationTime,
            waveAmplitude: waveAmplitude,
            waveSpeed: waveSpeed
        )
        .allowsHitTesting(false)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: PowerManager.shared.tier) {
            startTimer()
        }
    }

    // MARK: - Timer Management

    private func startTimer() {
        stopTimer()
        // Run at 60fps to match animation (half rate in battery saver)
        // Capture effect (reference type) to access speed dynamically
        let effect = self.effect
        let state = whaleState
        let interval = (1.0 / 60.0) * PowerManager.shared.effectIntervalScale
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            // Access effect.speed fresh each time (effect is a reference type)
            let isDemoMode = effect.speed > 1.0
            state.update(realTime: Date(), isDemoMode: isDemoMode)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Helper Extensions

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
