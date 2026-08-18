//
//  SolarCalculator.swift
//  rootshell
//
//  Pure Swift implementation of NOAA solar position algorithm
//  for calculating sunrise, sunset, and sun position.
//

import Foundation

// MARK: - Data Models

/// Solar times for a given day and location
struct SolarTimes {
    let sunrise: Date
    let sunset: Date
    let solarNoon: Date
    let civilDawn: Date      // Sun 6 degrees below horizon
    let civilDusk: Date      // Sun 6 degrees below horizon

    /// Day length in hours
    var dayLength: TimeInterval {
        sunset.timeIntervalSince(sunrise)
    }
}

/// Current sun position in the sky
struct SolarPosition {
    let altitude: Double   // Degrees above horizon (-90 to 90)
    let azimuth: Double    // Degrees from north (0-360)
}

/// Time phase based on sun altitude
enum SolarPhase: String, CaseIterable {
    case night              // altitude < -18
    case astronomicalTwilight  // -18 to -12
    case nauticalTwilight   // -12 to -6
    case civilTwilight      // -6 to 0
    case goldenHour         // 0 to 6
    case day                // > 6

    init(altitude: Double) {
        switch altitude {
        case ..<(-18):
            self = .night
        case -18..<(-12):
            self = .astronomicalTwilight
        case -12..<(-6):
            self = .nauticalTwilight
        case -6..<0:
            self = .civilTwilight
        case 0..<6:
            self = .goldenHour
        default:
            self = .day
        }
    }
}

// MARK: - Solar Calculator

/// NOAA Solar Calculator implementation
/// Based on: https://gml.noaa.gov/grad/solcalc/calcdetails.html
enum SolarCalculator {

    // MARK: - Public API

    /// Calculate solar times for a given date and location
    static func calculateTimes(
        date: Date,
        latitude: Double,
        longitude: Double,
        timezone: TimeZone = .current
    ) -> SolarTimes {
        let calendar = Calendar.current
        let components = calendar.dateComponents(in: timezone, from: date)

        // Get Julian Day at noon
        let jd = julianDay(
            year: components.year ?? 2024,
            month: components.month ?? 1,
            day: components.day ?? 1
        )

        let tzOffset = Double(timezone.secondsFromGMT(for: date)) / 3600.0

        // Calculate solar noon
        let solarNoonMinutes = solarNoonTime(jd: jd, longitude: longitude, timezone: tzOffset)
        let solarNoon = timeFromMinutes(solarNoonMinutes, on: date, timezone: timezone)

        // Calculate sunrise and sunset (altitude = -0.833 for refraction)
        let sunriseMinutes = sunriseTime(jd: jd, latitude: latitude, longitude: longitude, timezone: tzOffset)
        let sunsetMinutes = sunsetTime(jd: jd, latitude: latitude, longitude: longitude, timezone: tzOffset)

        let sunrise = timeFromMinutes(sunriseMinutes, on: date, timezone: timezone)
        let sunset = timeFromMinutes(sunsetMinutes, on: date, timezone: timezone)

        // Calculate civil twilight (altitude = -6 degrees)
        let civilDawnMinutes = sunriseTime(jd: jd, latitude: latitude, longitude: longitude, timezone: tzOffset, altitude: -6.0)
        let civilDuskMinutes = sunsetTime(jd: jd, latitude: latitude, longitude: longitude, timezone: tzOffset, altitude: -6.0)

        let civilDawn = timeFromMinutes(civilDawnMinutes, on: date, timezone: timezone)
        let civilDusk = timeFromMinutes(civilDuskMinutes, on: date, timezone: timezone)

        return SolarTimes(
            sunrise: sunrise,
            sunset: sunset,
            solarNoon: solarNoon,
            civilDawn: civilDawn,
            civilDusk: civilDusk
        )
    }

    /// Calculate current sun position
    static func calculatePosition(
        date: Date,
        latitude: Double,
        longitude: Double,
        timezone: TimeZone = .current
    ) -> SolarPosition {
        let calendar = Calendar.current
        let components = calendar.dateComponents(in: timezone, from: date)

        let jd = julianDay(
            year: components.year ?? 2024,
            month: components.month ?? 1,
            day: components.day ?? 1
        )

        // Get time as fraction of day
        let hour = Double(components.hour ?? 12)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)
        let timeMinutes = hour * 60.0 + minute + second / 60.0
        let tzOffset = Double(timezone.secondsFromGMT(for: date)) / 3600.0

        let t = julianCentury(jd: jd)

        // Solar calculations
        let eqTime = equationOfTime(t: t)
        let decl = sunDeclination(t: t)

        // True solar time
        let trueSolarTime = timeMinutes + eqTime + 4.0 * longitude - 60.0 * tzOffset

        // Hour angle
        var hourAngle = trueSolarTime / 4.0 - 180.0
        if hourAngle < -180 {
            hourAngle += 360
        }

