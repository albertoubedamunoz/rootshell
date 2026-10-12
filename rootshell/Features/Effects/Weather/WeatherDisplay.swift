// WeatherDisplay.swift
// rootshell
// Names, symbols, and units shared by Live Weather settings and the sidebar.

#if !CHINA_BUILD
import Foundation

extension WeatherConditionKind {
    var localizedName: String {
        switch self {
        case .clear: return String(localized: "Clear", comment: "Weather condition")
        case .partlyCloudy: return String(localized: "Partly Cloudy", comment: "Weather condition")
        case .cloudy: return String(localized: "Cloudy", comment: "Weather condition")
        case .fog: return String(localized: "Fog", comment: "Weather condition")
        case .haze: return String(localized: "Haze", comment: "Weather condition")
        case .smoke: return String(localized: "Smoke", comment: "Weather condition")
        case .dust: return String(localized: "Dust", comment: "Weather condition")
        case .drizzle: return String(localized: "Drizzle", comment: "Weather condition")
        case .rain: return String(localized: "Rain", comment: "Weather condition")
        case .heavyRain: return String(localized: "Heavy Rain", comment: "Weather condition")
        case .snow: return String(localized: "Snow", comment: "Weather condition")
        case .heavySnow: return String(localized: "Heavy Snow", comment: "Weather condition")
        case .sleet: return String(localized: "Sleet", comment: "Weather condition")
        case .freezingRain: return String(localized: "Freezing Rain", comment: "Weather condition")
        case .thunderstorm: return String(localized: "Thunderstorms", comment: "Weather condition")
        case .windy: return String(localized: "Windy", comment: "Weather condition")
        }
    }

    func symbolName(night: Bool) -> String {
        switch self {
        case .clear: return night ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .haze: return night ? "moon.haze.fill" : "sun.haze.fill"
        case .smoke: return "smoke.fill"
        case .dust: return night ? "moon.dust.fill" : "sun.dust.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain: return "cloud.rain.fill"
        case .heavyRain: return "cloud.heavyrain.fill"
        case .snow, .heavySnow: return "cloud.snow.fill"
        case .sleet, .freezingRain: return "cloud.sleet.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .windy: return "wind"
        }
    }
}

extension WeatherSource {
    var displayName: String {
        switch self {
        case .nws: return String(localized: "National Weather Service", comment: "Weather data source")
        case .openMeteo: return String(localized: "Open-Meteo", comment: "Weather data source")
        case .metNorway: return String(localized: "MET Norway", comment: "Weather data source")
        }
    }

    /// Credit shown next to the data, linking to `website`.
    var attribution: String {
        switch self {
        case .nws: return String(localized: "National Weather Service", comment: "Weather data credit")
        case .openMeteo: return String(localized: "Weather data by Open-Meteo.com", comment: "Weather data credit required by Open-Meteo")
        case .metNorway: return String(localized: "Data from MET Norway", comment: "Weather data credit")
        }
    }

    var website: URL {
        switch self {
        case .nws: return URL(string: "https://www.weather.gov")!
        case .openMeteo: return URL(string: "https://open-meteo.com/")!
        case .metNorway: return URL(string: "https://api.met.no")!
        }
    }
}


extension WeatherSnapshot {
    /// The conditions to name at `date`, as the sky draws them.
    func displaySample(at date: Date) -> WeatherSample {
        WeatherTimeline.sample(at: date, snapshot: self)
    }

    func isNight(at date: Date) -> Bool {
        SolarCalculator.calculatePosition(date: date, latitude: coordinate.latitude, longitude: coordinate.longitude).altitude < -3
    }
}

enum WeatherFormat {
    /// "64°" in the user's preferred unit.
    static func temperature(_ celsius: Double, width: Measurement<UnitTemperature>.FormatStyle.UnitWidth = .narrow) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: width, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func windSpeed(_ metresPerSecond: Double) -> String {
        Measurement(value: metresPerSecond, unit: UnitSpeed.metersPerSecond)
            .formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func distance(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
#endif
