// AquariumSimulation.swift
// rootshell
// Deterministic species-specific swimming; no timers or per-fish objects.

import Foundation

extension AquariumSpecies {
    // Qualitative gait/behavior references and the limits of these artistic
    // scene-unit coefficients are documented in docs/aquarium-motion.md.
    var schooling: (radius: Float, alignment: Float, cohesion: Float) {
        switch self {
        case .neonTetra: return (6, 0.95, 0.24)
        case .blueTang: return (3, 0.22, 0.025)
        case .angelfish: return (2, 0.08, 0.015)
        case .clownfish, .butterflyfish: return (0, 0, 0)
        }
    }

    var turnRate: Float {
        switch self {
        case .clownfish: return 2.8
        case .blueTang: return 1.6
        case .butterflyfish: return 2.6
        case .angelfish: return 1.8
        case .neonTetra: return 4.2
        }
    }

    func activity(at time: Float, seed: Float) -> Float {
        // Smooth bouts instead of an identical enforced minimum speed. All
        // frequencies divide 256 so the simulation clock wraps continuously.
        switch self {
        case .clownfish: return 0.18 + 0.82 * pow(0.5 + 0.5 * sin(time * 0.75 + seed), 2)
        case .blueTang: return 0.88 + 0.12 * sin(time * 0.25 + seed)
        case .butterflyfish: return 0.25 + 0.75 * pow(0.5 + 0.5 * sin(time * 0.5 + seed), 2)
        case .angelfish: return 0.12 + 0.88 * pow(0.5 + 0.5 * sin(time * 0.3125 + seed), 2)
        case .neonTetra: return 0.55 + 0.75 * pow(0.5 + 0.5 * sin(time * 2 + seed), 4)
        }
    }

    func strokeRate(speed: Float, scale: Float) -> Float {
        // Radians/second. Small fish beat faster for a given scene speed;
        // pectoral swimmers keep sculling even when almost stationary.
        let bodyLengthsPerSecond = speed / max(2.5 * scale, 0.1)
        let base: Float
        switch self {
        case .clownfish: base = 7.5
        case .blueTang: base = 8.5
        case .butterflyfish: base = 6.5
        case .angelfish: base = 5.5
        case .neonTetra: base = 10
        }
        return base + bodyLengthsPerSecond * (self == .neonTetra ? 16 : 8)
    }
}

