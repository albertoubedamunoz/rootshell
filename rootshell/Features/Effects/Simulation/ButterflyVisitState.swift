//
//  ButterflyVisitState.swift
//  rootshell
//
//  Model and visit lifecycle for the Butterflies background effect.
//  Butterflies occasionally drift across the terminal in small groups,
//  flutter with a flap-burst/glide rhythm, sometimes pause to rest, then
//  exit. All motion is a pure function of frame time so the renderer never
//  mutates state per frame; between visits the effect is fully idle.
//

import SwiftUI
import UIKit
import Combine
import os.log

// MARK: - Entry Edge

/// Which screen edge a butterfly enters from
enum ButterflyEntryEdge: Sendable {
    case left
    case right
}

// MARK: - Butterfly Model

/// A single butterfly in flight. Position, wing pose, and heading are all
/// closed-form functions of frame time (same approach as `Firefly`).
struct Butterfly: Identifiable, Sendable {
    let id: UUID

    // Path across the screen
    let spawnFrameTime: TimeInterval    // Animation-clock time when this butterfly starts (includes stagger)
    let entryEdge: ButterflyEntryEdge
    let entryY: Double                  // Entry height (fraction of view height)
    let exitYDrift: Double              // Height change over the crossing (fraction of view height)
    let crossingDuration: Double        // Seconds to cross the screen (speed-adjusted at spawn)

    // Wander: incommensurate sines (golden-ratio frequency trick) for an
    // organic, non-repeating meander layered over the base drift
    let wanderFreqX: Double             // Hz
    let wanderFreqY: Double             // Hz, ~freqX * golden ratio
    let wanderPhaseX: Double            // 0-2pi
    let wanderPhaseY: Double            // 0-2pi
    let wanderAmpX: Double              // Fraction of view width
    let wanderAmpY: Double              // Fraction of view height

    // Flutter rhythm: flap-flap-flap-glide. The butterfly gains a little
    // height during each flap burst and sinks gently while gliding.
    let flutterCycle: Double            // Seconds per burst+glide cycle
    let flapFraction: Double            // Portion of the cycle spent flapping (0-1)
    let flapFrequency: Double           // Wing beats per second during a burst
    let flapPhase0: Double              // 0-2pi
    let liftAmplitude: Double           // Points of rise per flutter burst

    // Optional mid-crossing rest: travel eases to a stop, the butterfly
    // hovers nearly still slowly fanning its wings, then continues
    let perchProgress: Double?          // Where along the crossing to rest (fraction), nil = no rest
    let perchDuration: Double           // Seconds at rest

    // Appearance
    let size: CGFloat                   // Body length in points
    let colorIndex: Int                 // Palette index for garden color mode

    // Calm gliding with no rapid flap bursts or flutter bob. Set when the
    // user turns off Wing Flutter or the system requests reduced motion.
    // Mutable so a settings change applies to butterflies already in flight.
    var glideOnly: Bool

    // MARK: Social steering (per-frame simulation state)
    //
    // The scripted path above is a pure function of time. These fields hold a
    // small spring-damped displacement from that path, integrated each frame by
    // `ButterflyVisitState.stepSocial(frameTime:)`, so butterflies can avoid
    // each other and interact. All default, so `makeButterfly(...)` is unchanged.

    /// Displacement of the rendered position away from the scripted path (points)
    var socialOffset: CGVector = .zero
    /// Velocity of that displacement (points/sec)
    var socialVel: CGVector = .zero
    /// Animation-clock time of the most recent integration step (nil until first
    /// integrated frame — keeps staggered, not-yet-born butterflies from taking a
    /// giant catch-up step on birth)
    var lastSimTime: TimeInterval? = nil
    /// Current courtship-dance partner, nil = not dancing
    var courtPartner: UUID? = nil
    /// Dance end time; after release this doubles as the cooldown deadline
    var courtUntil: TimeInterval = 0
    /// 0–1 startle/excitement scalar; drives the evasive wing-burst and body jolt
    var agitation: Double = 0

    /// Ease ramp length for entering/leaving a perch
    private static let perchRamp: Double = 1.0

    // MARK: Time mapping

    /// Travel time freezes while perched (with cosine-eased deceleration and
    /// takeoff) so the crossing pauses without any velocity discontinuity.
    func travelTime(at frameTime: TimeInterval) -> Double {
        let elapsed = frameTime - spawnFrameTime
        guard let perchProgress else { return elapsed }

        let perchStart = perchProgress * crossingDuration
        let p = elapsed - perchStart
        guard p > 0 else { return elapsed }

        let r = Self.perchRamp
        let d = max(perchDuration, 2 * r)
        let lost: Double
        if p <= r {
            // Decelerating: velocity 1 -> 0 over the ramp
            lost = 0.5 * p - (r / (2 * .pi)) * sin(.pi * p / r)
        } else if p <= d - r {
            // Fully stopped
            lost = 0.5 * r + (p - r)
        } else if p <= d {
            // Accelerating back to full speed
            let q = p - (d - r)
            lost = (d - 1.5 * r) + 0.5 * q + (r / (2 * .pi)) * sin(.pi * q / r)
        } else {
            lost = d - r
        }
        return elapsed - lost
    }

