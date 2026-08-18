//
//  JellyfishVisitState.swift
//  rootshell
//
//  Model and visit lifecycle for the Jellyfish background effect.
//  Jellyfish occasionally drift across the lower part of the terminal,
//  pulsing their bells in a contract-and-coast swim rhythm with tentacles
//  trailing behind. The drift lane is a pure function of frame time (like
//  Butterfly); the only integrated per-frame state is the tentacle chains.
//  Between visits the effect is fully idle.
//

import SwiftUI
import UIKit
import Combine
import os.log

// MARK: - Entry Edge

/// Which screen edge a jellyfish enters from
enum JellyfishEntryEdge: Sendable {
    case left
    case right
}

// MARK: - Jellyfish Model

/// A single jellyfish in the water. Position, bell pose, and pulse are all
/// closed-form functions of frame time; the tentacle/oral-arm chains are the
/// one piece of simulated state, integrated by
/// `JellyfishVisitState.stepTentacles(frameTime:)`.
struct Jellyfish: Identifiable, Sendable {
    let id: UUID

    // Path across the screen
    let spawnFrameTime: TimeInterval    // Animation-clock time when this jelly starts (includes stagger)
    let entryEdge: JellyfishEntryEdge
    let entryY: Double                  // Entry height (fraction of view height)
    let exitYDrift: Double              // Height change over the crossing (fraction of view height)
    let sinksOut: Bool                  // Exits by sinking out the bottom instead of crossing fully
    let crossingDuration: Double        // Seconds to cross the screen (speed-adjusted at spawn)

    // Wander: incommensurate sines (golden-ratio frequency trick) at much
    // lower frequencies than the butterflies — an oceanic sway, not a flutter
    let wanderFreqX: Double             // Hz
    let wanderFreqY: Double             // Hz, ~freqX * golden ratio
    let wanderPhaseX: Double            // 0-2pi
    let wanderPhaseY: Double            // 0-2pi
    let wanderAmpX: Double              // Fraction of view width
    let wanderAmpY: Double              // Fraction of view height

    // Pulse-swim rhythm: the bell contracts quickly and relaxes slowly, and
    // the jelly lunges forward on the contraction then coasts back — the
    // pulse-coast coupling is what makes it read as swimming, not floating
    let pulsePeriod: Double             // Seconds per contract+relax cycle
    let pulsePhase0: Double             // 0-2pi
    let surgeAmplitude: Double          // Points of along-lane lunge per pulse

    // Anatomy (fixed at spawn)
    let bellRadius: CGFloat             // Points
    let tentacleCount: Int
    let tentacleNodesPer: Int
    let oralArmCount: Int
    let oralArmNodesPer: Int
    let tentacleAnchorX: [Double]       // Unit-space rim x per tentacle
    let oralArmAnchorX: [Double]        // Unit-space underside x per oral arm
    let colorIndex: Int                 // Per-jelly hue variation

    // Rare bioluminescent shimmer: pre-scheduled ripple start times so the
    // renderer stays a pure function of frame time
    let shimmerTimes: [TimeInterval]
    let shimmerDuration: Double

    // Calm drifting with a barely-perceptible breathe instead of the
    // contraction snap and lunge. Set under Reduce Motion.
    var calmDrift: Bool

    // MARK: Tentacle chains (per-frame simulation state)
    //
    // World-space node positions, flattened [chain * nodesPer + node].
    // Allocated once at spawn and mutated strictly in place afterwards.
    var tentacleNodes: [CGPoint]
    var oralArmNodes: [CGPoint]
    /// Animation-clock time of the most recent integration step (nil until
    /// first integrated frame — keeps staggered, not-yet-born jellies from
    /// taking a giant catch-up step on birth)
    var lastSimTime: TimeInterval? = nil

    // MARK: Avoidance (per-frame simulation state)
    //
    // Spring-damped displacement off the scripted lane, steering the bell
    // away from terminal text and from other bells. Integrated in
    // stepTentacles; the chains trail the displaced bell automatically via
    // bellTransform.
    var avoidOffset: CGVector = .zero
    var avoidVel: CGVector = .zero

    /// Portion of the pulse cycle spent contracting
    private static let contractFraction = 0.32
    /// Calm drift scales the bell deformation down to a gentle breathe
    private static let calmBreathe = 0.15

    // MARK: Pulse

