// WeatherSkyGeometry.swift
// rootshell
// World space is x east, y up, z south (right-handed); kilometres where a
// distance matters. Shared by the renderer and mirrored in Weather.metal.

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherSkyGeometry {
    static let cloudBase: Double = 1.4   // km, matches wxCloudBase

    /// Unit vector for a compass azimuth (degrees from north, clockwise) and altitude.
    static func direction(azimuth: Double, altitude: Double) -> SIMD3<Float> {
        let az = azimuth * .pi / 180, alt = altitude * .pi / 180
        return SIMD3(Float(sin(az) * cos(alt)), Float(sin(alt)), Float(-cos(az) * cos(alt)))
    }

    static func wrap180(_ degrees: Double) -> Double {
        var d = (degrees + 180).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d - 180
    }

    /// Faces the equator at night. By day it turns with the sun, keeping it
    /// within the middle of the frame, so sunrise and sunset stay in view even
    /// when the sun rises far to the north or south.
    static func cameraAzimuth(latitude: Double, sunAzimuth: Double, sunAltitude: Double, halfWidth: Double) -> Double {
        let facing: Double = latitude >= 0 ? 180 : 0
        let day = smoothstep(-12, -2, sunAltitude)
        let offset = wrap180(sunAzimuth - facing)
        let limit = halfWidth * 0.72
        let onScreen = max(-limit, min(limit, offset * 0.45))
        return facing + (offset - onScreen) * day
    }

    // MARK: Sidereal time and the celestial sphere

    static func greenwichSiderealDegrees(_ date: Date) -> Double {
        let d = date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
        let t = d / 36_525
        var g = 280.46061837 + 360.98564736629 * d + 0.000387933 * t * t - t * t * t / 38_710_000
        g = g.truncatingRemainder(dividingBy: 360)
        return g < 0 ? g + 360 : g
    }

    /// Rows mapping an equatorial unit vector (x toward RA 0, z toward the
    /// north celestial pole) into world space for an observer.
    static func equatorialRows(date: Date, latitude: Double, longitude: Double) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let lst = (greenwichSiderealDegrees(date) + longitude) * .pi / 180
        let phi = latitude * .pi / 180
        let sl = sin(lst), cl = cos(lst), sp = sin(phi), cp = cos(phi)
        return (SIMD3(Float(-sl), Float(cl), 0),
                SIMD3(Float(cp * cl), Float(cp * sl), Float(sp)),
                SIMD3(Float(sp * cl), Float(sp * sl), Float(-cp)))
    }

    static func equatorialVector(rightAscension: Double, declination: Double) -> SIMD3<Float> {
        let ra = rightAscension * .pi / 180, dec = declination * .pi / 180
        return SIMD3(Float(cos(dec) * cos(ra)), Float(cos(dec) * sin(ra)), Float(sin(dec)))
    }

    static func apply(_ rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(dot(rows.0, v), dot(rows.1, v), dot(rows.2, v))
    }

    static let galacticNorthPole = equatorialVector(rightAscension: 192.85948, declination: 27.12825)
    static let galacticCenter = equatorialVector(rightAscension: 266.40500, declination: -28.93617)

    // MARK: Light

    /// Sunlight transmittance through the atmosphere for an observer at
    /// `height` km. Mirrors wxTransmittance in Weather.metal.
    static func sunTransmittance(direction: SIMD3<Float>, height: Double) -> SIMD3<Float> {
        let earth = 6_360_000.0, top = 6_420_000.0
        let origin = SIMD3<Double>(0, earth + max(height, 0.02) * 1_000, 0)
        let d = SIMD3<Double>(Double(direction.x), Double(direction.y), Double(direction.z))
        func hit(_ radius: Double) -> (Double, Double)? {
            let b = (origin * d).sum(), c = (origin * origin).sum() - radius * radius
            let h = b * b - c
            guard h >= 0 else { return nil }
            return (-b - h.squareRoot(), -b + h.squareRoot())
        }
        if let ground = hit(earth), ground.0 > 0 { return .zero }
        guard let exit = hit(top)?.1, exit > 0 else { return SIMD3(repeating: 1) }
        let steps = 16, dt = exit / Double(steps)
        var depth = SIMD3<Double>.zero
        for i in 0..<steps {
            let p = origin + d * ((Double(i) + 0.5) * dt)
            let h = (p * p).sum().squareRoot() - earth
            let ozone = max(0, 1 - abs(h - 25_000) / 15_000)
            depth += (SIMD3(5.802e-6, 13.558e-6, 33.1e-6) * exp(-h / 8_000)
                      + SIMD3(repeating: 4.40e-6 * exp(-h / 1_200))
                      + SIMD3(0.650e-6, 1.881e-6, 0.085e-6) * ozone) * dt
        }
        return SIMD3(Float(exp(-depth.x)), Float(exp(-depth.y)), Float(exp(-depth.z)))
    }

    /// Exposure eases from night (moonlight and stars readable) to day.
    static func exposure(sunAltitude: Double) -> Float {
        let t = smoothstep(-14, 4, sunAltitude)
        return Float(exp2(log2(14.0) * (1 - t) + log2(1.5) * t))
    }

    static func starVisibility(sunAltitude: Double) -> Double {
        1 - smoothstep(-12, -4, sunAltitude)
    }

    // MARK: Preview times

    nonisolated enum PreviewTime: String, CaseIterable, Sendable {
        case sunrise, noon, sunset, night
    }

    /// The moment within a day of `around` matching a preview time, searched
    /// in ten-minute steps so it also works for cities across the date line.
    static func previewDate(_ preview: PreviewTime, around: Date, altitude: (Date) -> Double) -> Date {
        let samples = (0...144).map { around.addingTimeInterval(Double($0 - 72) * 600) }
        let altitudes = samples.map(altitude)
        switch preview {
        case .noon:
            return samples[altitudes.indices.max { altitudes[$0] < altitudes[$1] } ?? 72]
        case .night:
            return samples[altitudes.indices.min { altitudes[$0] < altitudes[$1] } ?? 72]
        case .sunrise, .sunset:
            let rising = preview == .sunrise
            let order = altitudes.indices.dropLast().sorted { abs($0 - 72) < abs($1 - 72) }
            for i in order {
                let a = altitudes[i], b = altitudes[i + 1]
                if rising ? (a < 3 && b >= 3) : (a >= 3 && b < 3) { return samples[rising ? i + 1 : i] }
            }
            return around
        }
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
}

