// Jellyfish.swift
// rootshell
// Pure anatomy and closed-form swimming pose, shared by the simulation and renderers.

import Foundation
import CoreGraphics

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
    let tentacleAngles: [Double]        // Attachment azimuths around the three-dimensional margin
    let originalTentacleAnchorX: [Double] // Flat rim anchors; empty for enhanced anatomy
    let oralArmAnchorX: [Double]        // Unit-space underside x per oral arm
    let colorIndex: Int                 // Per-jelly hue variation
    let visualDepth: Double             // 0 = distant, 1 = near; stable for a whole visit

    var usesOriginalRendering: Bool { !originalTentacleAnchorX.isEmpty }

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
        (calmDrift ? 0 : surgeAmplitude) * (pulseValue(at: frameTime - 0.12 * pulsePeriod) - 0.5)
    }

    /// Bell deformation driven by the pulse: contraction narrows and
    /// elongates the dome. Splayed tentacles emerge from the rim anchors
    /// riding this transform.
    func bellSquash(at frameTime: TimeInterval) -> (x: Double, y: Double) {
        let p = pulseValue(at: frameTime) * (calmDrift ? Self.calmBreathe : 1.0)
        return (x: 1 - 0.22 * p, y: 1 + 0.15 * p)
    }

    func opticalTilt(at frameTime: TimeInterval) -> Double {
        0.34 + sin((frameTime - spawnFrameTime) * 0.14 + pulsePhase0) * (calmDrift ? 0.01 : 0.07)
    }

    /// Flat rim for Original, or the projected jfBell surface for Enhanced.
    /// Sharing attachments with physics keeps the tentacle roots connected.
    func tentacleAnchor(_ chain: Int, at frameTime: TimeInterval) -> CGPoint {
        if usesOriginalRendering {
            return CGPoint(x: originalTentacleAnchorX[chain], y: 0.02)
        }
        let phi = tentacleAngles[chain]
        let pulse = pulseValue(at: frameTime) * (calmDrift ? Self.calmBreathe : 1)
        let lobes = cos(phi * 16 + pulsePhase0)
        let radius = 1 + 0.024 * lobes - 0.035 * pulse
        let tilt = opticalTilt(at: frameTime)
        let y = (0.035 * lobes + 0.065 * pulse) * cos(tilt)
            + sin(phi) * radius * 0.72 * sin(tilt)
        return CGPoint(x: cos(phi) * radius, y: y)
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

    /// Unit bell space → world: rim center at the origin, apex at (0,-1).
    /// Shared by the tentacle physics (anchor placement) and the renderer so
    /// the two can never drift apart.
    func bellTransform(at frameTime: TimeInterval, in size: CGSize) -> CGAffineTransform {
        let p = renderPosition(at: frameTime, in: size)
        let squash = bellSquash(at: frameTime)
        let margin = wanderAmpX * size.width + Double(bellRadius) * 8
        let direction: Double = entryEdge == .left ? 1 : -1
        let v: CGVector
        if usesOriginalRendering {
            // Preserve the original bell-first swimming pose.
            let dt = 0.08
            let p0 = position(at: frameTime - dt, in: size)
            let p1 = position(at: frameTime + dt, in: size)
            v = CGVector(dx: (p1.x - p0.x) / (2 * dt), dy: (p1.y - p0.y) / (2 * dt))
        } else {
            // Enhanced bells lean into the steady current, avoiding rapid
            // turns when the instantaneous pulse/surge velocity reverses.
            v = CGVector(dx: direction * (size.width + 2 * margin) / crossingDuration,
                         dy: exitYDrift * size.height / crossingDuration)
        }
        var ax = avoidVel.dx * 0.5
        var ay = avoidVel.dy * 0.5
        let speed = max((v.dx * v.dx + v.dy * v.dy).squareRoot(), 4)
        let alen = (ax * ax + ay * ay).squareRoot()
        let cap = 0.35 * speed
        if alen > cap {
            ax *= cap / alen
            ay *= cap / alen
        }
        let elapsed = frameTime - spawnFrameTime
        let sway = sin(2 * .pi * wanderFreqX * elapsed + wanderPhaseX) * 0.055
            + sin(2 * .pi * wanderFreqY * elapsed + wanderPhaseY) * 0.025
        let lean = atan2(v.dx + ax, speed * 1.8 + abs(v.dy + ay) * 0.35) * 0.75
            + sway * (calmDrift ? 0.15 : 1)
        let rotation = usesOriginalRendering ? atan2((v.dy + ay) * 0.35, v.dx + ax) + .pi / 2 : lean
        return CGAffineTransform(translationX: p.x, y: p.y)
            .rotated(by: rotation)
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