    /// How perched the butterfly is right now (0 = flying, 1 = at rest)
    func perchAmount(at frameTime: TimeInterval) -> Double {
        guard let perchProgress else { return 0 }
        let perchStart = perchProgress * crossingDuration
        let p = frameTime - spawnFrameTime - perchStart
        let r = Self.perchRamp
        let d = max(perchDuration, 2 * r)
        guard p > 0, p < d else { return 0 }
        if p < r { return Self.smootherstep(0, r, p) }
        if p > d - r { return 1 - Self.smootherstep(d - r, d, p) }
        return 1
    }

    /// Crossing progress (0 = entry edge, can exceed 1 for exit detection)
    func progress(at frameTime: TimeInterval) -> Double {
        travelTime(at: frameTime) / crossingDuration
    }

    /// Whether the butterfly has fully left the screen
    func isComplete(at frameTime: TimeInterval) -> Bool {
        progress(at: frameTime) > 1.05
    }

    // MARK: Position

    /// Crossing baseline at a given progress: entry-to-exit interpolation
    /// with no wander or flutter bob layered on.
    private func basePoint(progress prog: Double, in size: CGSize) -> CGPoint {
        // Offscreen margin large enough that wander can't peek early
        let margin = wanderAmpX * size.width + Double(self.size) * 2
        let startX = entryEdge == .left ? -margin : size.width + margin
        let endX = entryEdge == .left ? size.width + margin : -margin
        return CGPoint(x: startX + (endX - startX) * prog,
                       y: size.height * (entryY + exitYDrift * prog))
    }

    /// Lane-only position: the crossing baseline without the wander and
    /// flutter-bob micro-motion. The avoidance field is sampled here —
    /// sampled at the full scripted position, the bob/wander would pump a
    /// narrow text corridor's steep opposing gradients at ~1 Hz and the
    /// offset spring would echo it as a rapid wiggle instead of a glide.
    func lanePosition(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        basePoint(progress: travelTime(at: frameTime) / crossingDuration, in: size)
    }

    func position(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        let tt = travelTime(at: frameTime)
        let elapsed = frameTime - spawnFrameTime
        let base = basePoint(progress: tt / crossingDuration, in: size)

        // Wander runs on wall time so a perched butterfly still sways
        // slightly, but heavily damped while at rest
        let damp = 1 - 0.9 * perchAmount(at: frameTime)
        let wx = wanderAmpX * size.width * sin(2 * .pi * wanderFreqX * elapsed + wanderPhaseX) * damp
        let wy = wanderAmpY * size.height * sin(2 * .pi * wanderFreqY * elapsed + wanderPhaseY) * damp

        // Flutter bob: rise through the flap burst, sink through the glide
        var bob: Double = 0
        if !glideOnly {
            let u = positiveMod(tt / flutterCycle, 1.0)
            let shape = u < flapFraction
                ? Self.smootherstep(0, flapFraction, u)
                : 1 - Self.smootherstep(flapFraction, 1, u)
            bob = liftAmplitude * shape * damp
        }

        return CGPoint(x: base.x + wx, y: base.y + wy - bob)
    }

    // MARK: Wings

    /// Accumulated flapping phase. The clock only advances during flap
    /// bursts, so wing beats freeze mid-pose entering a glide and resume
    /// seamlessly at the next burst.
    func flapPhase(at frameTime: TimeInterval, lag: Double = 0) -> Double {
        let tt = travelTime(at: frameTime)
        let cycle = flutterCycle
        let burstLength = flapFraction * cycle
        let n = floor(tt / cycle)
        let u = tt - n * cycle
        let flapTime = n * burstLength + min(max(u, 0), burstLength)
        return flapPhase0 + 2 * .pi * flapFrequency * flapTime + lag
    }

    /// Horizontal wing scale (0.15-1.0). Burst = full beats that never go
    /// edge-on; glide = wings held open with a gentle sway; perch = slow
    /// open-close fanning.
    func wingScale(at frameTime: TimeInterval, lag: Double = 0) -> Double {
        let elapsed = frameTime - spawnFrameTime
        let glide = 0.88 + 0.08 * sin(2 * .pi * 0.8 * elapsed + flapPhase0)
        var scale = glide

        if !glideOnly {
            let tt = travelTime(at: frameTime)
            let u = positiveMod(tt, flutterCycle)
            let burstLength = flapFraction * flutterCycle
            let ramp = 0.12 * flutterCycle
            var burstWeight: Double = 0
            if u < burstLength {
                burstWeight = Self.smootherstep(0, ramp, u)
                    * (1 - Self.smootherstep(burstLength - ramp, burstLength, u))
            }
            let burst = 0.25 + 0.75 * abs(cos(flapPhase(at: frameTime, lag: lag)))
            scale = glide + (burst - glide) * burstWeight
        }

        // Perched: slow, contented wing fanning
        let perch = perchAmount(at: frameTime)
        if perch > 0 {
            let fan = 0.15 + 0.85 * abs(cos(2 * .pi * 0.4 * elapsed + flapPhase0))
            scale = scale + (fan - scale) * perch
        }
        return scale
    }

    // MARK: Heading

