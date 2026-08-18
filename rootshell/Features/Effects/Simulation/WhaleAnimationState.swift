//
//  WhaleAnimationState.swift
//  rootshell
//
//  State manager for whale animation in the Solar ocean effect.
//  Handles timing, phase transitions, and position management.
//

import SwiftUI
import Combine
import os.log

/// Animation phase for the whale surfacing sequence
enum WhalePhase: Equatable {
    case idle                           // No whale visible
    case emerging(progress: Double)     // 0-1, whale rises from water
    case surfaced                       // Whale at peak, brief pause
    case spouting(progress: Double)     // 0-1, water spout animation
    case diving(progress: Double)       // 0-1, whale descends with tail flip

    var isActive: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// State manager for whale animation timing and phases
final class WhaleAnimationState: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "WhaleAnimationState")

    // MARK: - Published State

    @Published private(set) var phase: WhalePhase = .idle
    @Published private(set) var horizontalPosition: Double = 0.5  // 0-1 normalized

    // MARK: - Timing Constants

    /// Duration of each animation phase in seconds
    /// Based on real humpback whale behavior:
    /// - Whales surface for 1-2 minutes taking 6-8 breaths
    /// - Each blow takes a few seconds, mist lingers 5-10 seconds
    /// - Gentle rise and descent, not abrupt
    private enum Duration {
        static let emerging: Double = 4.0      // Slow, graceful rise to surface
        static let surfaced: Double = 3.0      // Resting at surface, breathing
        static let spouting: Double = 8.0      // Multiple breaths, mist lingers
        static let diving: Double = 5.0        // Graceful descent with tail flip
        static let total: Double = emerging + surfaced + spouting + diving  // 20s
    }

    /// Interval range for whale appearances (real-time seconds)
    private enum Interval {
        // Demo mode: frequent appearances for testing/viewing
        static let demoFirstAppearance: Double = 3.0   // First whale appears quickly
        static let demoMinimum: Double = 60.0          // 1 minute
        static let demoMaximum: Double = 300.0         // 5 minutes

        // Normal mode: rare, delightful surprise appearances
        static let normalFirstAppearance: Double = 900.0   // First whale after 15 minutes
        static let normalMinimum: Double = 900.0           // 15 minutes
        static let normalMaximum: Double = 3600.0          // 60 minutes
    }

    // MARK: - Internal State

    /// Time when the current animation started (real time)
    private var animationStartTime: Date?

    /// Time of the last whale appearance (for scheduling next)
    private var lastAppearanceTime: Date = .distantPast

    /// Randomly determined interval until next appearance
    private var nextAppearanceInterval: TimeInterval = Interval.normalFirstAppearance

    /// Whether we've scheduled the first appearance
    private var isInitialized: Bool = false

    /// Demo mode active flag
    private var isDemoModeActive: Bool = false

    // MARK: - Timer-based updates
    private var displayLink: Timer?

    // MARK: - Initialization

    init() {
        // Timer will be started when demo mode activates
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Update

    /// Update whale animation state based on current real time
    /// - Parameters:
    ///   - realTime: Current real-world time
    ///   - isDemoMode: Whether demo mode is active (speed > 1.0)
    func update(realTime: Date, isDemoMode: Bool) {
        // Track demo mode changes
        let wasDemoMode = isDemoModeActive
        isDemoModeActive = isDemoMode

        // Handle mode transitions
        let modeChanged = isDemoMode != wasDemoMode

        // Initialize on first update or when mode changes
        if !isInitialized || modeChanged {
            lastAppearanceTime = realTime

            // Use appropriate first appearance interval for current mode
            if isDemoMode {
                nextAppearanceInterval = Interval.demoFirstAppearance
            } else {
                nextAppearanceInterval = Interval.normalFirstAppearance
            }
            isInitialized = true
        }

        // Handle ongoing animation (let it complete even if mode changes)
        if let startTime = animationStartTime {
            let elapsed = realTime.timeIntervalSince(startTime)
            updatePhase(elapsed: elapsed)
            return
        }

        // Check if it's time for a new appearance
        let timeSinceLastAppearance = realTime.timeIntervalSince(lastAppearanceTime)
        if timeSinceLastAppearance >= nextAppearanceInterval {
            startAnimation(at: realTime)
        }
    }

    // MARK: - Animation Control

    /// Start a new whale animation sequence
    private func startAnimation(at time: Date) {
        animationStartTime = time
        lastAppearanceTime = time

        // Random horizontal position (avoid extreme edges)
        horizontalPosition = Double.random(in: 0.15...0.85)

        // Begin with emerging phase
        phase = .emerging(progress: 0)

        // Schedule next appearance for after this one ends
        scheduleNextAppearance()
    }

    /// Update the current phase based on elapsed animation time
    private func updatePhase(elapsed: TimeInterval) {
        if elapsed < Duration.emerging {
            // Emerging phase
            let progress = elapsed / Duration.emerging
            phase = .emerging(progress: progress)
        } else if elapsed < Duration.emerging + Duration.surfaced {
            // Surfaced phase
            phase = .surfaced
        } else if elapsed < Duration.emerging + Duration.surfaced + Duration.spouting {
            // Spouting phase
            let spoutStart = Duration.emerging + Duration.surfaced
            let progress = (elapsed - spoutStart) / Duration.spouting
            phase = .spouting(progress: progress)
        } else if elapsed < Duration.total {
            // Diving phase
            let diveStart = Duration.emerging + Duration.surfaced + Duration.spouting
            let progress = (elapsed - diveStart) / Duration.diving
            phase = .diving(progress: progress)
        } else {
            // Animation complete
            phase = .idle
            animationStartTime = nil
        }
    }

    /// Schedule the next whale appearance with a random interval based on current mode
    private func scheduleNextAppearance() {
        if isDemoModeActive {
            nextAppearanceInterval = Double.random(in: Interval.demoMinimum...Interval.demoMaximum)
        } else {
            nextAppearanceInterval = Double.random(in: Interval.normalMinimum...Interval.normalMaximum)
        }
    }

    // MARK: - Computed Properties

    /// Progress through the entire animation sequence (0-1)
    var totalProgress: Double {
        guard let startTime = animationStartTime else { return 0 }
        let elapsed = Date.now.timeIntervalSince(startTime)
        return min(1.0, elapsed / Duration.total)
    }

    /// Whether a spout effect should be visible
    var isSpoutActive: Bool {
        if case .spouting = phase { return true }
        return false
    }

    /// Spout intensity for rendering (includes fade-in/out)
    var spoutIntensity: Double {
        guard case .spouting(let progress) = phase else { return 0 }

        // Quick rise, sustained spray, fade out
        if progress < 0.15 {
            return smootherstep(progress / 0.15)
        } else if progress < 0.7 {
            return 1.0
        } else {
            return 1.0 - smootherstep((progress - 0.7) / 0.3)
        }
    }

    /// Raw progress through spout phase (0-1), for timing particle animations
    var spoutProgress: Double {
        guard case .spouting(let progress) = phase else { return 0 }
        return progress
    }

    /// Tail lift amount for diving animation (0-1, peaks mid-dive)
    var tailLift: Double {
        guard case .diving(let progress) = phase else { return 0 }

        // Tail lifts during latter part of dive
        if progress < 0.4 {
            return 0
        } else if progress < 0.7 {
            return smootherstep((progress - 0.4) / 0.3)
        } else {
            return 1.0 - smootherstep((progress - 0.7) / 0.3) * 0.5  // Partial return
        }
    }

    /// Vertical offset for whale position (negative = above water line)
    var verticalOffset: Double {
        switch phase {
        case .idle:
            return 30  // Below surface
        case .emerging(let progress):
            // Rise from below to surface
            return 30 * (1.0 - smootherstep(progress))
        case .surfaced:
            return 0  // At surface
        case .spouting:
            return 0  // At surface
        case .diving(let progress):
            // Descend below surface
            return 30 * smootherstep(progress)
        }
    }

    /// Opacity for whale rendering (exponential falloff with depth)
    var whaleOpacity: Double {
        switch phase {
        case .idle:
            return 0
        case .emerging(let progress):
            // Exponential fade-in as whale rises from depth
            let depthProgress = 1.0 - smootherstep(progress)
            return pow(1.0 - depthProgress, 2.5)
        case .surfaced, .spouting:
            return 1.0
        case .diving(let progress):
            // Exponential fade-out as whale descends
            let depthProgress = smootherstep(progress)
            return pow(1.0 - depthProgress, 2.5)
        }
    }

    /// Depth factor for underwater visual effects (0 = surface, 1 = max depth)
    /// Used for color shift, scale reduction, edge softening
    var depthFactor: Double {
        switch phase {
        case .idle:
            return 1.0  // Fully submerged
        case .emerging(let progress):
            return 1.0 - smootherstep(progress)  // Rising toward surface (1.0 → 0.0)
        case .surfaced, .spouting:
            return 0.0  // At surface
        case .diving(let progress):
            return smootherstep(progress)  // Descending (0.0 → 1.0)
        }
    }

    /// Rotation angle for diving animation (radians)
    var diveAngle: Double {
        guard case .diving(let progress) = phase else { return 0 }
        // Tilt forward as whale dives
        return smootherstep(progress) * 0.3  // ~17 degrees max
    }

    // MARK: - Easing Functions

    /// Perlin's smootherstep (C2 continuous)
    private func smootherstep(_ t: Double) -> Double {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}
