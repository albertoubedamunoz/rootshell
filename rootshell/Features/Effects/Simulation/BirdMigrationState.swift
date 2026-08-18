//
//  BirdMigrationState.swift
//  rootshell
//
//  State manager for bird migration flocks in the Solar ocean effect.
//  Handles timing, species selection, flock lifecycle, and daylight gating.
//

import SwiftUI
import Combine
import os

/// Seabird species for ocean-themed migrations
enum SeabirdSpecies: String, CaseIterable, Sendable, CustomStringConvertible {
    case pelican      // Loose diagonal lines, slow gliding flight
    case gull         // Scattered groups, erratic paths
    case cormorant    // Tight V-formations, steady rhythm

    var description: String { rawValue }

    var flockSizeRange: ClosedRange<Int> {
        switch self {
        case .pelican: return 3...8
        case .gull: return 5...15
        case .cormorant: return 6...12
        }
    }

    /// Base flight speed multiplier
    var baseSpeed: Double {
        switch self {
        case .pelican: return 0.6   // Slow, majestic
        case .gull: return 1.2      // Fast, darting
        case .cormorant: return 0.9 // Moderate, steady
        }
    }

    /// How tight the formation is (0 = scattered, 1 = tight)
    var formationTightness: Double {
        switch self {
        case .pelican: return 0.3   // Loose line
        case .gull: return 0.1      // Scattered cloud
        case .cormorant: return 0.8 // Tight V
        }
    }

    /// Index for shader (0=pelican, 1=gull, 2=cormorant)
    var shaderIndex: Float {
        switch self {
        case .pelican: return 0.0
        case .gull: return 1.0
        case .cormorant: return 2.0
        }
    }
}

/// Which edge the flock enters from
enum FlockEntryEdge: Sendable {
    case left
    case right

    var exitEdge: FlockEntryEdge {
        self == .left ? .right : .left
    }
}

/// A single flock currently in flight
struct BirdFlock: Identifiable, Sendable {
    let id: UUID
    let species: SeabirdSpecies
    let birdCount: Int
    let seed: UInt32                // For procedural bird position derivation
    let entryEdge: FlockEntryEdge   // Which screen edge flock enters from
    let baseDirection: Double       // Flight direction in radians (with wind influence)
    let spawnTime: Date
    /// Spawn time in corrected animation frame space (skips background pauses)
    let spawnFrameTime: TimeInterval
    let altitude: Double            // 0-1, how high on screen (0 = horizon, 1 = top)

    /// Progress across screen (0 = entry edge, 1 = exit edge)
    /// - Parameters:
    ///   - frameTime: Current corrected animation time
    ///   - speedMultiplier: Reserved for future use (birds always fly at normal speed)
    /// - Returns: Progress value, can exceed 1.0 for exit detection
    func progress(atFrameTime frameTime: TimeInterval, speedMultiplier: Double) -> Double {
        let elapsed = max(0.0, frameTime - spawnFrameTime)
        // Base crossing duration ~45 seconds, modified by species speed
        // Birds fly at constant speed regardless of demo mode
        let crossingDuration = 45.0 / species.baseSpeed
        return min(1.3, elapsed / crossingDuration) // Allow overshoot for clean exit
    }

    /// Whether the flock has completely exited the screen
    func isComplete(atFrameTime frameTime: TimeInterval, speedMultiplier: Double) -> Bool {
        progress(atFrameTime: frameTime, speedMultiplier: speedMultiplier) > 1.15
    }
}