    /// Scripted velocity (points/sec) via central finite difference of the
    /// smooth position function, with the same upright rest-vector blend used
    /// while perched. Shared by `heading` and the rendered (social) heading.
    func scriptedVelocity(at frameTime: TimeInterval, in size: CGSize) -> CGVector {
        let dt = 0.08
        let p0 = position(at: frameTime - dt, in: size)
        let p1 = position(at: frameTime + dt, in: size)
        var vx = (p1.x - p0.x) / (2 * dt)
        var vy = (p1.y - p0.y) / (2 * dt)

        let perch = perchAmount(at: frameTime)
        if perch > 0 {
            // Blend velocity toward a gentle upward rest vector (no angle
            // wrapping issues since we interpolate the vector itself)
            let restX = (entryEdge == .left ? 1.0 : -1.0) * 6.0
            let restY = -14.0
            vx = vx + (restX - vx) * perch
            vy = vy + (restY - vy) * perch
        }
        return CGVector(dx: vx, dy: vy)
    }

    /// Flight heading in radians, following the velocity vector with damped
    /// vertical pitch so the butterfly banks through turns naturally.
    /// While perched it settles toward an upright, head-up pose.
    func heading(at frameTime: TimeInterval, in size: CGSize) -> Double {
        let v = scriptedVelocity(at: frameTime, in: size)
        return atan2(v.dy * 0.55, v.dx)
    }

    // MARK: Rendered (social) pose

    /// Visible position = scripted path + accumulated social offset.
    func renderPosition(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        let p = position(at: frameTime, in: size)
        return CGPoint(x: p.x + socialOffset.dx, y: p.y + socialOffset.dy)
    }

    /// Visible heading: the scripted velocity perturbed by the social-offset
    /// velocity, so an evasive veer visibly turns the butterfly into its move.
    func renderHeading(at frameTime: TimeInterval, in size: CGSize) -> Double {
        let v = scriptedVelocity(at: frameTime, in: size)
        let vx = v.dx + socialVel.dx
        let vy = v.dy + socialVel.dy
        return atan2(vy * 0.55, vx)
    }

    // MARK: Helpers

