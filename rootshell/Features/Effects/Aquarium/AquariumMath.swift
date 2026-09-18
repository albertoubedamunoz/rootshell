// AquariumMath.swift
// rootshell

import Foundation

// SIMD4-only GPU records keep Metal/Swift alignment explicit, including on simulator.
// The matching records live at the top of Aquarium.metal.
struct AquariumVertex: Sendable {
    var position: SIMD4<Float>  // xyz position; w material part (body, fin, eye, iris)
    var normal: SIMD4<Float>
    var uv: SIMD4<Float>        // xy surface coordinates; zw reserved
}

struct AquariumInstance: Sendable {
    var model: AquariumMatrix4
    var parameters: SIMD4<Float> // kind, seed, swim phase, movement/current strength
    var tint: SIMD4<Float>       // rgb tint, opacity
}

struct AquariumUniforms: Sendable {
    var viewProjection: AquariumMatrix4
    var lightProjection: AquariumMatrix4
    var cameraTime: SIMD4<Float>
    var lightDirection: SIMD4<Float> // xyz direction toward light; w intensity
    var lightColor: SIMD4<Float>
    var waterColor: SIMD4<Float>
    var fillColor: SIMD4<Float>
    var viewport: SIMD4<Float>       // width, height, inverse width, inverse height
    var optics: SIMD4<Float>         // caustics, haze, exposure stops, saturation
    var composition: SIMD4<Float>    // intensity, reading protection, light theme, bloom
    var environment: SIMD4<Float>    // half width, shadow texel size, current, reserved
}

struct AquariumMatrix4: Sendable {
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>
    static let identity = Self(c0: SIMD4(1, 0, 0, 0), c1: SIMD4(0, 1, 0, 0),
                               c2: SIMD4(0, 0, 1, 0), c3: SIMD4(0, 0, 0, 1))
    func applied(to v: SIMD4<Float>) -> SIMD4<Float> { c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w }
    static func * (a: Self, b: Self) -> Self {
        Self(c0: a.applied(to: b.c0), c1: a.applied(to: b.c1),
             c2: a.applied(to: b.c2), c3: a.applied(to: b.c3))
    }
    static func transform(position: SIMD3<Float>, forward: SIMD3<Float> = SIMD3(1, 0, 0),
                          scale: SIMD3<Float> = SIMD3(repeating: 1)) -> Self {
        let x = aqNormalize(forward)
        let z = aqNormalize(aqCross(x, SIMD3(0, 1, 0)), fallback: SIMD3(0, 0, 1))
        let y = aqCross(z, x)
        return Self(c0: aqV4(x * scale.x, 0), c1: aqV4(y * scale.y, 0),
                    c2: aqV4(z * scale.z, 0), c3: aqV4(position, 1))
    }
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> Self {
        let z = aqNormalize(eye - target)
        let x = aqNormalize(aqCross(SIMD3(0, 1, 0), z))
        let y = aqCross(z, x)
        return Self(c0: SIMD4(x.x, y.x, z.x, 0), c1: SIMD4(x.y, y.y, z.y, 0),
                    c2: SIMD4(x.z, y.z, z.z, 0),
                    c3: SIMD4(-aqDot(x, eye), -aqDot(y, eye), -aqDot(z, eye), 1))
    }
    /// Right-handed view space, Metal depth 0...1.
    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> Self {
        Self(c0: SIMD4(1 / halfWidth, 0, 0, 0), c1: SIMD4(0, 1 / halfHeight, 0, 0),
             c2: SIMD4(0, 0, 1 / (near - far), 0), c3: SIMD4(0, 0, near / (near - far), 1))
    }
}

func aqV3(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }
func aqV4(_ v: SIMD3<Float>, _ w: Float) -> SIMD4<Float> { SIMD4(v.x, v.y, v.z, w) }
func aqDot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
func aqCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
func aqLength(_ v: SIMD3<Float>) -> Float { sqrt(aqDot(v, v)) }
func aqNormalize(_ v: SIMD3<Float>, fallback: SIMD3<Float> = SIMD3(1, 0, 0)) -> SIMD3<Float> {
    let length = aqLength(v)
    return length > 0.00001 && length.isFinite ? v / length : fallback
}
func aqLimit(_ v: SIMD3<Float>, _ maximum: Float) -> SIMD3<Float> {
    let length = aqLength(v)
    return length > maximum ? v * (maximum / max(length, 0.00001)) : v
}

struct AquariumRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / 16_777_216 }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * unit() }
}

/// Accumulates a continuous phase; never derives position from time * current speed.
/// Long gaps are discarded, not replayed, so resume never teleports the animals.
struct AquariumClock {
    private(set) var time: Double = 0
    private var last: Double?
    mutating func suspend() { last = nil }
    mutating func advance(now: Double, speed: Double, paused: Bool) -> Double {
        guard now.isFinite else { last = nil; return 0 }
        guard !paused else { last = nil; return 0 }
        defer { last = now }
        guard let previous = last else { return 0 }
        let elapsed = now - previous
        guard elapsed >= 0, elapsed <= 0.25 else { return 0 }
        let delta = elapsed * AquariumConfiguration.finite(speed, 0...2, fallback: 1)
        time += delta
        return delta
    }
}