    /// Bell contraction amount (0 = relaxed, 1 = fully contracted).
    /// Asymmetric: fast contraction, slow relaxation, C1-continuous.
    func pulseValue(at frameTime: TimeInterval) -> Double {
        let elapsed = frameTime - spawnFrameTime
        let u = positiveMod(elapsed / pulsePeriod + pulsePhase0 / (2 * .pi), 1.0)
        if u < Self.contractFraction {
            return Self.smootherstep(0, Self.contractFraction, u)
        }
        return 1 - Self.smootherstep(Self.contractFraction, 1, u)
    }

    /// Along-lane surge displacement (points): a quick forward lunge during
    /// the contraction, falling slowly back while coasting. Periodic and
    /// bounded, so the jelly never drifts off its lane. The small lag makes
    /// the thrust visibly follow the contraction.
    func surgeOffset(at frameTime: TimeInterval) -> Double {
        surgeAmplitude * (pulseValue(at: frameTime - 0.12 * pulsePeriod) - 0.5)
    }

    /// Bell deformation driven by the pulse: contraction narrows and
    /// elongates the dome. Splayed tentacles emerge from the rim anchors
    /// riding this transform.
    func bellSquash(at frameTime: TimeInterval) -> (x: Double, y: Double) {
        let p = pulseValue(at: frameTime) * (calmDrift ? Self.calmBreathe : 1.0)
        return (x: 1 - 0.22 * p, y: 1 + 0.15 * p)
    }

    // MARK: Progress

    /// Crossing progress (0 = entry edge, can exceed 1 for exit detection)
    func progress(at frameTime: TimeInterval) -> Double {
        (frameTime - spawnFrameTime) / crossingDuration
    }

    /// Whether the jellyfish has fully left the screen (crossed, or sunk out
    /// the bottom with its trailing tentacles)
    func isComplete(at frameTime: TimeInterval, in size: CGSize) -> Bool {
        if progress(at: frameTime) > 1.05 { return true }
        if sinksOut {
            let p = position(at: frameTime, in: size)
            return p.y > size.height + Double(bellRadius) * 8
        }
        return false
    }

    // MARK: Position

    func position(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        let elapsed = frameTime - spawnFrameTime
        let prog = elapsed / crossingDuration

        // Offscreen margin covers the bell plus the full trailing chain
        // length so neither entry nor exit ever pops
        let margin = wanderAmpX * size.width + Double(bellRadius) * 8
        let startX = entryEdge == .left ? -margin : size.width + margin
        let endX = entryEdge == .left ? size.width + margin : -margin

        let baseX = startX + (endX - startX) * prog
        let baseY = size.height * (entryY + exitYDrift * prog)

        let wx = wanderAmpX * size.width * sin(2 * .pi * wanderFreqX * elapsed + wanderPhaseX)
        let wy = wanderAmpY * size.height * sin(2 * .pi * wanderFreqY * elapsed + wanderPhaseY)

        // Pulse-coast surge projected along the lane direction
        let laneDX = endX - startX
        let laneDY = exitYDrift * size.height
        let laneLen = max((laneDX * laneDX + laneDY * laneDY).squareRoot(), 1)
        let surge = surgeOffset(at: frameTime)

        return CGPoint(x: baseX + wx + surge * laneDX / laneLen,
                       y: baseY + wy + surge * laneDY / laneLen)
    }

    /// Lane-only position: the crossing baseline without the wander and
    /// pulse-surge micro-motion (keep the base math in lockstep with
    /// `position(at:in:)`). The avoidance field is sampled here — sampled at
    /// the full scripted position, the surge/wander would pump a narrow text
    /// corridor's steep opposing gradients at pulse frequency and the
    /// offset spring would echo it as a wiggle instead of a lean.
    func lanePosition(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        let prog = (frameTime - spawnFrameTime) / crossingDuration
        let margin = wanderAmpX * size.width + Double(bellRadius) * 8
        let startX = entryEdge == .left ? -margin : size.width + margin
        let endX = entryEdge == .left ? size.width + margin : -margin
        return CGPoint(x: startX + (endX - startX) * prog,
                       y: size.height * (entryY + exitYDrift * prog))
    }

    /// Scripted position plus the text-avoidance displacement — the point
    /// everything visible hangs off (bell transform, culling)
    func renderPosition(at frameTime: TimeInterval, in size: CGSize) -> CGPoint {
        let p = position(at: frameTime, in: size)
        return CGPoint(x: p.x + avoidOffset.dx, y: p.y + avoidOffset.dy)
    }

    // MARK: Heading

