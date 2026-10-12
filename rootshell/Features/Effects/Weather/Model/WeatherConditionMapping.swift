// WeatherConditionMapping.swift
// rootshell
// Maps NWS icon codes, METAR phenomena, and MET Norway symbol codes onto
// WeatherConditionKind. Pure, so the tables are unit tested without a network.

#if !CHINA_BUILD
import Foundation

nonisolated struct WeatherConditionReading: Equatable, Sendable {
    var kind: WeatherConditionKind
    var cloudCover: Double
    /// Typical rate for the reported intensity, when the source gives none.
    var precipitationRate: Double?
    var thunder: Bool = false
}

// MARK: - National Weather Service

nonisolated enum NWSConditionMapping {
    /// `https://api.weather.gov/icons/land/day/tsra_hi,40/rain,60?size=medium`
    /// yields `[("tsra_hi", 0.4), ("rain", 0.6)]`.
    static func iconCodes(from url: String) -> [(code: String, chance: Double?)] {
        guard let path = URLComponents(string: url)?.path else { return [] }
        let parts = path.split(separator: "/").map(String.init)
        guard let start = parts.firstIndex(where: { $0 == "day" || $0 == "night" }) else { return [] }
        return parts[(start + 1)...].compactMap { part in
            let fields = part.split(separator: ",", maxSplits: 1).map(String.init)
            guard let code = fields.first, !code.isEmpty else { return nil }
            let chance = fields.count > 1 ? Double(fields[1]).map { min(max($0 / 100, 0), 1) } : nil
            return (code, chance)
        }
    }

    static func reading(iconCode code: String) -> WeatherConditionReading? {
        switch code {
        case "skc", "hot", "cold": return .init(kind: .clear, cloudCover: 0)
        case "few": return .init(kind: .clear, cloudCover: 0.2)
        case "sct": return .init(kind: .partlyCloudy, cloudCover: 0.45)
        case "bkn": return .init(kind: .cloudy, cloudCover: 0.75)
        case "ovc": return .init(kind: .cloudy, cloudCover: 1)
        case "wind_skc": return .init(kind: .windy, cloudCover: 0)
        case "wind_few": return .init(kind: .windy, cloudCover: 0.2)
        case "wind_sct": return .init(kind: .windy, cloudCover: 0.45)
        case "wind_bkn": return .init(kind: .windy, cloudCover: 0.75)
        case "wind_ovc": return .init(kind: .windy, cloudCover: 1)
        case "snow": return .init(kind: .snow, cloudCover: 0.95, precipitationRate: 1.2)
        case "blizzard": return .init(kind: .heavySnow, cloudCover: 1, precipitationRate: 4)
        case "rain_snow", "rain_sleet", "snow_sleet", "sleet":
            return .init(kind: .sleet, cloudCover: 0.95, precipitationRate: 1.5)
        case "fzra", "rain_fzra", "snow_fzra": return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: 1.5)
        case "rain": return .init(kind: .rain, cloudCover: 0.95, precipitationRate: 2.5)
        case "rain_showers": return .init(kind: .rain, cloudCover: 0.8, precipitationRate: 2.5)
        case "rain_showers_hi": return .init(kind: .rain, cloudCover: 0.5, precipitationRate: 1.5)
        case "tsra": return .init(kind: .thunderstorm, cloudCover: 0.95, precipitationRate: 6, thunder: true)
        case "tsra_sct": return .init(kind: .thunderstorm, cloudCover: 0.7, precipitationRate: 4, thunder: true)
        case "tsra_hi": return .init(kind: .thunderstorm, cloudCover: 0.5, precipitationRate: 3, thunder: true)
        case "tornado": return .init(kind: .thunderstorm, cloudCover: 1, precipitationRate: 8, thunder: true)
        case "hurricane", "tropical_storm": return .init(kind: .heavyRain, cloudCover: 1, precipitationRate: 12)
        case "dust": return .init(kind: .dust, cloudCover: 0.1)
        case "smoke": return .init(kind: .smoke, cloudCover: 0.2)
        case "haze": return .init(kind: .haze, cloudCover: 0.2)
        case "fog": return .init(kind: .fog, cloudCover: 0.9)
        default: return nil
        }
    }

    /// The first recognised code of an icon URL, weighted by its precipitation chance.
    static func reading(iconURL: String) -> (reading: WeatherConditionReading, chance: Double?)? {
        for entry in iconCodes(from: iconURL) {
            if let reading = reading(iconCode: entry.code) { return (reading, entry.chance) }
        }
        return nil
    }

    /// METAR `presentWeather` entries; the most significant phenomenon wins.
    static func reading(phenomena: [(weather: String, intensity: String?, modifier: String?)]) -> WeatherConditionReading? {
        guard !phenomena.isEmpty else { return nil }
        func scale(_ intensity: String?, light: Double, moderate: Double, heavy: Double) -> Double {
            switch intensity { case "light": return light; case "heavy": return heavy; default: return moderate }
        }
        let names = Set(phenomena.map(\.weather))
        if let storm = phenomena.first(where: { $0.weather == "thunderstorms" }) {
            return .init(kind: .thunderstorm, cloudCover: 1,
                         precipitationRate: scale(storm.intensity, light: 2, moderate: 5, heavy: 12), thunder: true)
        }
        if let freezing = phenomena.first(where: { $0.modifier == "freezing" && ($0.weather == "rain" || $0.weather == "drizzle") }) {
            return .init(kind: .freezingRain, cloudCover: 1, precipitationRate: scale(freezing.intensity, light: 0.5, moderate: 1.5, heavy: 4))
        }
        let frozen = ["snow", "snow_grains", "snow_pellets", "ice_crystals"]
        if let snow = phenomena.first(where: { frozen.contains($0.weather) }) {
            if names.contains("rain") || names.contains("drizzle") || names.contains("ice_pellets") {
                return .init(kind: .sleet, cloudCover: 1, precipitationRate: scale(snow.intensity, light: 0.6, moderate: 1.5, heavy: 3.5))
            }
            let heavy = snow.intensity == "heavy" || snow.modifier == "blowing"
            return .init(kind: heavy ? .heavySnow : .snow, cloudCover: 1,
                         precipitationRate: scale(snow.intensity, light: 0.5, moderate: 1.5, heavy: 4))
        }
        if let ice = phenomena.first(where: { ["ice_pellets", "hail", "small_hail"].contains($0.weather) }) {
            return .init(kind: .sleet, cloudCover: 1, precipitationRate: scale(ice.intensity, light: 0.6, moderate: 1.5, heavy: 4))
        }
        if let rain = phenomena.first(where: { $0.weather == "rain" }) {
            return .init(kind: rain.intensity == "heavy" ? .heavyRain : .rain, cloudCover: 0.95,
                         precipitationRate: scale(rain.intensity, light: 0.8, moderate: 3, heavy: 10))
        }
        if let drizzle = phenomena.first(where: { $0.weather == "drizzle" }) {
            return .init(kind: .drizzle, cloudCover: 0.95, precipitationRate: scale(drizzle.intensity, light: 0.15, moderate: 0.3, heavy: 0.6))
        }
        if names.contains("fog") || names.contains("fog_mist") { return .init(kind: .fog, cloudCover: 0.9) }
        if names.contains("smoke") || names.contains("volcanic_ash") { return .init(kind: .smoke, cloudCover: 0.2) }
        if !names.isDisjoint(with: ["dust", "sand", "dust_storm", "sand_storm", "dust_whirls"]) {
            return .init(kind: .dust, cloudCover: 0.1)
        }
        if names.contains("haze") || names.contains("spray") { return .init(kind: .haze, cloudCover: 0.2) }
        if names.contains("squalls") || names.contains("funnel_cloud") { return .init(kind: .thunderstorm, cloudCover: 1, precipitationRate: 4) }
        return nil
    }

    /// METAR cloud layer amounts; the densest layer sets the cover.
    static func cloudCover(layerAmounts: [String]) -> Double? {
        let values = layerAmounts.compactMap { amount -> Double? in
            switch amount.uppercased() {
            case "CLR", "SKC", "NCD", "NSC": return 0
            case "FEW": return 0.2
            case "SCT": return 0.45
            case "BKN": return 0.75
            case "OVC", "VV": return 1
            default: return nil
            }
        }
        return values.max()
    }

    /// "SW", "NNE" ... as meteorological degrees.
    static func degrees(compass: String) -> Double? {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard let index = points.firstIndex(of: compass.uppercased().trimmingCharacters(in: .whitespaces)) else { return nil }
        return Double(index) * 22.5
    }

    /// "10 km/h", "5 to 15 mph" or "10 kt" as m/s, using the upper bound of a range.
    static func windSpeed(text: String) -> Double? {
        let lower = text.lowercased()
        let numbers = lower.split(whereSeparator: { !$0.isNumber && $0 != "." }).compactMap { Double($0) }
        guard let value = numbers.max() else { return nil }
        if lower.contains("km/h") { return value / 3.6 }
        if lower.contains("mph") { return value * 0.44704 }
        if lower.contains("kt") || lower.contains("knot") { return value * 0.514444 }
        if lower.contains("m/s") { return value }
        return value * 0.44704
    }

    /// NWS quantitative values carry a WMO unit code such as `wmoUnit:km_h-1`.
    static func metresPerSecond(_ value: Double, unitCode: String?) -> Double {
        let unit = unitCode?.lowercased() ?? ""
        if unit.contains("km_h") { return value / 3.6 }
        if unit.contains("kt") || unit.contains("knot") { return value * 0.514444 }
        if unit.contains("mi_h") || unit.contains("mph") { return value * 0.44704 }
        return value
    }
}

