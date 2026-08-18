//
//  MoonCalculator.swift
//  rootshell
//
//  Pure Swift implementation of lunar ephemeris algorithms
//  for calculating moon position, phase, and illumination.
//
//  Based on Jean Meeus' "Astronomical Algorithms" (2nd Edition)
//

import Foundation

// MARK: - Data Models

/// Moon position in the sky
struct MoonPosition {
    let altitude: Double       // Degrees above horizon (-90 to 90)
    let azimuth: Double        // Degrees from north (0-360)
    let parallacticAngle: Double  // For proper phase shadow orientation
}

/// Moon phase information
struct MoonPhaseInfo {
    let phase: MoonPhase       // Named phase
    let illumination: Double   // 0.0 to 1.0
    let phaseAngle: Double     // 0-360 degrees through cycle
    let positionAngle: Double  // Angle of bright limb from north
}

/// Named moon phases
enum MoonPhase: String, CaseIterable {
    case newMoon = "New Moon"
    case waxingCrescent = "Waxing Crescent"
    case firstQuarter = "First Quarter"
    case waxingGibbous = "Waxing Gibbous"
    case fullMoon = "Full Moon"
    case waningGibbous = "Waning Gibbous"
    case lastQuarter = "Last Quarter"
    case waningCrescent = "Waning Crescent"

    /// Localized display name for UI
    var displayName: String {
        switch self {
        case .newMoon: return String(localized: "New Moon", comment: "Moon phase: new moon")
        case .waxingCrescent: return String(localized: "Waxing Crescent", comment: "Moon phase: waxing crescent")
        case .firstQuarter: return String(localized: "First Quarter", comment: "Moon phase: first quarter")
        case .waxingGibbous: return String(localized: "Waxing Gibbous", comment: "Moon phase: waxing gibbous")
        case .fullMoon: return String(localized: "Full Moon", comment: "Moon phase: full moon")
        case .waningGibbous: return String(localized: "Waning Gibbous", comment: "Moon phase: waning gibbous")
        case .lastQuarter: return String(localized: "Last Quarter", comment: "Moon phase: last quarter")
        case .waningCrescent: return String(localized: "Waning Crescent", comment: "Moon phase: waning crescent")
        }
    }

    /// Initialize from phase angle (0-360 degrees through lunar cycle)
    init(phaseAngle: Double) {
        let normalized = phaseAngle.truncatingRemainder(dividingBy: 360.0)
        let angle = normalized < 0 ? normalized + 360 : normalized

        switch angle {
        case 0..<22.5:
            self = .newMoon
        case 22.5..<67.5:
            self = .waxingCrescent
        case 67.5..<112.5:
            self = .firstQuarter
        case 112.5..<157.5:
            self = .waxingGibbous
        case 157.5..<202.5:
            self = .fullMoon
        case 202.5..<247.5:
            self = .waningGibbous
        case 247.5..<292.5:
            self = .lastQuarter
        case 292.5..<337.5:
            self = .waningCrescent
        default:
            self = .newMoon
        }
    }
}

/// Complete lunar data for rendering
struct MoonData {
    let position: MoonPosition
    let phaseInfo: MoonPhaseInfo
    let isAboveHorizon: Bool
}

// MARK: - Moon Calculator

/// Lunar ephemeris calculator using Meeus algorithms
enum MoonCalculator {

    // MARK: - Constants

    /// Synodic month (new moon to new moon) in days
    static let synodicMonth: Double = 29.530588853

    /// Known new moon reference: January 6, 2000 18:14 UTC
    private static let referenceNewMoon: Double = 947182440.0  // Unix timestamp

    // MARK: - Public API

    /// Calculate complete moon data for rendering
    static func calculateMoonData(
        date: Date,
        latitude: Double,
        longitude: Double,
        timezone: TimeZone = .current
    ) -> MoonData {
        let position = calculatePosition(
            date: date,
            latitude: latitude,
            longitude: longitude,
            timezone: timezone
        )

        let phaseInfo = calculatePhase(date: date)

        return MoonData(
            position: position,
            phaseInfo: phaseInfo,
            isAboveHorizon: position.altitude > -0.833  // Account for refraction
        )
    }