    /// Scripted velocity (points/sec) via central finite difference of the
    /// smooth position function
    func scriptedVelocity(at frameTime: TimeInterval, in size: CGSize) -> CGVector {
        let dt = 0.08
        let p0 = position(at: frameTime - dt, in: size)
        let p1 = position(at: frameTime + dt, in: size)
        return CGVector(dx: (p1.x - p0.x) / (2 * dt), dy: (p1.y - p0.y) / (2 * dt))
    }

    /// Unit bell space → world: rim center at the origin, apex at (0,-1).
    /// Shared by the tentacle physics (anchor placement) and the renderer so
    /// the two can never drift apart.
    func bellTransform(at frameTime: TimeInterval, in size: CGSize) -> CGAffineTransform {
        let p = renderPosition(at: frameTime, in: size)
        let squash = bellSquash(at: frameTime)
        // Medusae swim bell-first: the apex points into the direction of
        // travel, with heavy vertical damping so the tilt stays gentle
        // through the slow wander. Blending in the avoidance velocity makes
        // an evading bell lean into its drift instead of side-slipping —
        // but capped to a fraction of the scripted speed, so it can only
        // tilt (~20° max), never swing through vertical: uncapped, an
        // avoidance push against the slow cruise dominated the atan2 and
        // visibly rotated the head sideways.
        let v = scriptedVelocity(at: frameTime, in: size)
        var ax = avoidVel.dx * 0.5
        var ay = avoidVel.dy * 0.5
        let speed = max((v.dx * v.dx + v.dy * v.dy).squareRoot(), 4)
        let alen = (ax * ax + ay * ay).squareRoot()
        let cap = 0.35 * speed
        if alen > cap {
            ax *= cap / alen
            ay *= cap / alen
        }
        let heading = atan2((v.dy + ay) * 0.35, v.dx + ax)
        return CGAffineTransform(translationX: p.x, y: p.y)
            .rotated(by: heading + .pi / 2)
            .scaledBy(x: bellRadius * squash.x, y: bellRadius * squash.y)
    }

    // MARK: Shimmer

    /// Active bioluminescent ripple, if any. `head` runs 0 (rim) → 1
    /// (tentacle tip); `strength` fades the highlight in and out.
    func shimmer(at frameTime: TimeInterval) -> (head: Double, strength: Double)? {
        for start in shimmerTimes {
            let t = frameTime - start
            if t >= 0, t < shimmerDuration {
                let head = t / shimmerDuration
                return (head, sin(.pi * head))
            }
        }
        return nil
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

/// Visit lifecycle manager (modeled on `ButterflyVisitState`): schedules
/// occasional visits, spawns one to a few jellies, prunes those that have
/// exited, and exposes `isIdle` to pause the render timeline entirely
/// between visits. Each `JellyfishView` owns its own instance, so the
/// settings preview's frequent visits never affect the live overlay.
@MainActor
final class JellyfishVisitState: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "Jellyfish")

    // MARK: Published State

    /// The active jellies. Deliberately NOT `@Published`: the only reader is
    /// the `Canvas` inside the `TimelineView`, which already redraws every
    /// frame from `timeline.date` while a visit is in progress. Publishing
    /// this would fire `objectWillChange` on every per-frame tentacle write
    /// in `stepTentacles`, causing redundant SwiftUI body invalidations on
    /// top of the timeline tick. `isIdle` (below) is the sole reactive
    /// signal needed. Mutated in place (no per-frame copy/allocation).
    private(set) var jellies: [Jellyfish] = []

    /// True when no jellies are on screen; drives the paused render timeline.
    @Published private(set) var isIdle = true

    // MARK: Visit Frequency

    enum VisitFrequency: String, Codable, CaseIterable {
        case frequent
        case occasional
        case rare

        var displayName: String {
            switch self {
            case .frequent: return String(localized: "Frequent", comment: "Jellyfish visit frequency: every 1-2 minutes")
            case .occasional: return String(localized: "Occasional", comment: "Jellyfish visit frequency: every 3-6 minutes")
            case .rare: return String(localized: "Rare", comment: "Jellyfish visit frequency: every 10-20 minutes")
            }
        }

