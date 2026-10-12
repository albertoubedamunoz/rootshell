// LightningSchedule.swift
// rootshell

#if !CHINA_BUILD
import Foundation

nonisolated struct LightningStrike: Equatable, Sendable {
    let time: Double
    let seed: UInt64
    /// Screen position of the flash inside the cloud deck, uv 0...1.
    let position: Float
    let top: Float
    /// Cloud-to-ground strokes draw a channel; the rest only light the cloud.
    let showsBolt: Bool
}

/// GPU record for one bolt segment, mirrored by WXBoltSegment in Weather.metal.
nonisolated struct LightningSegment: Sendable {
    var ends: SIMD4<Float>   // start xy, end xy in uv
    var style: SIMD4<Float>  // width in pixels, brightness, reserved, reserved
}

/// Deterministic strikes from wall time. At most one strike per 8 s slot,
/// always in the slot's first 2 s, so strikes are at least 6 s apart and each
/// flash stays one envelope: well inside the WCAG three-flashes limit.
nonisolated enum LightningSchedule {
    static let slot: Double = 8
    static let window: Double = 2
    static let flashDuration: Double = 1.1

    static func strike(inSlot index: Int64, rate: Double) -> LightningStrike? {
        guard rate > 0 else { return nil }
        var random = WeatherRandom(seed: UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15 ^ 0x5717_E5)
        guard random.unit() < min(rate, 1) * 0.35 else { return nil }
        let time = Double(index) * slot + random.unit() * window
        return LightningStrike(time: time, seed: random.next(), position: Float(0.12 + random.unit() * 0.76),
                               top: Float(0.24 + random.unit() * 0.18), showsBolt: random.unit() < 0.55)
    }

    /// The strike whose flash may still be visible at `time`.
    static func activeStrike(at time: Double, rate: Double) -> LightningStrike? {
        let index = Int64((time / slot).rounded(.down))
        for candidate in [index, index - 1] {
            if let strike = strike(inSlot: candidate, rate: rate),
               time >= strike.time, time - strike.time < flashDuration { return strike }
        }
        return nil
    }

    /// 0...1. A fast rise, a decay, and two or three shallow return-stroke
    /// flickers that never drop below half, so it reads as a single flash.
    static func flash(at time: Double, strike: LightningStrike) -> Double {
        let t = time - strike.time
        guard t >= 0, t < flashDuration else { return 0 }
        let rise = min(t / 0.03, 1)
        let decay = exp(-max(t - 0.03, 0) / 0.28)
        let strokes = 2 + Int(strike.seed % 2)
        var flicker = 1.0
        for i in 1..<strokes {
            let at = 0.07 * Double(i) + Double((strike.seed >> (8 * UInt64(i))) & 0xF) / 600
            flicker += 0.45 * exp(-pow((t - at) / 0.025, 2))
        }
        // Fade the tail to exactly zero so the cut-off never pops.
        let tail = max(0, min(1, (flashDuration - t) / 0.3))
        return min(rise * decay * flicker / 1.45, 1) * tail * tail * (3 - 2 * tail)
    }

    /// A branching channel by midpoint displacement, top to bottom in uv.
    /// `segments` keeps its capacity; nothing is allocated after the first strike.
    static func buildBolt(seed: UInt64, top: SIMD2<Float>, bottomY: Float, into segments: inout [LightningSegment]) {
        segments.removeAll(keepingCapacity: true)
        var random = WeatherRandom(seed: seed)
        let bottom = SIMD2<Float>(top.x + Float(random.unit() - 0.5) * 0.18, bottomY)
        appendChannel(from: top, to: bottom, depth: 5, width: 2.2, brightness: 1, random: &random, into: &segments)
        let main = segments.count
        let branches = 1 + Int(random.next() % 2)
        for _ in 0..<branches where main > 4 {
            let origin = segments[Int(random.next() % UInt64(main * 2 / 3))].ends
            let start = SIMD2(origin.z, origin.w)
            let side: Float = random.unit() < 0.5 ? -1 : 1
            let length = Float(0.12 + random.unit() * 0.18) * (bottomY - top.y)
            let end = start + SIMD2(side * length * 0.6, length)
            appendChannel(from: start, to: end, depth: 4, width: 1.2, brightness: 0.55, random: &random, into: &segments)
        }
    }

    private static func appendChannel(from a: SIMD2<Float>, to b: SIMD2<Float>, depth: Int, width: Float,
                                      brightness: Float, random: inout WeatherRandom, into segments: inout [LightningSegment]) {
        guard depth > 0 else {
            segments.append(LightningSegment(ends: SIMD4(a.x, a.y, b.x, b.y), style: SIMD4(width, brightness, 0, 0)))
            return
        }
        let d = b - a
        let length = (d.x * d.x + d.y * d.y).squareRoot()
        let normal = length > 0 ? SIMD2(-d.y, d.x) / length : SIMD2<Float>(1, 0)
        let mid = (a + b) * 0.5 + normal * Float(random.unit() - 0.5) * length * 0.32
        appendChannel(from: a, to: mid, depth: depth - 1, width: width, brightness: brightness, random: &random, into: &segments)
        appendChannel(from: mid, to: b, depth: depth - 1, width: width * 0.94, brightness: brightness, random: &random, into: &segments)
    }
}

/// SplitMix64.
nonisolated struct WeatherRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
}
#endif