    /// Calculate moon phase information
    static func calculatePhase(date: Date) -> MoonPhaseInfo {
        // Days since known new moon
        let daysSinceRef = date.timeIntervalSince1970 - referenceNewMoon
        let daysSinceNewMoon = daysSinceRef / 86400.0

        // Phase angle: 0 = new moon, 180 = full moon
        let cyclePosition = daysSinceNewMoon.truncatingRemainder(dividingBy: synodicMonth)
        let normalizedCycle = cyclePosition < 0 ? cyclePosition + synodicMonth : cyclePosition
        let phaseAngle = (normalizedCycle / synodicMonth) * 360.0

        // Illumination: 0 at new moon, 1 at full moon
        // Uses cosine of elongation (phase angle converted to radians)
        let elongationRad = phaseAngle * .pi / 180.0
        let illumination = (1.0 - cos(elongationRad)) / 2.0

        // Position angle of bright limb (simplified)
        // This determines which side of the moon is illuminated
        let positionAngle = calculateBrightLimbAngle(phaseAngle: phaseAngle)

        let phase = MoonPhase(phaseAngle: phaseAngle)

        return MoonPhaseInfo(
            phase: phase,
            illumination: illumination,
            phaseAngle: phaseAngle,
            positionAngle: positionAngle
        )
    }

    /// Calculate current moon position in the sky
    static func calculatePosition(
        date: Date,
        latitude: Double,
        longitude: Double,
        timezone: TimeZone = .current
    ) -> MoonPosition {
        let jd = julianDay(from: date)
        let t = julianCentury(jd: jd)

        // Calculate moon's ecliptic coordinates
        let (moonLon, moonLat) = calculateEclipticCoordinates(t: t)

        // Convert ecliptic to equatorial coordinates
        let obliquity = meanObliquity(t: t)
        let (ra, dec) = eclipticToEquatorial(
            longitude: moonLon,
            latitude: moonLat,
            obliquity: obliquity
        )

        // Convert equatorial to horizontal (alt/az) coordinates
        let lst = localSiderealTime(jd: jd, longitude: longitude)
        let hourAngle = lst - ra

        let (altitude, azimuth) = equatorialToHorizontal(
            hourAngle: hourAngle,
            declination: dec,
            latitude: latitude
        )

        // Calculate parallactic angle for phase shadow orientation
        let parallacticAngle = calculateParallacticAngle(
            hourAngle: hourAngle,
            declination: dec,
            latitude: latitude
        )

        return MoonPosition(
            altitude: altitude,
            azimuth: azimuth,
            parallacticAngle: parallacticAngle
        )
    }

    // MARK: - Ecliptic Coordinates (Meeus Ch. 47)