        var intervalDescription: String {
            switch self {
            case .frequent: return String(localized: "About every 1–2 minutes", comment: "Caption for frequent jellyfish visits")
            case .occasional: return String(localized: "About every 3–6 minutes", comment: "Caption for occasional jellyfish visits")
            case .rare: return String(localized: "About every 10–20 minutes", comment: "Caption for rare jellyfish visits")
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

    private weak var effect: JellyfishEffect?
    private var previewMode = false
    private var hasStarted = false
    private var visitTask: Task<Void, Never>?
    private var configCancellable: AnyCancellable?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lastFrequency: VisitFrequency = .occasional
    private var lastTextAvoidanceEnabled = true

    /// Terminal-text tracker (nil in previews, which have no terminal behind
    /// them). Ticked from update(), so it costs nothing while idle.
    private var tracker: TextRegionTracker?
    /// Latched true while visits are paused on a mostly-full screen; the
    /// spawn gate then requires coverage below the resume threshold
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

    func start(effect: JellyfishEffect, previewMode: Bool) {
        guard !hasStarted else { return }
        hasStarted = true
        self.effect = effect
        self.previewMode = previewMode
        lastFrequency = effect.visitFrequency
        lastTextAvoidanceEnabled = effect.textAvoidanceEnabled

        // Previews have no terminal behind them, so they never construct a
        // tracker — the toggle is a no-op there by design
        if !previewMode {
            let tracker = TextRegionTracker()
            tracker.canvasFrameInGlobal = canvasFrameInGlobal
            self.tracker = tracker
        }

        // Re-arm the idle wait when the user changes visit frequency.
        // Shimmer and color changes need nothing here — both are read at
        // draw time, so they apply to jellies already in the water.
        configCancellable = effect.configurationDidChange.sink { [weak self] in
            guard let self, let effect = self.effect else { return }
            if effect.visitFrequency != self.lastFrequency {
                self.lastFrequency = effect.visitFrequency
                if self.isIdle { self.scheduleNextVisit() }
            }
            // Text Avoidance applies to jellies already in the water:
            // forces stop next frame and the home spring eases them back
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
                self.jellies = []
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
        jellies = []
        isIdle = true
        hasStarted = false
        tracker = nil
        coverageWaiting = false
    }

    /// Called once per rendered frame; integrates the tentacle chains,
    /// prunes exited jellies, and goes idle (pausing the timeline) when the
    /// visit is over. Runs only while jellies are present, so it adds zero
    /// cost between visits.
    func update(frameTime: TimeInterval) {
        guard !jellies.isEmpty else { return }
        if lastTextAvoidanceEnabled {
            tracker?.tick(now: frameTime)
        }
        stepTentacles(frameTime: frameTime)
        let size = viewSize
        jellies.removeAll { $0.isComplete(at: frameTime, in: size) }
        if jellies.isEmpty {
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

    // MARK: - Tentacle Physics

    /// Tunable constants for the tentacle-chain simulation. Kept together
    /// for easy on-device tuning.
    private enum ChainConstants {
        static let segLenFactor: Double = 0.50      // tentacle segment length ÷ bell radius
        static let armSegLenFactor: Double = 0.68   // oral arms are longer and lazier
        static let stiffness: Double = 12           // exponential follow rate (1/s)
        static let calmStiffness: Double = 30       // Reduce Motion: near-rigid trailing
        static let swayAmp: Double = 5              // pt/s lateral water-current sway
        static let swayFreq: Double = 0.22          // Hz
        static let sinkBias: Double = 6             // pt/s downward settle, growing toward the tip
        static let dtClamp: Double = 0.10           // max integration step (s)
    }

    /// Tunable constants for the avoidance spring (text + mutual separation)
    /// — deliberately languid next to the butterflies' steering: a jelly
    /// leans clear over seconds, it never darts. Critically damped (ζ≈1) so
    /// there is no overshoot.
    private enum AvoidConstants {
        // The text field is sampled open-loop at the lane position, so a
        // sustained push settles at strength × weight / kSpring exactly.
        static let kSpring: Double = 2.5          // lazy return to the scripted lane
        static let damping: Double = 3.2          // ζ = 3.2/(2·√2.5) ≈ 1.0
        static let bandRadius: Double = 90        // wide standoff onset — react early
        static let bandStrength: Double = 150     // ≈90pt settled deep inside a band (1.5×150/2.5)
        static let cursorStrength: Double = 275   // ≈110pt settled inside the core bubble, no dart
        static let cursorInfluence: Double = 2.5  // wider shell than butterflies for earlier onset
        // Mutual separation is closed-loop by nature (it reacts to actual
        // rendered proximity), so keep its gradient (2·strength·w/radius)
        // near kSpring — repulsion this gentle can't ring, only relax.
        static let sepFactor: Double = 2.0        // standoff onset ÷ summed bell radii
        static let sepStrength: Double = 450      // stacked bells settle ~70–100pt apart
        static let maxVel: Double = 70            // ~5× cruise speed cap on any transient
        static let maxOffset: Double = 120        // bells + tentacle mass need more clearance
    }

    /// Per-frame chain integration: distance-constrained follow-the-leader
    /// with frame-rate-independent lag, plus a gentle water-current sway.
    /// Tentacle splay on each pulse is emergent — the rim anchors ride the
    /// squashing bell transform and the lagging chain flares as they snap
    /// back. O(jellies × chains × nodes) over tiny counts, no allocations.
    private func stepTentacles(frameTime: TimeInterval) {
        typealias K = ChainConstants
        let size = viewSize
        guard size.width > 1, size.height > 1 else { return }

        for i in jellies.indices {
            guard frameTime >= jellies[i].spawnFrameTime else { continue }

            // Read scalars into locals; never copy the whole struct out —
            // that would retain the node arrays and force a COW copy of
            // them on every write below
            let bellRadius = Double(jellies[i].bellRadius)
            let calm = jellies[i].calmDrift
            let phase0 = jellies[i].pulsePhase0
            let seeding = jellies[i].lastSimTime == nil
            let dt = jellies[i].lastSimTime.map { max(0, min(frameTime - $0, K.dtClamp)) } ?? 0

            // Integrate the text-avoidance spring before reading the bell
            // transform so the chains anchor to the displaced bell this frame
            stepAvoidance(index: i, frameTime: frameTime, size: size, calm: calm, dt: dt)

            let transform = jellies[i].bellTransform(at: frameTime, in: size)
            let stiffness = calm ? K.calmStiffness : K.stiffness
            let swayScale = calm ? 0.25 : 1.0

            func stepChains(_ kp: WritableKeyPath<Jellyfish, [CGPoint]>,
                            anchors: [Double], anchorY: Double,
                            nodesPer: Int, segLen: Double) {
                for chain in anchors.indices {
                    var parent = CGPoint(x: anchors[chain], y: anchorY).applying(transform)
                    let chainPhase = phase0 + Double(chain) * 1.7
                    for k in 0..<nodesPer {
                        let idx = chain * nodesPer + k
                        if seeding {
                            // Born hanging straight below the anchor
                            let seeded = CGPoint(x: parent.x, y: parent.y + segLen)
                            jellies[i][keyPath: kp][idx] = seeded
                            parent = seeded
                            continue
                        }
                        var p = jellies[i][keyPath: kp][idx]
                        var dx = p.x - parent.x
                        var dy = p.y - parent.y
                        let len = (dx * dx + dy * dy).squareRoot()
                        if len < 0.001 {
                            dx = 0; dy = segLen
                        } else {
                            dx *= segLen / len; dy *= segLen / len
                        }
                        // Distance-constrained target, direction preserved
                        let follow = 1 - exp(-dt * stiffness)
                        p.x += (parent.x + dx - p.x) * follow
                        p.y += (parent.y + dy - p.y) * follow
                        // Water current + settle, phase-offset down the chain
                        p.x += K.swayAmp * sin(2 * .pi * K.swayFreq * frameTime + chainPhase + Double(k) * 0.8) * dt * swayScale
                        p.y += K.sinkBias * dt * Double(k) / Double(nodesPer)
                        jellies[i][keyPath: kp][idx] = p
                        parent = p
                    }
                }
            }

            stepChains(\.tentacleNodes,
                       anchors: jellies[i].tentacleAnchorX, anchorY: 0.02,
                       nodesPer: jellies[i].tentacleNodesPer,
                       segLen: bellRadius * K.segLenFactor)
            stepChains(\.oralArmNodes,
                       anchors: jellies[i].oralArmAnchorX, anchorY: 0.08,
                       nodesPer: jellies[i].oralArmNodesPer,
                       segLen: bellRadius * K.armSegLenFactor)

            jellies[i].lastSimTime = frameTime
        }
    }

    // MARK: - Text Avoidance

    /// Spring-damped drift off the scripted lane: soft push off text bands,
    /// firmer push out of the cursor bubble, mutual separation so slow bells
    /// never stack, home spring back to the lane. Same integrator shape as
    /// the butterflies' social layer, tuned languid. Writes only the
    /// CGVector scalars in place (COW-safe).
    private func stepAvoidance(index i: Int, frameTime: TimeInterval, size: CGSize, calm: Bool, dt: Double) {
        typealias A = AvoidConstants
        guard dt > 0 else { return }

        // Reduce Motion (calmDrift) keeps the whole layer inert — lane
        // selection already happened at spawn; bleed any residual offset
        // home instead of freezing the bell displaced.
        let motionScale: Double = calm ? 0
            : (ProcessInfo.processInfo.isLowPowerModeEnabled ? 0.6 : 1.0)
        guard motionScale > 0 else {
            let decay = exp(-dt / 0.4)
            jellies[i].avoidOffset.dx *= decay
            jellies[i].avoidOffset.dy *= decay
            jellies[i].avoidVel.dx *= decay
            jellies[i].avoidVel.dy *= decay
            return
        }

        // Fade all forces out near the end of the crossing so avoidance can
        // never hold a jelly back from exiting. When the text toggle flips
        // off or the field drops out mid-visit, the home spring below bleeds
        // any residual displacement back to the lane on its own.
        let exitTaper = 1 - Jellyfish.smootherstep(0.9, 1.05, jellies[i].progress(at: frameTime))

        var fx = -A.kSpring * jellies[i].avoidOffset.dx - A.damping * jellies[i].avoidVel.dx
        var fy = -A.kSpring * jellies[i].avoidOffset.dy - A.damping * jellies[i].avoidVel.dy

        // Mutual separation: independent of the text-avoidance toggle, and
        // measured between the displaced render positions — actual on-screen
        // proximity is what must never happen. Bells push apart along the
        // center line; the differing lane speeds that cause an overtake also
        // guarantee the pair drifts back out of range afterwards.
        if exitTaper > 0 {
            let pi = jellies[i].renderPosition(at: frameTime, in: size)
            for j in jellies.indices where j != i {
                guard frameTime >= jellies[j].spawnFrameTime else { continue }
                let pj = jellies[j].renderPosition(at: frameTime, in: size)
                var dx = pi.x - pj.x
                var dy = pi.y - pj.y
                var d = (dx * dx + dy * dy).squareRoot()
                if d < 0.5 {
                    // Degenerate overlap: deterministic tie-break direction
                    let h = Double(jellies[i].id.hashValue & 0xffff) / 65535.0 * 2 * .pi
                    dx = cos(h); dy = sin(h); d = 1
                }
                let sepRadius = A.sepFactor * Double(jellies[i].bellRadius + jellies[j].bellRadius)
                guard d < sepRadius else { continue }
                let w = 1 - d / sepRadius
                let push = A.sepStrength * w * w * motionScale * exitTaper
                fx += push * dx / d
                fy += push * dy / d
            }
        }

        let field: TextAvoidanceField? = {
            guard lastTextAvoidanceEnabled, let f = tracker?.field, f.isActive else { return nil }
            return f
        }()
        if let field, exitTaper > 0 {
            // Sampled at the LANE position: open-loop (never the displaced
            // renderPosition — the field's gradients would act as extra
            // stiffness the damping wasn't tuned for and the bell bounces),
            // and de-noised (the full scripted position carries wander +
            // pulse surge, which modulate a narrow corridor's opposing
            // gradients at pulse frequency into a visible wiggle).
            // Steady-state displacement is strength × weight / kSpring.
            let p = jellies[i].lanePosition(at: frameTime, in: size)
            let sample = TextAvoidanceForce.evaluate(
                at: p, field: field,
                bandRadius: A.bandRadius,
                cursorInfluenceScale: A.cursorInfluence,
                seed: jellies[i].id.hashValue)
            let fscale = motionScale * exitTaper
            // On a mostly-full screen the bands would shove from every side
            // at once; fall back to cursor-bubble-only
            if field.coverage <= TextRegionTracker.CoverageGate.suppress {
                fx += A.bandStrength * sample.bandFx * fscale
                fy += A.bandStrength * sample.bandFy * fscale
            }
            fx += A.cursorStrength * sample.cursorFx * fscale
            fy += A.cursorStrength * sample.cursorFy * fscale
        }

        // Semi-implicit Euler with velocity/offset caps
        var vx = jellies[i].avoidVel.dx + fx * dt
        var vy = jellies[i].avoidVel.dy + fy * dt
        let speed = (vx * vx + vy * vy).squareRoot()
        if speed > A.maxVel, speed > 0 {
            let k = A.maxVel / speed
            vx *= k
            vy *= k
        }
        var ox = jellies[i].avoidOffset.dx + vx * dt
        var oy = jellies[i].avoidOffset.dy + vy * dt
        let off = (ox * ox + oy * oy).squareRoot()
        if off > A.maxOffset, off > 0 {
            let k = A.maxOffset / off
            ox *= k
            oy *= k
            // Press against the cap instead of buzzing: drop outward velocity
            let nx = ox / A.maxOffset, ny = oy / A.maxOffset
            let vn = vx * nx + vy * ny
            if vn > 0 {
                vx -= nx * vn
                vy -= ny * vn
            }
        }
        jellies[i].avoidVel.dx = vx
        jellies[i].avoidVel.dy = vy
        jellies[i].avoidOffset.dx = ox
        jellies[i].avoidOffset.dy = oy
    }

    // MARK: Scheduling

    private func scheduleNextVisit(first: Bool = false) {
        visitTask?.cancel()
        guard let effect else { return }

        var interval: Double
        if previewMode {
            interval = first ? 0.3 : Double.random(in: 3...6)
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
        Self.logger.info("Next jellyfish visit in \(waitSeconds, format: .fixed(precision: 1))s")

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

        // Preview shows one jelly at a time: crossings are long, so stacking
        // scheduled spawns would crowd the little preview box
        if previewMode, !jellies.isEmpty {
            scheduleNextVisit()
            return
        }

        let now = frameTime(at: Date.now)

        // Text avoidance: refresh the field for lane selection, and defer the
        // visit while the screen is mostly full of text — a jelly would have
        // nowhere text-free to drift.
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
                    Self.logger.info("Jellyfish visit deferred: \(coveragePct)% text coverage, retry in \(retry, format: .fixed(precision: 0))s")
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
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let speed = min(max(effect.speed, 0.25), 2.0)

        // Usually one or two, occasionally a small bloom
        let roll = Double.random(in: 0..<1)
        var count = roll < 0.55 ? 1 : (roll < 0.90 ? 2 : 3)
        if effect.moreJellyfish { count += 1 }
        if lowPower || previewMode { count = 1 }

        // The group shares an entry edge; separated lanes plus long staggers
        // keep the slow drifters from overlapping for a whole crossing. The
        // shared height is drawn from the candidates that best clear the text.
        let entryEdge: JellyfishEntryEdge = Bool.random() ? .left : .right
        let baseEntryY = TextAvoidanceForce.pickEntryY(
            in: 0.40...0.70,
            entryFromLeft: entryEdge == .left,
            field: avoidField,
            viewSize: viewSize)
        let laneOffsets: [Double] = [0, -0.10, 0.12, -0.20]

        var newJellies: [Jellyfish] = []
        var takenLanes: [Double] = []
        for index in 0..<count {
            let stagger = index == 0 ? 0 : Double.random(in: 3.0...10.0)
            newJellies.append(makeJellyfish(
                spawnFrameTime: now + stagger,
                entryEdge: entryEdge,
                baseEntryY: baseEntryY + laneOffsets[index % laneOffsets.count],
                takenLanes: takenLanes,
                speed: speed,
                reduceMotion: reduceMotion,
                lowPower: lowPower,
                avoidField: avoidField
            ))
            takenLanes.append(newJellies[index].entryY)
        }

        jellies.append(contentsOf: newJellies)
        isIdle = false

        let spawnCount = newJellies.count
        Self.logger.info("Jellyfish visit: \(spawnCount) drifting in from \(entryEdge == .left ? "left" : "right")")
    }

    private func makeJellyfish(
        spawnFrameTime: TimeInterval,
        entryEdge: JellyfishEntryEdge,
        baseEntryY: Double,
        takenLanes: [Double] = [],
        speed: Double,
        reduceMotion: Bool,
        lowPower: Bool,
        avoidField: TextAvoidanceField? = nil
    ) -> Jellyfish {
        let goldenRatio = 1.618033988749895
        let wanderFreq = Double.random(in: 0.015...0.035) * speed

        // Bias lanes to the lower band — a jelly crossing near the top reads
        // as a balloon, not something underwater
        var entryY = min(max(baseEntryY + Double.random(in: -0.06...0.06), 0.30), 0.78)

        // Most jellies drift across; some sink out the bottom mid-crossing
        let sinksOut = !previewMode && Double.random(in: 0..<1) < 0.25
        var exitYDrift: Double
        if sinksOut {
            exitYDrift = Double.random(in: 0.5...0.8)
        } else {
            exitYDrift = min(max(Double.random(in: -0.15...0.15), 0.30 - entryY), 0.80 - entryY)
        }

        // Refine this member's own jitter draw against the text field and
        // against the lanes earlier members of this visit already claimed —
        // the fixed lane offsets can collide after the 0.30–0.78 clamp, and
        // text scoring alone would happily converge every member on the same
        // clear corridor. A sinker leaves the lane early, so only its first
        // 60% is text-scored.
        if avoidField != nil || !takenLanes.isEmpty {
            let tMax = sinksOut ? 0.6 : 1.0
            func penalty(entryY y: Double, exitYDrift drift: Double) -> Double {
                var p = 0.0
                if let field = avoidField {
                    p += TextAvoidanceForce.lanePenalty(
                        entryY: y, exitYDrift: drift,
                        entryFromLeft: entryEdge == .left,
                        tMax: tMax, in: viewSize, field: field)
                }
                // Comparable weight to a lane brushing text, zero beyond a
                // bell-diameter-ish gap (0.12 of height)
                for taken in takenLanes {
                    let w = max(0, 1 - abs(y - taken) / 0.12)
                    p += 2.5 * w * w
                }
                return p
            }
            var bestPenalty = penalty(entryY: entryY, exitYDrift: exitYDrift)
            for _ in 0..<3 where bestPenalty > 0 {
                let candY = min(max(baseEntryY + Double.random(in: -0.10...0.10), 0.30), 0.78)
                let candDrift = sinksOut
                    ? Double.random(in: 0.5...0.8)
                    : min(max(Double.random(in: -0.15...0.15), 0.30 - candY), 0.80 - candY)
                let candPenalty = penalty(entryY: candY, exitYDrift: candDrift)
                if candPenalty < bestPenalty {
                    bestPenalty = candPenalty
                    entryY = candY
                    exitYDrift = candDrift
                }
            }
        }

        let crossingDuration = (previewMode
            ? Double.random(in: 18...30)
            : Double.random(in: 45...120)) / speed
        let bellRadius = previewMode ? CGFloat.random(in: 14...20) : CGFloat.random(in: 26...44)

        let tentacleCount = Int.random(in: 6...10)
        let tentacleNodesPer = 7
        let oralArmCount = Int.random(in: 2...4)
        let oralArmNodesPer = 9

        // Rim anchors spread evenly with a little jitter; oral arms cluster
        // under the bell center
        var anchors: [Double] = []
        for i in 0..<tentacleCount {
            let t = Double(i) / Double(tentacleCount - 1)
            anchors.append(-0.85 + 1.70 * t + Double.random(in: -0.04...0.04))
        }
        var armAnchors: [Double] = []
        for i in 0..<oralArmCount {
            let t = oralArmCount == 1 ? 0.5 : Double(i) / Double(oralArmCount - 1)
            armAnchors.append((t - 0.5) * 0.35 + Double.random(in: -0.03...0.03))
        }

        // Pre-scheduled shimmer ripples (dark themes render them)
        var shimmerTimes: [TimeInterval] = []
        if !reduceMotion, !lowPower {
            for _ in 0..<Int.random(in: 0...2) {
                shimmerTimes.append(spawnFrameTime + crossingDuration * Double.random(in: 0.25...0.75))
            }
        }

        return Jellyfish(
            id: UUID(),
            spawnFrameTime: spawnFrameTime,
            entryEdge: entryEdge,
            entryY: entryY,
            exitYDrift: exitYDrift,
            sinksOut: sinksOut,
            crossingDuration: crossingDuration,
            wanderFreqX: wanderFreq,
            wanderFreqY: wanderFreq * goldenRatio * Double.random(in: 0.9...1.1),
            wanderPhaseX: Double.random(in: 0...(2 * .pi)),
            wanderPhaseY: Double.random(in: 0...(2 * .pi)),
            wanderAmpX: Double.random(in: 0.02...0.04) * (reduceMotion ? 0.3 : 1.0),
            wanderAmpY: Double.random(in: 0.03...0.06) * (reduceMotion ? 0.3 : 1.0),
            pulsePeriod: Double.random(in: 2.5...4.0) / speed,
            pulsePhase0: Double.random(in: 0...(2 * .pi)),
            surgeAmplitude: reduceMotion ? 0 : Double.random(in: 10...18),
            bellRadius: bellRadius,
            tentacleCount: tentacleCount,
            tentacleNodesPer: tentacleNodesPer,
            oralArmCount: oralArmCount,
            oralArmNodesPer: oralArmNodesPer,
            tentacleAnchorX: anchors,
            oralArmAnchorX: armAnchors,
            colorIndex: Int.random(in: 0...7),
            shimmerTimes: shimmerTimes,
            shimmerDuration: 1.6,
            calmDrift: reduceMotion,
            tentacleNodes: [CGPoint](repeating: .zero, count: tentacleCount * tentacleNodesPer),
            oralArmNodes: [CGPoint](repeating: .zero, count: oralArmCount * oralArmNodesPer)
        )
    }
}
