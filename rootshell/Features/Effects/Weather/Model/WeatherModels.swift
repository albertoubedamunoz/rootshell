// WeatherModels.swift
// rootshell
// Pure value types shared by the weather clients, store, and renderer.

#if !CHINA_BUILD
import Foundation

nonisolated enum WeatherConditionKind: String, Codable, CaseIterable, Sendable {
    case clear, partlyCloudy, cloudy, fog, haze, smoke, dust, drizzle, rain, heavyRain
    case snow, heavySnow, sleet, freezingRain, thunderstorm, windy

    /// Cover implied by the condition when a source reports no numeric cloud cover.
    var typicalCloudCover: Double {
        switch self {
        case .clear: return 0.05
        case .partlyCloudy, .windy: return 0.45
        case .cloudy: return 0.9
        case .fog: return 0.85
        case .haze, .smoke, .dust: return 0.05
        case .drizzle, .snow, .sleet: return 0.95
        case .rain, .heavyRain, .heavySnow, .freezingRain, .thunderstorm: return 1
        }
    }
}

nonisolated enum WeatherSource: String, Codable, Sendable {
    case nws, metNorway
}

/// Rounded to 0.01° (about 1 km): the cache key, and all that leaves the device.
nonisolated struct WeatherCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        let lat = latitude.isFinite ? min(max(latitude, -90), 90) : 0
        var lon = (longitude.isFinite ? longitude : 0) + 180
        lon = lon.truncatingRemainder(dividingBy: 360)
        if lon < 0 { lon += 360 }
        self.latitude = (lat * 100).rounded() / 100
        self.longitude = ((lon - 180) * 100).rounded() / 100
    }

    var key: String { String(format: "%.2f,%.2f", latitude, longitude) }
    var queryLatitude: String { String(format: "%.2f", latitude) }
    var queryLongitude: String { String(format: "%.2f", longitude) }
}

/// One moment of weather, normalised across sources to SI units.
nonisolated struct WeatherSample: Codable, Equatable, Sendable {
    var date: Date
    var kind: WeatherConditionKind
    var cloudCover: Double                  // 0...1
    var cloudLow: Double? = nil
    var cloudMid: Double? = nil
    var cloudHigh: Double? = nil
    var precipitationRate: Double? = nil    // mm/h
    var precipitationChance: Double? = nil  // 0...1
    var thunderChance: Double? = nil        // 0...1
    var windSpeed: Double? = nil            // m/s
    var windGust: Double? = nil             // m/s
    var windFrom: Double? = nil             // degrees, meteorological
    var visibility: Double? = nil           // metres
    var fogFraction: Double? = nil          // 0...1
    var temperature: Double? = nil          // °C
}

nonisolated struct WeatherSnapshot: Codable, Equatable, Sendable {
    var coordinate: WeatherCoordinate
    var source: WeatherSource
    var current: WeatherSample
    var hourly: [WeatherSample]
    var fetchedAt: Date
    /// The source's earliest refetch time (met.no `Expires`).
    var expiresAt: Date?
    var placeName: String?
}

nonisolated struct WeatherCity: Codable, Hashable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

nonisolated enum WeatherLocationSelection: Hashable, Sendable {
    case device
    case city(WeatherCity)
}
#endif