    private func positiveMod(_ value: Double, _ m: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    /// Smootherstep for C2-continuous transitions
    static func smootherstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

// MARK: - Visit State

/// Visit lifecycle manager (modeled on `BirdMigrationState`): schedules
/// occasional visits, spawns small groups, prunes butterflies that have
/// exited, and exposes `isIdle` to pause the render timeline entirely
/// between visits. Each `ButterfliesView` owns its own instance, so the
/// settings preview's frequent visits never affect the live overlay.
@MainActor
final class ButterflyVisitState: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Butterflies")

    // MARK: Published State

    /// The active butterflies. Deliberately NOT `@Published`: the only reader is
    /// the `Canvas` inside the `TimelineView`, which already redraws every frame
    /// from `timeline.date` while a visit is in progress. Publishing this would
    /// fire `objectWillChange` on every per-frame physics write in `stepSocial`
    /// (and on every prune/append), causing redundant SwiftUI body invalidations
    /// on top of the timeline tick. `isIdle` (below) is the sole reactive signal
    /// needed — it pauses/resumes the timeline, which is what starts and stops
    /// the redraws. Mutated in place (no per-frame copy/allocation).
    private(set) var butterflies: [Butterfly] = []

    /// True when no butterflies are on screen; drives the paused render timeline.
    /// This is the only state that needs to be `@Published`: flipping it false on
    /// spawn resumes the timeline (and redraws), flipping it true on the last
    /// prune pauses it.
    @Published private(set) var isIdle = true

    // MARK: Visit Frequency

    enum VisitFrequency: String, Codable, CaseIterable {
        case frequent
        case occasional
        case rare

        var displayName: String {
            switch self {
            case .frequent: return String(localized: "Frequent", comment: "Butterfly visit frequency: every 1-2 minutes")
            case .occasional: return String(localized: "Occasional", comment: "Butterfly visit frequency: every 3-6 minutes")
            case .rare: return String(localized: "Rare", comment: "Butterfly visit frequency: every 10-20 minutes")
            }
        }

        var intervalDescription: String {
            switch self {
            case .frequent: return String(localized: "About every 1–2 minutes", comment: "Caption for frequent butterfly visits")
            case .occasional: return String(localized: "About every 3–6 minutes", comment: "Caption for occasional butterfly visits")
            case .rare: return String(localized: "About every 10–20 minutes", comment: "Caption for rare butterfly visits")
            }
        }

        var intervalRange: ClosedRange<Double> {
            switch self {
            case .frequent: return 60...120
            case .occasional: return 180...360
            case .rare: return 600...1200
            }
        }

        /// Shorter first wait so the user sees something soon after enabling
        var firstVisitRange: ClosedRange<Double> {
            switch self {
            case .frequent: return 10...25
            case .occasional: return 15...45
            case .rare: return 30...90
            }
        }
    }

    // MARK: Internal State

    /// Animation clock epoch; frame times are seconds since this date
    private let epoch = Date.now

    private weak var effect: ButterfliesEffect?
    private var previewMode = false
    private var hasStarted = false
    private var visitTask: Task<Void, Never>?
    private var configCancellable: AnyCancellable?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastFrequency: VisitFrequency = .occasional
    private var lastFlutterEnabled = true
    private var lastTextAvoidanceEnabled = true

    /// Terminal-text tracker (nil in previews, which have no terminal behind
    /// them). Ticked from update(), so it costs nothing while idle.
    private var tracker: TextRegionTracker?
    /// Latched true while visits are paused on a mostly-full screen; the
    /// spawn gate then requires coverage to drop below the resume threshold
    /// (hysteresis against flapping around one value).
    private var coverageWaiting = false

    /// Current view size, kept fresh by the view for spawn geometry
    var viewSize: CGSize = .zero

    /// Effect canvas frame in global coordinates, kept fresh by the view so
    /// the tracker can convert terminal-space rects into canvas space
    var canvasFrameInGlobal: CGRect = .zero {
        didSet { tracker?.canvasFrameInGlobal = canvasFrameInGlobal }
    }

    // MARK: Clock

    nonisolated func frameTime(at date: Date) -> TimeInterval {
        date.timeIntervalSince(epoch)
    }

    // MARK: Lifecycle

    func start(effect: ButterfliesEffect, previewMode: Bool) {
        guard !hasStarted else { return }
        hasStarted = true
        self.effect = effect
        self.previewMode = previewMode
        lastFrequency = effect.visitFrequency
        lastFlutterEnabled = effect.flutterEnabled
        lastTextAvoidanceEnabled = effect.textAvoidanceEnabled

        // Previews have no terminal behind them, so they never construct a
        // tracker — the toggle is a no-op there by design
        if !previewMode {
            let tracker = TextRegionTracker()
            tracker.canvasFrameInGlobal = canvasFrameInGlobal
            self.tracker = tracker
        }

        configCancellable = effect.configurationDidChange.sink { [weak self] in
            guard let self, let effect = self.effect else { return }

            // Re-arm the idle wait when the user changes visit frequency
            if effect.visitFrequency != self.lastFrequency {
                self.lastFrequency = effect.visitFrequency
                if self.isIdle { self.scheduleNextVisit() }
            }

            // Apply a Wing Flutter change to butterflies already in flight;
            // crossings last up to a minute, so waiting for the next visit
            // makes the toggle look broken
            if effect.flutterEnabled != self.lastFlutterEnabled {
                self.lastFlutterEnabled = effect.flutterEnabled
                let glideOnly = UIAccessibility.isReduceMotionEnabled || !effect.flutterEnabled
                self.butterflies = self.butterflies.map { butterfly in
                    var updated = butterfly
                    updated.glideOnly = glideOnly
                    return updated
                }
            }

            // Text Avoidance applies to in-flight butterflies immediately:
            // forces stop next frame and the home spring glides them back
            self.lastTextAvoidanceEnabled = effect.textAvoidanceEnabled
        }

        // The app keeps running in the background during long-lived SSH
        // sessions, so the visit timer would keep spawning and un-pause the
        // render timeline with no screen to draw to. Go fully idle instead.
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasStarted else { return }
                self.visitTask?.cancel()
                self.visitTask = nil
                self.butterflies = []
                self.isIdle = true
            }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hasStarted, self.isIdle else { return }
                self.scheduleNextVisit()
            }
        })

        scheduleNextVisit(first: true)
    }

    func stop() {
        visitTask?.cancel()
        visitTask = nil
        configCancellable = nil
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers = []
        butterflies = []
        isIdle = true
        hasStarted = false
        tracker = nil
        coverageWaiting = false
    }

    /// Called once per rendered frame; integrates the social steering layer,
    /// prunes exited butterflies, and goes idle (pausing the timeline) when the
    /// visit is over. Runs only while butterflies are present, so it adds zero
    /// cost between visits.
    func update(frameTime: TimeInterval) {
        guard !butterflies.isEmpty else { return }
        if lastTextAvoidanceEnabled {
            tracker?.tick(now: frameTime)
        }
        stepSocial(frameTime: frameTime)
        butterflies.removeAll { $0.isComplete(at: frameTime) }
        if butterflies.isEmpty {
            isIdle = true
            scheduleNextVisit()
        }
    }

    /// Spawn a visit immediately (settings "Visit Now" and previews). The
    /// user asked, so the coverage gate is bypassed — lanes are still chosen
    /// around the text.
    func forceSpawn() {
        spawnVisit(ignoringCoverage: true)
    }

    // MARK: - Social Steering

    /// Tunable constants for the per-frame steering simulation. Kept together
    /// for easy on-device tuning. All forces are accelerations (mass = 1).
    private enum SteerConstants {
        static let kSpring: Double = 6.0          // pull offset back to scripted path
        static let damping: Double = 4.0          // velocity damping (ζ≈0.82)
        static let sepFactor: Double = 2.6        // separation radius ÷ mean body length
        static let sepStrength: Double = 1400     // collision repulsion peak (pt/s²)
        static let courtFactor: Double = 5.5      // courtship radius ÷ mean body length
        static let relSpeedThresh: Double = 60    // max relative scripted speed to start a dance
        static let courtRadial: Double = 3.0      // hold a loose orbit ring (softer than kSpring)
        static let courtTangential: Double = 90   // orbit swirl (pt/s²), opposite sign per partner
        static let orbitRatio: Double = 0.55      // orbitRadius = orbitRatio × courtRadius
        static let danceMin: Double = 3.0
        static let danceMax: Double = 5.0
        static let cooldown: Double = 6.0         // post-dance refractory (s)
        static let maxVel: Double = 220           // clamp on |socialVel| (pt/s)
        static let maxOffset: Double = 70         // clamp on |socialOffset| (pt)
        static let dtClamp: Double = 0.10         // max integration step (s)
        static let courtSpringWeight: Double = 0.25 // home-spring weight while courting

        // Text avoidance. Spawn-time lane selection owns big stable text
        // blocks; these forces only clear text that appears mid-crossing,
        // plus the cursor bubble.
        // The field is sampled open-loop at the scripted position, so a
        // sustained push settles at strength × weight / kSpring exactly.
        static let textBandRadius: Double = 60    // standoff onset (~2.5 rows)
        static let textBandStrength: Double = 300 // ≈75pt settled deep inside a band (1.5×300/6)
        static let cursorStrength: Double = 600   // ≈100pt settled inside the core bubble
        static let cursorInfluence: Double = 2.0  // falloff shell = 2× core bubble radius
        static let maxOffsetAvoid: Double = 110   // raised cap: room to clear a 4-row band
    }

    /// Per-frame social steering: collision avoidance, the courtship orbit, and
    /// the "agitation" scalar that drives an evasive flutter. Integrates a
    /// spring-damped offset from each butterfly's scripted path. O(n²) over the
    /// handful of butterflies in a visit, with scripted positions cached once.
    private func stepSocial(frameTime: TimeInterval) {
        typealias K = SteerConstants

        // Reduce Motion fully disables the social layer (motion is identical to
        // the original scripted paths); Low Power keeps avoidance but drops the
        // optional courtship dance.
        let motionScale: Double
        let allowCourtship: Bool
        if UIAccessibility.isReduceMotionEnabled {
            motionScale = 0
            allowCourtship = false
        } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
            motionScale = 0.6
            allowCourtship = false
        } else {
            motionScale = 1.0
            allowCourtship = true
        }

        let count = butterflies.count

        // Reduce Motion: smoothly bleed any residual perturbation to zero and
        // stop. (Toggling mid-flight then glides each butterfly home over ~0.25s
        // rather than snapping.)
        if motionScale == 0 {
            for i in 0..<count {
                let dt = max(0, min(frameTime - (butterflies[i].lastSimTime ?? frameTime), K.dtClamp))
                let decay = exp(-dt / 0.25)
                butterflies[i].socialOffset.dx *= decay
                butterflies[i].socialOffset.dy *= decay
                butterflies[i].socialVel.dx *= decay
                butterflies[i].socialVel.dy *= decay
                butterflies[i].agitation *= decay
                butterflies[i].courtPartner = nil
                butterflies[i].lastSimTime = frameTime
            }
            return
        }

        let size = viewSize
        guard size.width > 1, size.height > 1 else { return }

        // Smaller views (settings preview) scale social radii/strength down so a
        // cramped 140pt box shows a hint of avoidance instead of pinball.
        let minDim = min(size.width, size.height)
        let crampScale = min(1.0, minDim / 400.0)
        // Text avoidance needs more room to clear a band than the social
        // forces ever do; previews never have a tracker, so their cramped
        // clamp is untouched.
        let avoidField: TextAvoidanceField? = {
            guard lastTextAvoidanceEnabled, let field = tracker?.field, field.isActive else { return nil }
            return field
        }()
        let maxOffset = avoidField != nil
            ? min(K.maxOffsetAvoid, minDim * 0.28)
            : min(K.maxOffset, minDim * 0.18)

        // Cache scripted state once per frame for the born set.
        var born = [Bool](repeating: false, count: count)
        var scriptVel = [CGVector](repeating: .zero, count: count)
        var renderPos = [CGPoint](repeating: .zero, count: count)
        var perch = [Double](repeating: 0, count: count)
        var prog = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let b = butterflies[i]
            guard frameTime >= b.spawnFrameTime else { continue }
            born[i] = true
            let p = b.position(at: frameTime, in: size)
            renderPos[i] = CGPoint(x: p.x + b.socialOffset.dx, y: p.y + b.socialOffset.dy)
            scriptVel[i] = b.scriptedVelocity(at: frameTime, in: size)
            perch[i] = b.perchAmount(at: frameTime)
            prog[i] = b.progress(at: frameTime)
        }

        // --- Courtship pairing pass ---
        if allowCourtship {
            // Release finished or now-invalid pairings (sets the cooldown deadline).
            for i in 0..<count {
                guard let partnerID = butterflies[i].courtPartner else { continue }
                let pj = butterflies.firstIndex { $0.id == partnerID }
                let partnerBad = pj.map { !born[$0] || perch[$0] > 0.2 || prog[$0] > 0.9 } ?? true
                if frameTime >= butterflies[i].courtUntil || partnerBad
                    || !born[i] || perch[i] > 0.2 || prog[i] > 0.9 {
                    butterflies[i].courtPartner = nil
                    butterflies[i].courtUntil = frameTime + K.cooldown
                }
            }

            // Form at most one new pairing per frame: the closest eligible pair.
            // Small group sizes keep this to ~one dance at a time.
            func eligible(_ i: Int) -> Bool {
                born[i] && butterflies[i].courtPartner == nil
                    && frameTime >= butterflies[i].courtUntil    // past cooldown
                    && perch[i] < 0.2 && prog[i] > 0.05 && prog[i] < 0.9
            }
            var bestI = -1, bestJ = -1
            var bestDist = Double.greatestFiniteMagnitude
            for i in 0..<count where eligible(i) {
                for j in (i + 1)..<count where eligible(j) {
                    let courtRadius = K.courtFactor * Double(butterflies[i].size + butterflies[j].size) / 2 * crampScale
                    let dx = renderPos[i].x - renderPos[j].x
                    let dy = renderPos[i].y - renderPos[j].y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    guard dist < courtRadius else { continue }
                    let rvx = scriptVel[i].dx - scriptVel[j].dx
                    let rvy = scriptVel[i].dy - scriptVel[j].dy
                    let relSpeed = (rvx * rvx + rvy * rvy).squareRoot()
                    guard relSpeed < K.relSpeedThresh, dist < bestDist else { continue }
                    bestDist = dist; bestI = i; bestJ = j
                }
            }
            if bestI >= 0 {
                let until = frameTime + Double.random(in: K.danceMin...K.danceMax)
                butterflies[bestI].courtPartner = butterflies[bestJ].id
                butterflies[bestJ].courtPartner = butterflies[bestI].id
                butterflies[bestI].courtUntil = until
                butterflies[bestJ].courtUntil = until
            }
        } else {
            // Courtship disallowed (Low Power): drop any active pairings.
            for i in 0..<count where butterflies[i].courtPartner != nil {
                butterflies[i].courtPartner = nil
            }
        }

        // --- Force accumulation + integration (simultaneous: neighbor reads use
        // the frame-start caches, so order within the loop doesn't matter) ---
        for i in 0..<count {
            guard born[i] else { continue }
            var b = butterflies[i]
            let dt = max(0, min(frameTime - (b.lastSimTime ?? frameTime), K.dtClamp))
            let exitTaper = 1 - Butterfly.smootherstep(0.9, 1.05, prog[i])
            let perchResp = 1 - 0.85 * perch[i]   // resting butterflies barely drift

            // Restorative home spring + damping (always active). A perched
            // butterfly springs home faster so it stays planted; a courting one
            // relaxes the spring so the orbit can form.
            let courting = b.courtPartner != nil
            let springK = courting ? K.kSpring * K.courtSpringWeight : K.kSpring * (1 + perch[i])
            var fx = -springK * b.socialOffset.dx - K.damping * b.socialVel.dx
            var fy = -springK * b.socialOffset.dy - K.damping * b.socialVel.dy

            // Interaction forces (separation + courtship), scaled by motion /
            // perch / exit so they fade where they shouldn't act.
            var ifx = 0.0, ify = 0.0
            var agitationTarget = 0.0

            // Separation (collision avoidance) from every other born butterfly.
            for j in 0..<count where j != i && born[j] {
                let sepRadius = K.sepFactor * Double(b.size + butterflies[j].size) / 2 * crampScale
                var dx = renderPos[i].x - renderPos[j].x
                var dy = renderPos[i].y - renderPos[j].y
                var dist = (dx * dx + dy * dy).squareRoot()
                if dist < 0.5 {
                    // Degenerate overlap: deterministic tie-break direction.
                    let h = Double(b.id.hashValue & 0xffff) / 65535.0 * 2 * .pi
                    dx = cos(h); dy = sin(h); dist = 1
                }
                guard dist < sepRadius else { continue }
                let nx = dx / dist, ny = dy / dist
                let w = 1 - dist / sepRadius
                var strength = K.sepStrength * w * w
                if dist < 0.5 * sepRadius {
                    strength += K.sepStrength * 0.6   // anti-overlap floor
                }
                ifx += strength * nx
                ify += strength * ny
                agitationTarget = max(agitationTarget, 0.6 * w)
            }

            // Courtship orbit: radial spring to the ideal ring + tangential swirl.
            if courting, let partnerID = b.courtPartner,
               let pj = butterflies.firstIndex(where: { $0.id == partnerID }), born[pj] {
                let dx = renderPos[i].x - renderPos[pj].x
                let dy = renderPos[i].y - renderPos[pj].y
                var dist = (dx * dx + dy * dy).squareRoot()
                if dist < 0.5 { dist = 0.5 }
                let nx = dx / dist, ny = dy / dist
                let courtRadius = K.courtFactor * Double(b.size + butterflies[pj].size) / 2 * crampScale
                let radialErr = dist - K.orbitRatio * courtRadius
                ifx += -K.courtRadial * radialErr * nx
                ify += -K.courtRadial * radialErr * ny
                // Opposite tangential sign per partner → pinwheel about the midpoint.
                let sign: Double = b.id.uuidString < butterflies[pj].id.uuidString ? 1 : -1
                ifx += K.courtTangential * sign * (-ny)
                ify += K.courtTangential * sign * nx
                agitationTarget = max(agitationTarget, 0.3)
            }

            // Text avoidance: soft push off text bands (rides iscale like the
            // other interactions), strong cursor bubble applied directly —
            // it bypasses perchResp because a perched butterfly must startle
            // when output lands beneath it. Sampled at the LANE position:
            // open-loop (never the displaced renderPos — the field's steep
            // gradients would couple into the spring and ring, seen as rapid
            // bouncing plus heading whip since renderHeading follows
            // socialVel), and de-noised (the full scripted position carries
            // flutter bob + wander, which pump a narrow corridor's opposing
            // gradients at ~1 Hz into a visible wiggle). Steady-state
            // displacement for a sustained push is strength × weight / kSpring.
            if let field = avoidField {
                let lane = b.lanePosition(at: frameTime, in: size)
                let sample = TextAvoidanceForce.evaluate(
                    at: lane, field: field,
                    bandRadius: K.textBandRadius,
                    cursorInfluenceScale: K.cursorInfluence,
                    seed: b.id.hashValue)
                // On a mostly-full screen the bands would shove from every
                // side at once; fall back to cursor-bubble-only
                if field.coverage <= TextRegionTracker.CoverageGate.suppress {
                    ifx += K.textBandStrength * sample.bandFx
                    ify += K.textBandStrength * sample.bandFy
                }
                let cscale = motionScale * exitTaper
                fx += K.cursorStrength * sample.cursorFx * cscale
                fy += K.cursorStrength * sample.cursorFy * cscale
                agitationTarget = max(agitationTarget, sample.agitation * motionScale)
            }

            let iscale = motionScale * perchResp * exitTaper
            fx += ifx * iscale
            fy += ify * iscale

            // Semi-implicit (symplectic) Euler.
            b.socialVel.dx += fx * dt
            b.socialVel.dy += fy * dt
            let speed = (b.socialVel.dx * b.socialVel.dx + b.socialVel.dy * b.socialVel.dy).squareRoot()
            if speed > K.maxVel, speed > 0 {
                let k = K.maxVel / speed
                b.socialVel.dx *= k; b.socialVel.dy *= k
            }
            b.socialOffset.dx += b.socialVel.dx * dt
            b.socialOffset.dy += b.socialVel.dy * dt
            let off = (b.socialOffset.dx * b.socialOffset.dx + b.socialOffset.dy * b.socialOffset.dy).squareRoot()
            if off > maxOffset, off > 0 {
                let k = maxOffset / off
                b.socialOffset.dx *= k; b.socialOffset.dy *= k
                // Press against the cap instead of buzzing: drop outward velocity.
                let nx = b.socialOffset.dx / maxOffset, ny = b.socialOffset.dy / maxOffset
                let vn = b.socialVel.dx * nx + b.socialVel.dy * ny
                if vn > 0 { b.socialVel.dx -= nx * vn; b.socialVel.dy -= ny * vn }
            }

            // Agitation: snap up to the encounter target, otherwise decay (~0.9s).
            b.agitation = agitationTarget > b.agitation ? agitationTarget : b.agitation * exp(-dt / 0.6)

            b.lastSimTime = frameTime
            butterflies[i] = b
        }
    }

    // MARK: Scheduling

    private func scheduleNextVisit(first: Bool = false) {
        visitTask?.cancel()
        guard let effect else { return }

        var interval: Double
        if previewMode {
            interval = first ? 0.3 : Double.random(in: 8...15)
        } else {
            let frequency = effect.visitFrequency
            interval = first
                ? Double.random(in: frequency.firstVisitRange)
                : Double.random(in: frequency.intervalRange)
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                interval *= 2
            }
        }

        let waitSeconds = interval
        Self.logger.info("Next butterfly visit in \(waitSeconds, format: .fixed(precision: 1))s")

        visitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(waitSeconds), tolerance: .seconds(max(waitSeconds * 0.1, 0.05)))
            guard !Task.isCancelled else { return }
            self?.spawnVisit()
        }
    }

    // MARK: Spawning

    private func spawnVisit(ignoringCoverage: Bool = false) {
        guard let effect else { return }
        // A sleeping visit task can fire mid-transition before the
        // didEnterBackground observer runs; the foreground observer re-arms
        guard UIApplication.shared.applicationState != .background else { return }
        guard viewSize.width > 50, viewSize.height > 50 else {
            // Layout not ready yet; try again shortly
            visitTask?.cancel()
            visitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.spawnVisit()
            }
            return
        }

        let now = frameTime(at: Date.now)

        // Text avoidance: refresh the field for lane selection, and defer the
        // visit while the screen is mostly full of text (vim, htop, a long
        // build) — the butterflies would have nowhere text-free to fly.
        var avoidField: TextAvoidanceField?
        if !previewMode, effect.textAvoidanceEnabled, let tracker {
            tracker.scanForSpawn(now: now)
            let field = tracker.field
            if field.isActive { avoidField = field }

            // Only ever gate WITH data (isValid); hysteresis so coverage
            // hovering near the threshold can't flap the gate.
            if !ignoringCoverage, field.isValid {
                let gate = coverageWaiting
                    ? TextRegionTracker.CoverageGate.resume
                    : TextRegionTracker.CoverageGate.suppress
                if field.coverage > gate {
                    coverageWaiting = true
                    let retry = Double.random(in: 20...40)
                    let coveragePct = Int(field.coverage * 100)
                    Self.logger.info("Butterfly visit deferred: \(coveragePct)% text coverage, retry in \(retry, format: .fixed(precision: 0))s")
                    visitTask?.cancel()
                    visitTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(retry))
                        guard !Task.isCancelled else { return }
                        self?.spawnVisit()
                    }
                    return
                }
            }
        }
        coverageWaiting = false

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let speed = min(max(effect.speed, 0.25), 2.0)

        // Small groups: usually one or two, occasionally three
        let roll = Double.random(in: 0..<1)
        var count = roll < 0.45 ? 1 : (roll < 0.80 ? 2 : 3)
        if effect.moreButterflies { count += 1 }

        // The group shares an entry edge and loose formation height, but
        // each butterfly flies its own path. The formation height is drawn
        // from the candidates that best clear the current text.
        let entryEdge: ButterflyEntryEdge = Bool.random() ? .left : .right
        let baseEntryY = TextAvoidanceForce.pickEntryY(
            in: 0.18...0.62,
            entryFromLeft: entryEdge == .left,
            field: avoidField,
            viewSize: viewSize)

        var newButterflies: [Butterfly] = []
        for index in 0..<count {
            let stagger = index == 0 ? 0 : Double.random(in: 0.5...4.0)
            newButterflies.append(makeButterfly(
                spawnFrameTime: now + stagger,
                entryEdge: entryEdge,
                baseEntryY: baseEntryY,
                speed: speed,
                perchingEnabled: effect.perchingEnabled,
                flutterEnabled: effect.flutterEnabled,
                reduceMotion: reduceMotion,
                avoidField: avoidField
            ))
        }

        butterflies.append(contentsOf: newButterflies)
        isIdle = false

        let spawnCount = newButterflies.count
        Self.logger.info("Butterfly visit: \(spawnCount) arriving from \(entryEdge == .left ? "left" : "right")")
    }

    private func makeButterfly(
        spawnFrameTime: TimeInterval,
        entryEdge: ButterflyEntryEdge,
        baseEntryY: Double,
        speed: Double,
        perchingEnabled: Bool,
        flutterEnabled: Bool,
        reduceMotion: Bool,
        avoidField: TextAvoidanceField? = nil
    ) -> Butterfly {
        let goldenRatio = 1.618033988749895
        let wanderFreq = Double.random(in: 0.08...0.16) * speed

        // Keep the whole crossing comfortably on screen: clamp the entry
        // height, then pick an exit drift that can't push past the edges
        var entryY = min(max(baseEntryY + Double.random(in: -0.12...0.12), 0.08), 0.80)
        var exitYDrift = min(max(Double.random(in: -0.25...0.25), 0.10 - entryY), 0.82 - entryY)

        var perchProgress: Double?
        var perchDuration = 0.0
        if perchingEnabled && !reduceMotion && Double.random(in: 0..<1) < 0.4 {
            perchProgress = Double.random(in: 0.35...0.65)
            perchDuration = Double.random(in: 4...8)

            // A percher lingers mid-lane, so its own jitter draw matters more
            // than the group's shared height: re-draw a couple of candidates
            // and keep the clearest (the perch point is scored triple).
            if let field = avoidField {
                var bestPenalty = TextAvoidanceForce.lanePenalty(
                    entryY: entryY, exitYDrift: exitYDrift,
                    entryFromLeft: entryEdge == .left,
                    perchProgress: perchProgress,
                    in: viewSize, field: field)
                for _ in 0..<2 where bestPenalty > 0 {
                    let candY = min(max(baseEntryY + Double.random(in: -0.12...0.12), 0.08), 0.80)
                    let candDrift = min(max(Double.random(in: -0.25...0.25), 0.10 - candY), 0.82 - candY)
                    let candPerch = Double.random(in: 0.35...0.65)
                    let penalty = TextAvoidanceForce.lanePenalty(
                        entryY: candY, exitYDrift: candDrift,
                        entryFromLeft: entryEdge == .left,
                        perchProgress: candPerch,
                        in: viewSize, field: field)
                    if penalty < bestPenalty {
                        bestPenalty = penalty
                        entryY = candY
                        exitYDrift = candDrift
                        perchProgress = candPerch
                    }
                }
            }
        }

        return Butterfly(
            id: UUID(),
            spawnFrameTime: spawnFrameTime,
            entryEdge: entryEdge,
            entryY: entryY,
            exitYDrift: exitYDrift,
            crossingDuration: Double.random(in: 35...55) / speed,
            wanderFreqX: wanderFreq,
            wanderFreqY: wanderFreq * goldenRatio * Double.random(in: 0.9...1.1),
            wanderPhaseX: Double.random(in: 0...(2 * .pi)),
            wanderPhaseY: Double.random(in: 0...(2 * .pi)),
            wanderAmpX: Double.random(in: 0.03...0.06) * (reduceMotion ? 0.3 : 1.0),
            wanderAmpY: Double.random(in: 0.05...0.09) * (reduceMotion ? 0.3 : 1.0),
            flutterCycle: Double.random(in: 2.2...3.6) / speed,
            flapFraction: Double.random(in: 0.55...0.70),
            flapFrequency: Double.random(in: 4.5...6.5),
            flapPhase0: Double.random(in: 0...(2 * .pi)),
            liftAmplitude: Double.random(in: 10...16),
            perchProgress: perchProgress,
            perchDuration: perchDuration,
            size: CGFloat.random(in: 22...34),
            colorIndex: Int.random(in: 0...7),
            glideOnly: reduceMotion || !flutterEnabled
        )
    }
}
