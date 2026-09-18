// AquariumSimulation.swift
// rootshell
// Deterministic, bounded boids; no timers, framework dependencies, or per-fish objects.

import Foundation

struct AquariumFish: Sendable {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var heading: SIMD3<Float>
    var species: AquariumSpecies
    var phase: Float
    var seed: Float
    var scale: Float
}

struct AquariumSimulation: Sendable {
    private(set) var fish: [AquariumFish] = []
    private(set) var halfWidth: Float = 8
    private var random = AquariumRandom(seed: 0xA91A_2026)
    private var simulationTime: Double = 0

    mutating func configure(count: Int, halfWidth: Float) {
        let width = max(halfWidth.isFinite ? halfWidth : 8, 2.1)
        if abs(width - self.halfWidth) > 0.001 {
            let ratio = width / self.halfWidth
            for i in fish.indices { fish[i].position.x *= ratio }
            self.halfWidth = width
        }
        let target = min(max(count, 0), 64)
        if fish.count > target { fish.removeLast(fish.count - target) }
        while fish.count < target {
            // Stable species order keeps population changes from replacing existing animals.
            let species = AquariumSpecies(rawValue: fish.count % 5) ?? .clownfish
            let direction: Float = random.unit() < 0.5 ? -1 : 1
            let position = SIMD3(random.range(-width * 0.78, width * 0.78),
                                 random.range(-1.65, 3.05), random.range(-4.4, 1.35))
            let velocity = SIMD3(direction * species.cruisingSpeed, random.range(-0.03, 0.03), random.range(-0.1, 0.1))
            fish.append(AquariumFish(position: position, velocity: velocity, heading: aqNormalize(velocity),
                                     species: species, phase: random.range(0, 2 * .pi), seed: random.range(1, 1000),
                                     scale: species.scale * random.range(0.85, 1.15)))
        }
    }

    mutating func advance(delta: Double, current: Float) {
        guard delta.isFinite, delta > 0 else { return }
        // Bounded semi-fixed substeps: consistent behavior at 15, 30, and 60 Hz.
        let duration = Float(min(delta, 0.5))
        let steps = max(1, Int(ceil(duration / (1.0 / 60.0))))
        let dt = duration / Float(steps)
        for _ in 0..<steps { step(dt: dt, current: current.isFinite ? min(max(current, 0), 1) : 0.45) }
    }

    private mutating func step(dt: Float, current: Float) {
        simulationTime = (simulationTime + Double(dt)).truncatingRemainder(dividingBy: 512 * Double.pi)
        let previous = fish // COW snapshot makes updates independent of iteration order.
        for i in fish.indices {
            let f = previous[i]
            var separation = SIMD3<Float>.zero
            var alignment = SIMD3<Float>.zero
            var center = SIMD3<Float>.zero
            var neighbors: Float = 0
            for j in previous.indices where j != i {
                let other = previous[j]
                let offset = f.position - other.position
                let distanceSquared = aqDot(offset, offset)
                let separationDistance = (f.scale + other.scale) * 0.76
                if distanceSquared < separationDistance * separationDistance {
                    if distanceSquared > 0.0001 {
                        separation += offset / max(distanceSquared, 0.03)
                    } else {
                        // Deterministically unstick coincident spawn positions without NaNs.
                        separation.x += i < j ? -1 : 1
                    }
                }
                if other.species == f.species && distanceSquared < 8 {
                    alignment += other.velocity
                    center += other.position
                    neighbors += 1
                }
            }
            var acceleration = aqLimit(separation, 2.3) * 1.1
            if neighbors > 0 {
                acceleration += (alignment / neighbors - f.velocity) * 0.36
                acceleration += (center / neighbors - f.position) * 0.045
            }
            // Soft wall forces turn the whole fish; there is no modulo wrap or mirrored teleport.
            let xBound = max(halfWidth - f.scale * 1.55, 0.9)
            let margin: Float = 1.1
            func wall(_ value: Float, _ low: Float, _ high: Float) -> Float {
                let lower = max(0, (low + margin - value) / margin)
                let upper = max(0, (value - high + margin) / margin)
                return (lower * lower - upper * upper) * 1.9
            }
            acceleration += SIMD3(wall(f.position.x, -xBound, xBound),
                                  wall(f.position.y, -1.85, 3.2), wall(f.position.z, -4.7, 1.7))
            let t = Float(simulationTime)
            acceleration += SIMD3(sin(t * 0.25 + f.seed) * 0.10,
                                  sin(t * 0.4375 + f.seed * 1.73) * 0.09,
                                  cos(t * 0.3125 + f.seed) * 0.13)
            acceleration.x += sin(t * 0.21875 + f.position.z) * current * 0.035
            // A gentle depth preference leaves the front glass free of nose-on fish.
            acceleration.z -= f.velocity.z * 0.16
            var velocity = f.velocity + aqLimit(acceleration, 1.8) * dt
            let cruise = f.species.cruisingSpeed
            velocity = aqLimit(velocity, cruise * 1.6)
            if aqLength(velocity) < cruise * 0.65 { velocity = aqNormalize(velocity, fallback: f.heading) * cruise * 0.65 }
            var position = f.position + velocity * dt
            // Numerical safety cage. This normally never activates with the soft-wall margins.
            for axis in 0..<3 {
                let low: Float = axis == 0 ? -xBound : (axis == 1 ? -2.0 : -4.9)
                let high: Float = axis == 0 ? xBound : (axis == 1 ? 3.35 : 1.9)
                if position[axis] < low { position[axis] = low; velocity[axis] = abs(velocity[axis]) }
                if position[axis] > high { position[axis] = high; velocity[axis] = -abs(velocity[axis]) }
            }
            let heading = aqNormalize(f.heading + (aqNormalize(velocity) - f.heading) * (1 - exp(-dt * 4)))
            fish[i].position = position
            fish[i].velocity = velocity
            fish[i].heading = heading
            // Keep a small phase for stable vertex animation even after multi-day sessions.
            fish[i].phase = (f.phase + dt * (5.5 + aqLength(velocity) * 4.5)).truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    var instances: [AquariumInstance] {
        fish.map { f in
            AquariumInstance(model: .transform(position: f.position, forward: f.heading, scale: SIMD3(repeating: f.scale)),
                             parameters: SIMD4(Float(f.species.rawValue), f.seed, f.phase, aqLength(f.velocity)),
                             tint: SIMD4(1, 1, 1, 1))
        }
    }
}