/// State manager for bird migration timing and lifecycle
@MainActor
final class BirdMigrationState: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BirdMigration")

    // MARK: - Published State

    @Published private(set) var activeFlocks: [BirdFlock] = []

    // MARK: - Timing Constants

    private enum Interval {
        // Demo mode: frequent migrations for testing/viewing
        static let demoMinimum: Double = 30.0    // 30 seconds
        static let demoMaximum: Double = 90.0    // 1.5 minutes
        static let demoFirst: Double = 5.0       // Quick first appearance

        // Normal mode: ~5 minute intervals as specified
        static let normalMinimum: Double = 240.0   // 4 minutes
        static let normalMaximum: Double = 360.0   // 6 minutes
        static let normalFirst: Double = 120.0     // 2 minutes to first
    }

    /// Maximum concurrent flocks
    private let maxConcurrentFlocks = 3

    // MARK: - Internal State

    /// Time of the last flock spawn
    private var lastSpawnTime: Date = .distantPast

    /// Randomly determined interval until next spawn
    private var nextSpawnInterval: TimeInterval = Interval.normalFirst

    /// Whether we've initialized (first update received)
    private var isInitialized: Bool = false

    /// Current demo mode state
    private var isDemoModeActive: Bool = false

    /// Wind direction in radians (~14 degrees = 0.25 rad, matches Ocean.metal)
    private let windDirection: Double = 0.25

    // MARK: - Initialization

    init() {
        // State initialized lazily on first update
    }

    // MARK: - Update

    /// Update bird migration state
    /// - Parameters:
    ///   - realTime: Current real-world time
    ///   - sunAltitude: Sun altitude in degrees (for daylight check)
    ///   - isDemoMode: Whether demo mode is active (speed > 1.0)
    func update(realTime: Date, animationFrameTime: TimeInterval, sunAltitude: Double, isDemoMode: Bool) {
        // Track mode changes
        let wasDemoMode = isDemoModeActive
        isDemoModeActive = isDemoMode
        let modeChanged = isDemoMode != wasDemoMode

        // Initialize or reset on mode change
        if !isInitialized || modeChanged {
            lastSpawnTime = realTime
            nextSpawnInterval = isDemoMode ? Interval.demoFirst : Interval.normalFirst
            isInitialized = true
            Self.logger.info("Initialized: demoMode=\(isDemoMode), nextInterval=\(self.nextSpawnInterval)s")
        }

        // Birds always fly at normal speed regardless of demo mode
        // (demo mode only affects spawn frequency, not flight speed)
        let speedMultiplier = 1.0

        // Prune completed flocks
        activeFlocks.removeAll { $0.isComplete(atFrameTime: animationFrameTime, speedMultiplier: speedMultiplier) }

        // Daylight gate: only spawn during daylight (sun > -6 degrees for civil twilight)
        let isDaylight = sunAltitude > -6.0
        guard isDaylight else {
            return
        }

        // Check spawn interval
        let timeSinceLastSpawn = realTime.timeIntervalSince(lastSpawnTime)
        if timeSinceLastSpawn >= nextSpawnInterval && activeFlocks.count < maxConcurrentFlocks {
            Self.logger.info("Spawn interval reached: \(timeSinceLastSpawn)s >= \(self.nextSpawnInterval)s, sunAlt=\(sunAltitude)")
            spawnFlock(at: realTime, animationFrameTime: animationFrameTime)
        }
    }

    // MARK: - Flock Spawning

    private func spawnFlock(at time: Date, animationFrameTime: TimeInterval) {
        Self.logger.info("Spawning bird flock at \(time)")

        // Random species selection
        let species = SeabirdSpecies.allCases.randomElement()!
        let birdCount = Int.random(in: species.flockSizeRange)

        // Entry edge: slight bias toward wind direction (wind blows left-to-right)
        let windBias = Double.random(in: 0...1)
        let entryEdge: FlockEntryEdge = windBias > 0.6 ? .left : .right

        // Direction with wind influence + random variation
        // Base wind is ~14 degrees (0.25 rad), birds fly roughly with wind
        let directionVariation = Double.random(in: -0.4...0.4) // ±23 degrees
        var baseDirection = windDirection + directionVariation

        // Flip direction if entering from right (flying left)
        if entryEdge == .right {
            baseDirection = .pi - baseDirection
        }

        // Altitude: avoid very bottom (ocean/whale territory) and very top (off screen)
        let altitude = Double.random(in: 0.15...0.65)

        let flock = BirdFlock(
            id: UUID(),
            species: species,
            birdCount: birdCount,
            seed: UInt32.random(in: 0...UInt32.max),
            entryEdge: entryEdge,
            baseDirection: baseDirection,
            spawnTime: time,
            spawnFrameTime: animationFrameTime,
            altitude: altitude
        )

        activeFlocks.append(flock)
        lastSpawnTime = time
        scheduleNextSpawn()

        Self.logger.info("Spawned \(species) flock with \(birdCount) birds, altitude=\(altitude), direction=\(baseDirection)")
    }

    private func scheduleNextSpawn() {
        if isDemoModeActive {
            nextSpawnInterval = Double.random(in: Interval.demoMinimum...Interval.demoMaximum)
        } else {
            nextSpawnInterval = Double.random(in: Interval.normalMinimum...Interval.normalMaximum)
        }
    }

    // MARK: - Testing/Debug Support

    /// Force spawn a flock immediately (for testing)
    func forceSpawn() {
        let now = Date()
        spawnFlock(at: now, animationFrameTime: now.timeIntervalSinceReferenceDate)
    }

    /// Clear all active flocks
    func clearFlocks() {
        activeFlocks.removeAll()
    }
}
