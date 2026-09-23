import Foundation

/// Pure, bounded visual state. Never receives a character, command, or input callback.
/// One tooth phase drives each bank's meshing gears and stitched transmission belt.
nonisolated enum TerminalTouchSteampunkMechanics {
    static let bankCount = 3
    static let phasePeriod = 48.0 // LCM of the 12-, 16-, and 24-tooth wheels.

    struct Bank: Sendable, Equatable {
        private(set) var phase = 0.0
        private(set) var speed = 0.0
        private(set) var pressure = 0.0

        var isMoving: Bool { speed > 0 || pressure > 0 }

        mutating func strike(_ strength: Double) {
            guard strength.isFinite, strength > 0 else { return }
            let strength = min(1.6, strength)
            speed = min(34, speed + 10 * strength)
            pressure = min(1, pressure + 0.34 * strength)
        }

        mutating func advance(seconds: Double, held: Double) {
            guard seconds.isFinite, seconds > 0 else { return }
            // A stalled frame must not fling the mechanism forward on resumption.
            let dt = min(seconds, 1.0 / 15.0)
            let load = held.isFinite ? min(2, max(0, held)) : 0
            let target = min(16, load * 9)
            let decay = exp(-4.8 * dt)
            // Analytic integration: the same motion at 30, 60, and 120 Hz.
            let distance = target * dt + (speed - target) * (1 - decay) / 4.8
            phase = (phase + max(0, distance)).truncatingRemainder(dividingBy: TerminalTouchSteampunkMechanics.phasePeriod)
            speed = target + (speed - target) * decay
            let pressureTarget = min(0.68, load * 0.32)
            pressure = pressureTarget + (pressure - pressureTarget) * exp(-6.5 * dt)
            if load == 0 {
                if speed < 0.025 { speed = 0 }
                if pressure < 0.003 { pressure = 0 }
            }
        }

        mutating func stop() { speed = 0; pressure = 0 }

        func angle(teeth: Int, reversed: Bool = false) -> Double {
            guard teeth > 0 else { return 0 }
            return phase * 2 * .pi / Double(teeth) * (reversed ? -1 : 1)
        }
    }

    struct Drive: Sendable {
        private(set) var banks = Array(repeating: Bank(), count: TerminalTouchSteampunkMechanics.bankCount)
        private(set) var lastTime: Double?
        var isMoving: Bool { banks.contains { $0.isMoving } }

        static func weights(at position: Double) -> [Double] {
            let x = position.isFinite ? min(1, max(0, position)) : 0.5
            // A neighbouring bank receives a small transmitted impulse, not a
            // full-screen flash. The closest bank always receives the strongest.
            return [0.17, 0.5, 0.83].map { center in
                max(0.08, 1 - abs(center - x) / 0.46)
            }
        }

        mutating func strike(at position: Double, strength: Double = 1) {
            for (index, weight) in Self.weights(at: position).enumerated() {
                banks[index].strike(strength * weight)
            }
        }

        mutating func advance(to time: Double, held: [Double]) {
            guard time.isFinite else { stop(); return }
            guard let previous = lastTime else { lastTime = time; return }
            lastTime = time
            guard time >= previous, time - previous < 0.5 else { stop(); return }
            for index in banks.indices {
                banks[index].advance(seconds: time - previous, held: held.indices.contains(index) ? held[index] : 0)
            }
        }

        mutating func rebaseClock() { lastTime = nil }
        mutating func stop() {
            for index in banks.indices { banks[index].stop() }
            lastTime = nil
        }
    }

    /// The porcelain/enamel face is deliberately separate from its brass rim.
    /// All illumination under a live UIKit legend preserves the contrast floor.
    struct RGB: Hashable, Sendable {
        let r: Double
        let g: Double
        let b: Double

        init(_ r: Double, _ g: Double, _ b: Double) {
            func clean(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
            self.r = clean(r); self.g = clean(g); self.b = clean(b)
        }
        static let black = Self(0, 0, 0)
        static let white = Self(1, 1, 1)
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(_ other: Self) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
        func mix(_ other: Self, _ fraction: Double) -> Self {
            let t = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return Self(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
        }
        func ink(preferred: Self, minimum: Double) -> Self {
            if contrast(preferred) >= minimum { return preferred }
            return contrast(.black) >= contrast(.white) ? .black : .white
        }
        func lit(toward light: Self, amount: Double, ink: Self, minimum: Double) -> Self {
            let amount = amount.isFinite ? min(1, max(0, amount)) : 0
            let side = luminance >= ink.luminance
            func valid(_ c: Self) -> Bool { c.contrast(ink) >= minimum && (c.luminance >= ink.luminance) == side }
            if valid(mix(light, amount)) { return mix(light, amount) }
            var low = 0.0, high = amount
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if valid(mix(light, mid)) { low = mid } else { high = mid }
            }
            return mix(light, low)
        }
        var cacheKey: String { [r, g, b].map { String($0.bitPattern, radix: 16) }.joined(separator: ":") }
    }
}