        // Solar zenith and altitude
        let latRad = latitude * .pi / 180.0
        let declRad = decl * .pi / 180.0
        let haRad = hourAngle * .pi / 180.0

        let cosZenith = sin(latRad) * sin(declRad) + cos(latRad) * cos(declRad) * cos(haRad)
        let zenith = acos(cosZenith) * 180.0 / .pi
        let altitude = 90.0 - zenith

        // Solar azimuth
        var azimuth: Double
        if hourAngle > 0 {
            azimuth = (acos((sin(latRad) * cosZenith - sin(declRad)) / (cos(latRad) * sin(zenith * .pi / 180.0))) * 180.0 / .pi + 180.0).truncatingRemainder(dividingBy: 360.0)
        } else {
            azimuth = (540.0 - acos((sin(latRad) * cosZenith - sin(declRad)) / (cos(latRad) * sin(zenith * .pi / 180.0))) * 180.0 / .pi).truncatingRemainder(dividingBy: 360.0)
        }

        return SolarPosition(altitude: altitude, azimuth: azimuth)
    }

    /// Calculate day progress (0 = sunrise, 0.5 = solar noon, 1 = sunset)
    /// Returns value outside 0-1 for times before sunrise or after sunset
    static func dayProgress(date: Date, times: SolarTimes) -> Double {
        let now = date.timeIntervalSince1970
        let sunrise = times.sunrise.timeIntervalSince1970
        let sunset = times.sunset.timeIntervalSince1970

        if now < sunrise {
            // Before sunrise: negative progress
            let beforeDawn = times.civilDawn.timeIntervalSince1970
            return (now - sunrise) / (sunrise - beforeDawn) * 0.1
        } else if now > sunset {
            // After sunset: progress > 1
            let afterDusk = times.civilDusk.timeIntervalSince1970
            return 1.0 + (now - sunset) / (afterDusk - sunset) * 0.1
        } else {
            // During day: 0 to 1
            return (now - sunrise) / (sunset - sunrise)
        }
    }

    /// Clamp day progress to 0-1 range (for arc position)
    static func clampedDayProgress(date: Date, times: SolarTimes) -> Double {
        let progress = dayProgress(date: date, times: times)
        return min(max(progress, 0.0), 1.0)
    }

    /// Determine current solar phase
    static func currentPhase(altitude: Double) -> SolarPhase {
        SolarPhase(altitude: altitude)
    }

    // MARK: - Private Calculations

    /// Calculate Julian Day number
    private static func julianDay(year: Int, month: Int, day: Int) -> Double {
        var y = year
        var m = month

        if m <= 2 {
            y -= 1
            m += 12
        }

        let a = Int(Double(y) / 100.0)
        let b = 2 - a + Int(Double(a) / 4.0)

        return Double(Int(365.25 * Double(y + 4716))) +
               Double(Int(30.6001 * Double(m + 1))) +
               Double(day) + Double(b) - 1524.5
    }

    /// Julian century from Julian Day
    private static func julianCentury(jd: Double) -> Double {
        (jd - 2451545.0) / 36525.0
    }

    /// Geometric mean longitude of sun (degrees)
    private static func geomMeanLongSun(t: Double) -> Double {
        var l0 = 280.46646 + t * (36000.76983 + 0.0003032 * t)
        while l0 > 360.0 { l0 -= 360.0 }
        while l0 < 0.0 { l0 += 360.0 }
        return l0
    }

    /// Geometric mean anomaly of sun (degrees)
    private static func geomMeanAnomalySun(t: Double) -> Double {
        357.52911 + t * (35999.05029 - 0.0001537 * t)
    }

    /// Eccentricity of Earth's orbit
    private static func eccentricityEarthOrbit(t: Double) -> Double {
        0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    }

    /// Sun equation of center (degrees)
    private static func sunEqOfCenter(t: Double) -> Double {
        let m = geomMeanAnomalySun(t: t)
        let mrad = m * .pi / 180.0
        let sinm = sin(mrad)
        let sin2m = sin(2.0 * mrad)
        let sin3m = sin(3.0 * mrad)
        return sinm * (1.914602 - t * (0.004817 + 0.000014 * t)) +
               sin2m * (0.019993 - 0.000101 * t) +
               sin3m * 0.000289
    }

    /// Sun true longitude (degrees)
    private static func sunTrueLong(t: Double) -> Double {
        geomMeanLongSun(t: t) + sunEqOfCenter(t: t)
    }

    /// Sun apparent longitude (degrees)
    private static func sunApparentLong(t: Double) -> Double {
        let o = sunTrueLong(t: t)
        let omega = 125.04 - 1934.136 * t
        return o - 0.00569 - 0.00478 * sin(omega * .pi / 180.0)
    }

    /// Mean obliquity of ecliptic (degrees)
    private static func meanObliquityOfEcliptic(t: Double) -> Double {
        let seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
        return 23.0 + (26.0 + seconds / 60.0) / 60.0
    }

    /// Corrected obliquity (degrees)
    private static func obliquityCorrection(t: Double) -> Double {
        let e0 = meanObliquityOfEcliptic(t: t)
        let omega = 125.04 - 1934.136 * t
        return e0 + 0.00256 * cos(omega * .pi / 180.0)
    }

    /// Sun declination (degrees)
    private static func sunDeclination(t: Double) -> Double {
        let e = obliquityCorrection(t: t)
        let lambda = sunApparentLong(t: t)
        let sint = sin(e * .pi / 180.0) * sin(lambda * .pi / 180.0)
        return asin(sint) * 180.0 / .pi
    }

    /// Equation of time (minutes)
    private static func equationOfTime(t: Double) -> Double {
        let e = obliquityCorrection(t: t)
        let l0 = geomMeanLongSun(t: t)
        let ecc = eccentricityEarthOrbit(t: t)
        let m = geomMeanAnomalySun(t: t)

        var y = tan((e / 2.0) * .pi / 180.0)
        y *= y

        let sin2l0 = sin(2.0 * l0 * .pi / 180.0)
        let sinm = sin(m * .pi / 180.0)
        let cos2l0 = cos(2.0 * l0 * .pi / 180.0)
        let sin4l0 = sin(4.0 * l0 * .pi / 180.0)
        let sin2m = sin(2.0 * m * .pi / 180.0)

        let etime = y * sin2l0 - 2.0 * ecc * sinm + 4.0 * ecc * y * sinm * cos2l0 -
                    0.5 * y * y * sin4l0 - 1.25 * ecc * ecc * sin2m
        return etime * 180.0 / .pi * 4.0
    }

    /// Hour angle for sunrise/sunset at given altitude
    private static func hourAngleSunrise(lat: Double, decl: Double, altitude: Double = -0.833) -> Double {
        let latRad = lat * .pi / 180.0
        let declRad = decl * .pi / 180.0

        let cosHA = (cos((90.0 - altitude) * .pi / 180.0) / (cos(latRad) * cos(declRad))) - tan(latRad) * tan(declRad)

        // Handle polar day/night
        if cosHA > 1.0 { return 0.0 }   // Sun never rises
        if cosHA < -1.0 { return 180.0 } // Sun never sets

        return acos(cosHA) * 180.0 / .pi
    }

    /// Solar noon time in minutes from midnight
    private static func solarNoonTime(jd: Double, longitude: Double, timezone: Double) -> Double {
        let t = julianCentury(jd: jd)
        let eqTime = equationOfTime(t: t)
        return 720.0 - 4.0 * longitude - eqTime + timezone * 60.0
    }

    /// Sunrise time in minutes from midnight
    private static func sunriseTime(jd: Double, latitude: Double, longitude: Double, timezone: Double, altitude: Double = -0.833) -> Double {
        let t = julianCentury(jd: jd)
        let eqTime = equationOfTime(t: t)
        let decl = sunDeclination(t: t)
        let ha = hourAngleSunrise(lat: latitude, decl: decl, altitude: altitude)
        return 720.0 - 4.0 * (longitude + ha) - eqTime + timezone * 60.0
    }

    /// Sunset time in minutes from midnight
    private static func sunsetTime(jd: Double, latitude: Double, longitude: Double, timezone: Double, altitude: Double = -0.833) -> Double {
        let t = julianCentury(jd: jd)
        let eqTime = equationOfTime(t: t)
        let decl = sunDeclination(t: t)
        let ha = hourAngleSunrise(lat: latitude, decl: decl, altitude: altitude)
        return 720.0 - 4.0 * (longitude - ha) - eqTime + timezone * 60.0
    }

    /// Convert minutes from midnight to Date
    private static func timeFromMinutes(_ minutes: Double, on date: Date, timezone: TimeZone) -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)

        // Clamp to valid range (handle edge cases at poles)
        let clampedMinutes = max(0, min(minutes, 1440))
        return startOfDay.addingTimeInterval(clampedMinutes * 60.0)
    }
}

// MARK: - Default Location Fallback

extension SolarCalculator {
    /// Estimate rough latitude from timezone (very approximate)
    static func estimatedLatitude(from timezone: TimeZone) -> Double {
        // Most populated areas are between 30-50 degrees latitude
        // Use timezone offset as a very rough proxy
        let offset = Double(timezone.secondsFromGMT()) / 3600.0

        // Rough heuristic: Northern hemisphere for most positive offsets
        if offset >= -3 && offset <= 3 {
            // Europe/Africa
            return 45.0
        } else if offset >= 4 && offset <= 12 {
            // Asia/Australia
            return 35.0
        } else {
            // Americas
            return 40.0
        }
    }

    /// Estimate longitude from timezone
    static func estimatedLongitude(from timezone: TimeZone) -> Double {
        // 15 degrees per hour offset
        let offset = Double(timezone.secondsFromGMT()) / 3600.0
        return offset * 15.0
    }
}
