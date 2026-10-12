// LiveWeatherConfiguration.swift
// rootshell

#if !CHINA_BUILD
import Foundation
import CoreFoundation

struct LiveWeatherConfiguration: Equatable, Sendable {
    enum Quality: String, CaseIterable, Sendable {
        case economical, balanced, cinematic
        var pixelBudget: Double {
            switch self {
            case .economical: return 700_000
            case .balanced: return 1_400_000
            case .cinematic: return 2_800_000
            }
        }
        var cloudSteps: Int {
            switch self {
            case .economical: return 10
            case .balanced: return 14
            case .cinematic: return 22
            }
        }
        /// Cloud field re-renders per second; frames in between reproject it.
        var cloudRate: Double {
            switch self {
            case .economical: return 5
            case .balanced: return 8
            case .cinematic: return 12
            }
        }
        var ambientFramesPerSecond: Int { self == .cinematic ? 20 : 15 }
        var activeFramesPerSecond: Int { self == .cinematic ? 60 : 30 }
        var maxRaindrops: Int {
            switch self {
            case .economical: return 500
            case .balanced: return 900
            case .cinematic: return 1_500
            }
        }
        var maxSnowflakes: Int {
            switch self {
            case .economical: return 300
            case .balanced: return 500
            case .cinematic: return 800
            }
        }
    }

    enum LocationSource: String, CaseIterable, Sendable {
        case device, city
    }

    var intensity: Double = 0.30
    var readingProtection: Double = 0.40
    var quality: Quality = .balanced
    var locationSource: LocationSource = .device
    var city: WeatherCity?
    var showStars = true
    var showSunAndMoon = true
    var lightningFlashes = true
    var showInSidebar = true
    var demo = false

    var selection: WeatherLocationSelection {
        if locationSource == .city, let city { return .city(city) }
        return .device
    }

    static func finite(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    func sanitized() -> Self {
        var c = self
        c.intensity = Self.finite(c.intensity, 0...1, fallback: 0.30)
        c.readingProtection = Self.finite(c.readingProtection, 0...1, fallback: 0.40)
        if let city = c.city {
            if city.latitude.isFinite, city.longitude.isFinite, abs(city.latitude) <= 90, abs(city.longitude) <= 180 {
                c.city = WeatherCity(name: String(city.name.prefix(120)), latitude: city.latitude, longitude: city.longitude)
            } else {
                c.city = nil
            }
        }
        return c
    }

    var dictionary: [String: Any] {
        let c = sanitized()
        var dictionary: [String: Any] = [
            "version": 1, "intensity": c.intensity, "readingProtection": c.readingProtection,
            "quality": c.quality.rawValue, "locationSource": c.locationSource.rawValue,
            "showStars": c.showStars, "showSunAndMoon": c.showSunAndMoon,
            "lightningFlashes": c.lightningFlashes, "showInSidebar": c.showInSidebar, "demo": c.demo
        ]
        if let city = c.city {
            dictionary["cityName"] = city.name
            dictionary["cityLatitude"] = city.latitude
            dictionary["cityLongitude"] = city.longitude
        }
        return dictionary
    }

    /// Partial or older dictionaries keep defaults; unknown keys are ignored.
    static func decode(_ data: [String: Any], defaults: Self = Self()) -> Self {
        var c = defaults
        func number(_ key: String) -> Double? {
            guard let value = data[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        c.intensity = number("intensity") ?? c.intensity
        c.readingProtection = number("readingProtection") ?? c.readingProtection
        if let raw = data["quality"] as? String, let quality = Quality(rawValue: raw) { c.quality = quality }
        if let raw = data["locationSource"] as? String, let source = LocationSource(rawValue: raw) { c.locationSource = source }
        if let name = data["cityName"] as? String, let lat = number("cityLatitude"), let lon = number("cityLongitude") {
            c.city = WeatherCity(name: name, latitude: lat, longitude: lon)
        }
        c.showStars = data["showStars"] as? Bool ?? c.showStars
        c.showSunAndMoon = data["showSunAndMoon"] as? Bool ?? c.showSunAndMoon
        c.lightningFlashes = data["lightningFlashes"] as? Bool ?? c.lightningFlashes
        c.showInSidebar = data["showInSidebar"] as? Bool ?? c.showInSidebar
        c.demo = data["demo"] as? Bool ?? c.demo
        return c.sanitized()
    }
}
#endif