struct AquariumFish: Sendable {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var heading: SIMD3<Float>
    var species: AquariumSpecies
    var phase: Float
    var seed: Float
    var scale: Float
    var home: SIMD3<Float>
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
            for i in fish.indices {
                fish[i].position.x *= ratio
                fish[i].home.x *= ratio
            }
            self.halfWidth = width
        }
        let target = min(max(count, 0), 64)
        if fish.count > target { fish.removeLast(fish.count - target) }
        while fish.count < target {
            // Stable species order keeps population changes from replacing existing animals.
            let species = AquariumSpecies.allCases[fish.count % AquariumSpecies.allCases.count]
            let direction: Float = random.unit() < 0.5 ? -1 : 1
            var position = SIMD3(random.range(-width * 0.78, width * 0.78),
                                 random.range(-1.65, 3.05), random.range(-4.4, 1.35))
            // Start new tetras near their own shoal, with individual spacing.
            // Other species are not pulled into that school.
            if species == .neonTetra, let school = fish.first(where: { $0.species == .neonTetra }) {
                position = school.position + SIMD3(random.range(-0.7, 0.7),
                                                    random.range(-0.4, 0.4), random.range(-0.5, 0.5))
            }
            let velocity = SIMD3(direction * species.cruisingSpeed, random.range(-0.03, 0.03), random.range(-0.1, 0.1))
            let scale = species.scale * random.range(0.85, 1.15)
            let bound = max(width - scale * 1.55, 0.9)
            position.x = min(max(position.x, -bound), bound)
            position.y = min(max(position.y, -1.65), 3.05)
            position.z = min(max(position.z, -4.4), 1.35)
            fish.append(AquariumFish(position: position, velocity: velocity, heading: aqNormalize(velocity),
                                     species: species, phase: random.range(0, 2 * .pi), seed: random.range(1, 1000),
                                     scale: scale, home: position))
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
            let schooling = f.species.schooling
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
                if other.species == f.species && distanceSquared < schooling.radius * schooling.radius {
                    alignment += other.velocity
                    center += other.position
                    neighbors += 1
                }
            }
            var acceleration = aqLimit(separation, 2.3) * 1.1
            if neighbors > 0 {
                acceleration += (alignment / neighbors - f.velocity) * schooling.alignment
                acceleration += (center / neighbors - f.position) * schooling.cohesion
            }
            // Soft wall forces turn the whole fish; there is no modulo wrap or mirrored teleport.
            let xBound = max(halfWidth - f.scale * 1.55, 0.9)
            let margin: Float = 1.1
            func wall(_ value: Float, _ low: Float, _ high: Float) -> Float {
                let lower = max(0, (low + margin - value) / margin)
                let upper = max(0, (value - high + margin) / margin)
                return (lower * lower - upper * upper) * 1.9
            }
            let ahead = f.position + f.velocity * 0.7
            acceleration += SIMD3(wall(ahead.x, -xBound, xBound),
                                  wall(ahead.y, -1.85, 3.2), wall(ahead.z, -4.7, 1.7))
            let t = Float(simulationTime)
            let wander: Float = f.species == .neonTetra ? 0.045 : (f.species == .blueTang ? 0.07 : 0.10)
            acceleration += SIMD3(sin(t * 0.25 + f.seed) * wander,
                                  sin(t * 0.4375 + f.seed * 1.73) * wander * 0.45,
                                  cos(t * 0.3125 + f.seed) * wander)
            if f.species == .clownfish {
                // Site fidelity without inventing an anemone in the scene.
                let homeOffset = f.home - f.position
                acceleration += aqNormalize(homeOffset) * max(0, aqLength(homeOffset) - 0.65) * 0.32
            }
            acceleration.x += sin(t * 0.21875 + f.position.z) * current * 0.035
            // A gentle depth preference leaves the front glass free of nose-on fish.
            acceleration.z -= f.velocity.z * 0.16
            let cruise = f.species.cruisingSpeed
            let targetSpeed = cruise * f.species.activity(at: t, seed: f.seed)
            acceleration += f.heading * (targetSpeed - aqLength(f.velocity)) * 2.8
            var velocity = aqLimit(f.velocity + aqLimit(acceleration, 1.8) * dt, cruise * 1.6)
            let speed = aqLength(velocity)
            var desiredHeading = aqNormalize(velocity, fallback: f.heading)
            // Keep the tall fish upright: depth changes should not pitch them
            // into nose-first dives or flip their local up axis at vertical.
            let horizontal = sqrt(desiredHeading.x * desiredHeading.x + desiredHeading.z * desiredHeading.z)
            desiredHeading.y = min(max(desiredHeading.y, -horizontal * 0.55), horizontal * 0.55)
            let heading = aqTurn(f.heading, toward: aqNormalize(desiredHeading, fallback: f.heading),
                                 maximumAngle: f.species.turnRate * dt)
            velocity = heading * speed
            var position = f.position + velocity * dt
            // Numerical safety cage. This normally never activates with the soft-wall margins.
            for axis in 0..<3 {
                let low: Float = axis == 0 ? -xBound : (axis == 1 ? -2.0 : -4.9)
                let high: Float = axis == 0 ? xBound : (axis == 1 ? 3.35 : 1.9)
                if position[axis] < low { position[axis] = low; velocity[axis] = abs(velocity[axis]) }
                if position[axis] > high { position[axis] = high; velocity[axis] = -abs(velocity[axis]) }
            }
            fish[i].position = position
            fish[i].velocity = velocity
            fish[i].heading = aqNormalize(velocity, fallback: heading)
            // Keep a small phase for stable vertex animation even after multi-day sessions.
            fish[i].phase = (f.phase + dt * f.species.strokeRate(speed: speed, scale: f.scale))
                .truncatingRemainder(dividingBy: 2 * .pi)
        }
    }

    var instances: [AquariumInstance] {
        fish.map { f in
            AquariumInstance(model: .transform(position: f.position, forward: f.heading, scale: SIMD3(repeating: f.scale)),
                             parameters: SIMD4(Float(f.species.rawValue), f.seed, f.phase,
                                               aqLength(f.velocity) / f.species.cruisingSpeed),
                             tint: SIMD4(1, 1, 1, 1))
        }
    }
}