/// A pitched perspective camera whose bottom edge sits a few degrees below
/// the horizon. The long screen axis always spans 100°.
nonisolated struct WeatherCamera: Equatable, Sendable {
    var forward: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var tanHalfWidth: Float
    var tanHalfHeight: Float

    /// Horizontal half field of view in degrees for a width/height ratio.
    static func halfWidthDegrees(aspect: Double) -> Double {
        atan(Double(tangents(aspect: aspect).width)) * 180 / .pi
    }

    private static func tangents(aspect: Double) -> (width: Float, height: Float) {
        let tanLong = tan(50 * Double.pi / 180)
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        return (Float(aspect >= 1 ? tanLong : tanLong * aspect), Float(aspect >= 1 ? tanLong / aspect : tanLong))
    }

    init(aspect: Double, azimuth: Double) {
        (tanHalfWidth, tanHalfHeight) = Self.tangents(aspect: aspect)
        let pitch = atan(Double(tanHalfHeight)) * 180 / .pi - 3
        forward = WeatherSkyGeometry.direction(azimuth: azimuth, altitude: pitch)
        let worldUp = SIMD3<Float>(0, 1, 0)
        right = Self.normalize(Self.cross(forward, worldUp))
        up = Self.cross(right, forward)
    }

    /// uv has its origin at the top left, as in the shaders.
    func ray(uv: SIMD2<Float>) -> SIMD3<Float> {
        let x = uv.x * 2 - 1, y = 1 - uv.y * 2
        return Self.normalize(forward + right * (x * tanHalfWidth) + up * (y * tanHalfHeight))
    }

    func project(_ direction: SIMD3<Float>) -> SIMD2<Float>? {
        let z = (direction * forward).sum()
        guard z > 0.01 else { return nil }
        let x = (direction * right).sum() / (z * tanHalfWidth)
        let y = (direction * up).sum() / (z * tanHalfHeight)
        return SIMD2((x + 1) * 0.5, (1 - y) * 0.5)
    }

    /// Screen motion of clouds at the base height near the middle of the
    /// frame when the cloud field drifts by `world` kilometres.
    func cloudShift(world: SIMD2<Float>) -> SIMD2<Float> {
        let center = ray(uv: SIMD2(0.5, 0.45))
        let height = Float(WeatherSkyGeometry.cloudBase + 0.4)
        let distance = height / max(center.y, 0.12)
        let delta = SIMD3<Float>(world.x, 0, world.y)
        let depth = distance * max((center * forward).sum(), 0.2)
        let horizontal = SIMD3<Float>(forward.x, 0, forward.z)
        let along = (delta * horizontal).sum() / max((horizontal * horizontal).sum().squareRoot(), 0.001)
        let dx = (delta * right).sum() / (depth * 2 * tanHalfWidth)
        // Receding clouds sink toward the horizon.
        let dy = along * height / (distance * distance + height * height) / (2 * tanHalfHeight)
        return SIMD2(dx, dy)
    }

    private static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    private static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = (v * v).sum().squareRoot()
        return length > 0.00001 ? v / length : SIMD3(0, 0, 1)
    }
}
#endif