    /// Calculate moon's ecliptic longitude and latitude
    private static func calculateEclipticCoordinates(t: Double) -> (longitude: Double, latitude: Double) {
        // Mean elements
        let Lp = normalizeAngle(218.3164477 + 481267.88123421 * t
                                - 0.0015786 * t * t + t * t * t / 538841.0
                                - t * t * t * t / 65194000.0)  // Mean longitude

        let D = normalizeAngle(297.8501921 + 445267.1114034 * t
                               - 0.0018819 * t * t + t * t * t / 545868.0
                               - t * t * t * t / 113065000.0)  // Mean elongation

        let M = normalizeAngle(357.5291092 + 35999.0502909 * t
                               - 0.0001536 * t * t + t * t * t / 24490000.0)  // Sun's mean anomaly

        let Mp = normalizeAngle(134.9633964 + 477198.8675055 * t
                                + 0.0087414 * t * t + t * t * t / 69699.0
                                - t * t * t * t / 14712000.0)  // Moon's mean anomaly

        let F = normalizeAngle(93.2720950 + 483202.0175233 * t
                               - 0.0036539 * t * t - t * t * t / 3526000.0
                               + t * t * t * t / 863310000.0)  // Moon's argument of latitude

        // Additional arguments
        let A1 = normalizeAngle(119.75 + 131.849 * t)
        let A2 = normalizeAngle(53.09 + 479264.290 * t)
        let A3 = normalizeAngle(313.45 + 481266.484 * t)

        // Eccentricity of Earth's orbit
        let E = 1.0 - 0.002516 * t - 0.0000074 * t * t

        // Sum of periodic terms for longitude (simplified - major terms only)
        var sumL: Double = 0
        var sumB: Double = 0

        // Longitude terms (largest 20 terms from Meeus Table 47.A)
        let lonTerms: [(d: Double, m: Double, mp: Double, f: Double, coef: Double, eExp: Int)] = [
            (0, 0, 1, 0, 6288774, 0),
            (2, 0, -1, 0, 1274027, 0),
            (2, 0, 0, 0, 658314, 0),
            (0, 0, 2, 0, 213618, 0),
            (0, 1, 0, 0, -185116, 1),
            (0, 0, 0, 2, -114332, 0),
            (2, 0, -2, 0, 58793, 0),
            (2, -1, -1, 0, 57066, 1),
            (2, 0, 1, 0, 53322, 0),
            (2, -1, 0, 0, 45758, 1),
            (0, 1, -1, 0, -40923, 1),
            (1, 0, 0, 0, -34720, 0),
            (0, 1, 1, 0, -30383, 1),
            (2, 0, 0, -2, 15327, 0),
            (0, 0, 1, 2, -12528, 0),
            (0, 0, 1, -2, 10980, 0),
            (4, 0, -1, 0, 10675, 0),
            (0, 0, 3, 0, 10034, 0),
            (4, 0, -2, 0, 8548, 0),
            (2, 1, -1, 0, -7888, 1)
        ]

        for term in lonTerms {
            let arg = term.d * D + term.m * M + term.mp * Mp + term.f * F
            let argRad = arg * .pi / 180.0
            var coef = term.coef
            if term.eExp == 1 { coef *= E }
            else if term.eExp == 2 { coef *= E * E }
            sumL += coef * sin(argRad)
        }

        // Latitude terms (largest 15 terms from Meeus Table 47.B)
        let latTerms: [(d: Double, m: Double, mp: Double, f: Double, coef: Double, eExp: Int)] = [
            (0, 0, 0, 1, 5128122, 0),
            (0, 0, 1, 1, 280602, 0),
            (0, 0, 1, -1, 277693, 0),
            (2, 0, 0, -1, 173237, 0),
            (2, 0, -1, 1, 55413, 0),
            (2, 0, -1, -1, 46271, 0),
            (2, 0, 0, 1, 32573, 0),
            (0, 0, 2, 1, 17198, 0),
            (2, 0, 1, -1, 9266, 0),
            (0, 0, 2, -1, 8822, 0),
            (2, -1, 0, -1, 8216, 1),
            (2, 0, -2, -1, 4324, 0),
            (2, 0, 1, 1, 4200, 0),
            (2, 1, 0, -1, -3359, 1),
            (2, -1, -1, 1, 2463, 1)
        ]

        for term in latTerms {
            let arg = term.d * D + term.m * M + term.mp * Mp + term.f * F
            let argRad = arg * .pi / 180.0
            var coef = term.coef
            if term.eExp == 1 { coef *= E }
            else if term.eExp == 2 { coef *= E * E }
            sumB += coef * sin(argRad)
        }

        // Additional corrections
        sumL += 3958 * sin(A1 * .pi / 180.0)
        sumL += 1962 * sin((Lp - F) * .pi / 180.0)
        sumL += 318 * sin(A2 * .pi / 180.0)

        sumB -= 2235 * sin(Lp * .pi / 180.0)
        sumB += 382 * sin(A3 * .pi / 180.0)
        sumB += 175 * sin((A1 - F) * .pi / 180.0)
        sumB += 175 * sin((A1 + F) * .pi / 180.0)
        sumB += 127 * sin((Lp - Mp) * .pi / 180.0)
        sumB -= 115 * sin((Lp + Mp) * .pi / 180.0)

        // Final coordinates
        let longitude = normalizeAngle(Lp + sumL / 1000000.0)
        let latitude = sumB / 1000000.0

        return (longitude, latitude)
    }

    // MARK: - Coordinate Transformations

    /// Convert ecliptic to equatorial coordinates
    private static func eclipticToEquatorial(
        longitude: Double,
        latitude: Double,
        obliquity: Double
    ) -> (ra: Double, dec: Double) {
        let lonRad = longitude * .pi / 180.0
        let latRad = latitude * .pi / 180.0
        let oblRad = obliquity * .pi / 180.0

        // Right ascension
        let sinRa = sin(lonRad) * cos(oblRad) - tan(latRad) * sin(oblRad)
        let cosRa = cos(lonRad)
        var ra = atan2(sinRa, cosRa) * 180.0 / .pi
        if ra < 0 { ra += 360.0 }

        // Declination
        let sinDec = sin(latRad) * cos(oblRad) + cos(latRad) * sin(oblRad) * sin(lonRad)
        let dec = asin(sinDec) * 180.0 / .pi

        return (ra, dec)
    }