// MARK: - MET Norway

nonisolated enum METNorwayConditionMapping {
    /// `heavyrainshowersandthunder_day` and friends. The API also spells some
    /// light variants `lights...`; the prefix test covers those too.
    static func reading(symbolCode: String) -> WeatherConditionReading? {
        var code = symbolCode.lowercased()
        for suffix in ["_day", "_night", "_polartwilight"] where code.hasSuffix(suffix) {
            code.removeLast(suffix.count)
        }
        switch code {
        case "clearsky": return .init(kind: .clear, cloudCover: 0)
        case "fair": return .init(kind: .clear, cloudCover: 0.2)
        case "partlycloudy": return .init(kind: .partlyCloudy, cloudCover: 0.5)
        case "cloudy": return .init(kind: .cloudy, cloudCover: 0.95)
        case "fog": return .init(kind: .fog, cloudCover: 0.9)
        default: break
        }
        let thunder = code.contains("thunder")
        let light = code.hasPrefix("light")
        let heavy = code.hasPrefix("heavy")
        let showers = code.contains("showers")
        let cover: Double = showers ? 0.75 : 1
        func rate(light l: Double, moderate m: Double, heavy h: Double) -> Double { light ? l : (heavy ? h : m) }
        let reading: WeatherConditionReading
        if code.contains("sleet") {
            reading = .init(kind: .sleet, cloudCover: cover, precipitationRate: rate(light: 0.5, moderate: 1.5, heavy: 4))
        } else if code.contains("snow") {
            reading = .init(kind: heavy ? .heavySnow : .snow, cloudCover: cover, precipitationRate: rate(light: 0.4, moderate: 1.2, heavy: 3.5))
        } else if code.contains("rain") {
            reading = .init(kind: heavy ? .heavyRain : .rain, cloudCover: cover,
                            precipitationRate: rate(light: 0.5, moderate: 2.5, heavy: 8))
        } else {
            return nil
        }
        guard thunder else { return reading }
        return .init(kind: .thunderstorm, cloudCover: cover, precipitationRate: reading.precipitationRate, thunder: true)
    }
}

// MARK: - Coverage

/// Rough boxes around the areas api.weather.gov serves. A miss only costs a
/// MET Norway request; a false hit falls back on the NWS 404.
nonisolated enum NWSCoverage {
    private static let regions: [(lat: ClosedRange<Double>, lon: ClosedRange<Double>)] = [
        (24.3...49.5, -125.0...(-66.8)),    // contiguous states
        (51.0...71.6, -180.0...(-129.9)),   // Alaska
        (51.0...56.0, 172.0...180.0),       // western Aleutians
        (18.8...22.4, -160.4...(-154.7)),   // Hawaii
        (17.6...18.6, -67.4...(-64.5)),     // Puerto Rico and US Virgin Islands
        (13.1...20.7, 144.5...146.2),       // Guam and the Northern Marianas
        (-14.7...(-14.0), -171.2...(-168.0)) // American Samoa
    ]

    static func contains(_ coordinate: WeatherCoordinate) -> Bool {
        regions.contains { $0.lat.contains(coordinate.latitude) && $0.lon.contains(coordinate.longitude) }
    }
}
#endif
