//
//  BirdMigrationLayer.swift
//  rootshell
//
//  Renders animated bird migration flocks using Metal shaders.
//  Seabirds occasionally fly across the sky during the Solar background effect.
//  Features realistic flocking physics, species-specific formations, and wing animation.
//

import SwiftUI
import Combine
import CoreLocation
import os

/// Animated bird migration layer for the Solar ocean effect
struct BirdMigrationLayer: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BirdMigrationLayer")

    let oceanWidth: CGFloat
    let oceanHeight: CGFloat
    let solarData: SolarData
    let config: ArcConfiguration
    let effect: SolarGraphEffect

    @StateObject private var migrationState = BirdMigrationState()
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            ForEach(migrationState.activeFlocks) { flock in
                BirdMigrationShaderView(
                    width: oceanWidth,
                    height: oceanHeight,
                    flock: flock,
                    solarData: solarData,
                    config: config,
                    effect: effect
                )
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            Self.logger.info("BirdMigrationLayer appeared, starting timer")
            startTimer()
        }
        .onDisappear {
            Self.logger.info("BirdMigrationLayer disappeared, stopping timer")
            stopTimer()
        }
    }

    // MARK: - Timer Management

    private func startTimer() {
        stopTimer()

        Self.logger.info("Starting timer, effect.speed=\(self.effect.speed)")

        // Run at 10fps for state updates - don't need high frequency for spawn checks
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak migrationState] _ in
            guard let migrationState = migrationState else { return }

            // Calculate sun altitude fresh each time
            let now = Date()
            // Access effect.speed fresh each time (effect is a reference type)
            let isDemoMode = self.effect.speed > 1.0
            let sunAltitude: Double

            if isDemoMode {
                // In demo mode, calculate synthetic altitude from progress
                // Must match SolarGraphView.calculateProgress formula exactly
                let elapsed = self.effect.demoStartTime.distance(to: now) * self.effect.speed
                let progress = elapsed.truncatingRemainder(dividingBy: 86400) / 86400.0

                // Same formula as SolarGraphEffect.calculateSolarData
                let maxAltitude = 60.0
                let minAltitude = -18.0
                let midpoint = (maxAltitude + minAltitude) / 2.0
                let amplitude = (maxAltitude - minAltitude) / 2.0
                sunAltitude = midpoint + amplitude * sin((progress - 0.25) * 2.0 * .pi)
            } else {
                // Real-time mode - calculate from actual position
                let location = self.effect.getBestLocation()
                let position = SolarCalculator.calculatePosition(
                    date: now,
                    latitude: location.latitude,
                    longitude: location.longitude
                )
                sunAltitude = position.altitude
            }

            let animationFrameTime = self.effect.oceanTime(for: now.timeIntervalSinceReferenceDate, wrap: false)
            Task { @MainActor in
                migrationState.update(
                    realTime: now,
                    animationFrameTime: animationFrameTime,
                    sunAltitude: sunAltitude,
                    isDemoMode: isDemoMode
                )
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