    /// Convert equatorial to horizontal coordinates
    private static func equatorialToHorizontal(
        hourAngle: Double,
        declination: Double,
        latitude: Double
    ) -> (altitude: Double, azimuth: Double) {
        let haRad = hourAngle * .pi / 180.0
        let decRad = declination * .pi / 180.0
        let latRad = latitude * .pi / 180.0

        // Altitude
        let sinAlt = sin(decRad) * sin(latRad) + cos(decRad) * cos(latRad) * cos(haRad)
        let altitude = asin(sinAlt) * 180.0 / .pi

        // Azimuth
        let cosAz = (sin(decRad) - sin(altitude * .pi / 180.0) * sin(latRad)) /
                    (cos(altitude * .pi / 180.0) * cos(latRad))
        var azimuth = acos(max(-1, min(1, cosAz))) * 180.0 / .pi

        if sin(haRad) > 0 {
            azimuth = 360.0 - azimuth
        }

        return (altitude, azimuth)
    }

    /// Calculate parallactic angle
    private static func calculateParallacticAngle(
        hourAngle: Double,
        declination: Double,
        latitude: Double
    ) -> Double {
        let haRad = hourAngle * .pi / 180.0
        let decRad = declination * .pi / 180.0
        let latRad = latitude * .pi / 180.0

        let y = sin(haRad)
        let x = tan(latRad) * cos(decRad) - sin(decRad) * cos(haRad)

        return atan2(y, x) * 180.0 / .pi
    }

    /// Calculate bright limb position angle
    private static func calculateBrightLimbAngle(phaseAngle: Double) -> Double {
        // Simplified: bright limb faces the sun
        // At new moon (0): sun is "behind" moon, angle = 180
        // At full moon (180): sun is in front, angle = 0
        // Waxing (0-180): bright limb on right, angle near 90
        // Waning (180-360): bright limb on left, angle near 270

        if phaseAngle < 180 {
            return 90.0  // Waxing: bright on right
        } else {
            return 270.0  // Waning: bright on left
        }
    }

    // MARK: - Time Calculations

    /// Julian day from Date
    private static func julianDay(from date: Date) -> Double {
        // Unix epoch (Jan 1, 1970) in Julian days
        let unixEpochJD = 2440587.5
        let daysSinceUnix = date.timeIntervalSince1970 / 86400.0
        return unixEpochJD + daysSinceUnix
    }

    /// Julian century from J2000.0
    private static func julianCentury(jd: Double) -> Double {
        (jd - 2451545.0) / 36525.0
    }

    /// Local sidereal time in degrees
    private static func localSiderealTime(jd: Double, longitude: Double) -> Double {
        let t = julianCentury(jd: jd)

        // Greenwich mean sidereal time at 0h UT
        var gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
                   + 0.000387933 * t * t - t * t * t / 38710000.0

        gmst = normalizeAngle(gmst)

        // Add longitude for local sidereal time
        return normalizeAngle(gmst + longitude)
    }

    /// Mean obliquity of the ecliptic
    private static func meanObliquity(t: Double) -> Double {
        23.439291 - 0.0130042 * t - 0.00000016 * t * t + 0.000000504 * t * t * t
    }

    // MARK: - Utility Functions

    /// Normalize angle to 0-360 range
    private static func normalizeAngle(_ angle: Double) -> Double {
        var result = angle.truncatingRemainder(dividingBy: 360.0)
        if result < 0 { result += 360.0 }
        return result
    }
}

// MARK: - Convenience Extensions

extension MoonCalculator {

    /// Get moon phase name for display
    static func phaseName(for date: Date) -> String {
        calculatePhase(date: date).phase.displayName
    }

    /// Get illumination percentage for display
    static func illuminationPercent(for date: Date) -> Int {
        Int(round(calculatePhase(date: date).illumination * 100))
    }

    /// Check if moon is currently above horizon
    static func isAboveHorizon(
        date: Date,
        latitude: Double,
        longitude: Double
    ) -> Bool {
        let position = calculatePosition(
            date: date,
            latitude: latitude,
            longitude: longitude
        )
        return position.altitude > -0.833
    }
}
