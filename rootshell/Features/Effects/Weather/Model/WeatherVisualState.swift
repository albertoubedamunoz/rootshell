// WeatherVisualState.swift
// rootshell

#if !CHINA_BUILD
import Foundation

/// Continuous scene parameters the renderer draws. Every field blends
/// linearly, so condition changes become smooth transitions.
nonisolated struct WeatherVisualState: Equatable, Sendable {
    var cloudLow: Double = 0.1       // cumulus and stratus coverage
    var cloudMid: Double = 0         // altocumulus and altostratus coverage
    var cloudHigh: Double = 0.1      // cirrus coverage
    var cloudDensity: Double = 0.4   // optical thickness of the low layer
    var cloudBase = WeatherSkyGeometry.cloudBase  // km, low layer
    var cumuliform: Double = 0.5     // 0 stable sheets, 1 convective heaps
    var towering: Double = 0         // vertical development (cumulonimbus)
    var rain: Double = 0
    var snow: Double = 0
    var sleetMix: Double = 0         // share of precipitation drawn as pellets
    var fog: Double = 0
    var haze: Double = 0
    var hazeTint = SIMD3<Double>(0.82, 0.82, 0.80)
    var lightning: Double = 0
    var windEast: Double = 0.15      // drift toward east, -1...1
    var windNorth: Double = 0        // drift toward north, -1...1
    var gustiness: Double = 0

    var windStrength: Double { min(sqrt(windEast * windEast + windNorth * windNorth), 1) }
    var hasPrecipitation: Bool { rain > 0.01 || snow > 0.01 }

    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self {
        let t = min(max(t, 0), 1)
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Self(cloudLow: m(a.cloudLow, b.cloudLow), cloudMid: m(a.cloudMid, b.cloudMid), cloudHigh: m(a.cloudHigh, b.cloudHigh),
                    cloudDensity: m(a.cloudDensity, b.cloudDensity), cloudBase: m(a.cloudBase, b.cloudBase),
                    cumuliform: m(a.cumuliform, b.cumuliform), towering: m(a.towering, b.towering),
                    rain: m(a.rain, b.rain), snow: m(a.snow, b.snow), sleetMix: m(a.sleetMix, b.sleetMix),
                    fog: m(a.fog, b.fog), haze: m(a.haze, b.haze),
                    hazeTint: a.hazeTint + (b.hazeTint - a.hazeTint) * t,
                    lightning: m(a.lightning, b.lightning), windEast: m(a.windEast, b.windEast),
                    windNorth: m(a.windNorth, b.windNorth), gustiness: m(a.gustiness, b.gustiness))
    }

    /// The largest change in any one parameter, to tell a jump from a drift.
    func distance(to other: Self) -> Double {
        let pairs = [(cloudLow, other.cloudLow), (cloudMid, other.cloudMid), (cloudHigh, other.cloudHigh),
                     (cloudDensity, other.cloudDensity), (cloudBase / 3, other.cloudBase / 3), (cumuliform, other.cumuliform),
                     (towering, other.towering), (rain, other.rain), (snow, other.snow), (sleetMix, other.sleetMix),
                     (fog, other.fog), (haze, other.haze), (lightning, other.lightning), (windEast, other.windEast),
                     (windNorth, other.windNorth), (gustiness, other.gustiness)]
        let tint = hazeTint - other.hazeTint
        return pairs.reduce(max(abs(tint.x), abs(tint.y), abs(tint.z))) { max($0, abs($1.0 - $1.1)) }
    }

    /// Per-condition baseline, refined by whatever numbers the source reported.
    static func target(for sample: WeatherSample) -> Self {
        var s = Self()
        let kind = sample.kind
        let cover = clamp(sample.cloudCover)
        if let low = sample.cloudLow {
            // Rain falls from a low base, even when the model files its deck as mid cloud.
            let mid = clamp(sample.cloudMid ?? 0)
            s.cloudLow = clamp(kind.isPrecipitation ? max(low, mid * 0.8) : low)
            if s.cloudLow < 0.08 { s.cloudLow = 0 }
            s.cloudMid = mid < 0.05 ? 0 : mid
            s.cloudHigh = clamp(sample.cloudHigh ?? cover * 0.3)
        } else {
            // A few percent reads as clear; stray specks look like stains at night.
            s.cloudLow = cover < 0.08 ? 0 : cover
            s.cloudMid = kind == .partlyCloudy || kind == .windy ? cover * 0.35 : 0
            s.cloudHigh = [.clear, .partlyCloudy, .windy, .haze].contains(kind) ? min(cover * 0.8 + 0.15, 0.6) : cover * 0.3
        }
        switch kind {
        case .clear: s.cloudDensity = 0.35
        case .partlyCloudy, .windy: s.cloudDensity = 0.45
        case .cloudy: s.cloudDensity = 0.62
        case .fog, .haze, .smoke, .dust: s.cloudDensity = 0.5
        case .drizzle: s.cloudDensity = 0.7
        case .rain, .snow: s.cloudDensity = 0.78
        case .sleet, .freezingRain: s.cloudDensity = 0.82
        case .heavyRain, .heavySnow: s.cloudDensity = 0.92
        case .thunderstorm: s.cloudDensity = 1
        }
        s.towering = kind == .thunderstorm ? 1 : (kind == .heavyRain ? 0.35 : (kind == .rain ? 0.12 : 0))

        // A measured base, else the lifting condensation level: about 125 m per °C of dew-point spread.
        let spread = sample.temperature.flatMap { t in sample.dewPoint.map { max(t - $0, 0) } }
        if let base = sample.cloudBase ?? spread.map({ $0 * 125 }), base.isFinite {
            s.cloudBase = min(max(base / 1_000, 0.5), 2.6)
        }
        // Instability heaps low cloud and builds congestus; a stable column spreads it into sheets.
        if let cape = sample.cape, cape.isFinite {
            s.cumuliform = 0.25 + 0.75 * (1 - exp(-max(cape, 0) / 300))
            if s.cloudLow > 0.05 { s.towering = max(s.towering, smoothstep(800, 3_000, cape) * 0.45) }
        }
        if let convective = sample.convectiveCloud, convective > 0 {
            s.cumuliform = max(s.cumuliform, 0.8)
            s.towering = max(s.towering, clamp(convective) * 0.75)
        }

        let chance = sample.precipitationChance.map { 0.45 + 0.55 * clamp($0) } ?? 1
        let rate = sample.precipitationRate
        func amount(baseline: Double, scale: Double) -> Double {
            guard let rate, rate > 0 else { return baseline * chance }
            return clamp(max(0.12 + 0.88 * sqrt(rate / scale), baseline * 0.5)) * chance
        }
        switch kind {
        case .drizzle: s.rain = amount(baseline: 0.18, scale: 12)
        case .rain: s.rain = amount(baseline: 0.42, scale: 12)
        case .heavyRain: s.rain = amount(baseline: 0.85, scale: 12)
        case .thunderstorm: s.rain = amount(baseline: 0.7, scale: 12)
        case .freezingRain: s.rain = amount(baseline: 0.45, scale: 12)
        case .snow: s.snow = amount(baseline: 0.45, scale: 4)
        case .heavySnow: s.snow = amount(baseline: 0.9, scale: 4)
        case .sleet:
            s.rain = amount(baseline: 0.35, scale: 12)
            s.snow = amount(baseline: 0.3, scale: 4)
            s.sleetMix = 0.5
        default: break
        }
        if kind == .freezingRain { s.sleetMix = 0.25 }

        let visibilityFog = sample.visibility.map { 1 - smoothstep(600, 5_000, $0) } ?? 0
        s.fog = max(kind == .fog ? 0.75 : 0, visibilityFog * 0.9, clamp(sample.fogFraction ?? 0) * 0.9)
        switch kind {
        case .haze: s.haze = 0.45; s.hazeTint = SIMD3(0.86, 0.84, 0.80)
        case .smoke: s.haze = 0.6; s.hazeTint = SIMD3(0.88, 0.64, 0.46)
        case .dust: s.haze = 0.55; s.hazeTint = SIMD3(0.88, 0.72, 0.50)
        default:
            if let visibility = sample.visibility {
                s.haze = (1 - smoothstep(5_000, 12_000, visibility)) * 0.2
            }
        }

        let thunder = sample.thunderChance.map(clamp) ?? 0
        s.lightning = kind == .thunderstorm ? max(0.55, thunder) : (thunder > 0.3 ? thunder * 0.6 : 0)

        // Wind blows from `windFrom`; drift toward the opposite bearing.
        let speed = sample.windSpeed ?? (kind == .windy ? 9 : 3)
        let toward = ((sample.windFrom ?? 250) + 180) * .pi / 180
        let strength = min(speed / 15, 1) * (kind == .windy ? 1.2 : 1)
        s.windEast = sin(toward) * min(strength, 1)
        s.windNorth = cos(toward) * min(strength, 1)
        if let gust = sample.windGust, speed > 0.5 {
            s.gustiness = clamp((gust / speed - 1) * 0.8)
        } else {
            s.gustiness = kind == .windy || kind == .thunderstorm ? 0.5 : 0.15
        }
        return s
    }

    /// A representative sample for demo mode and previews.
    static func demoSample(_ kind: WeatherConditionKind, date: Date) -> WeatherSample {
        var sample = WeatherSample(date: date, kind: kind, cloudCover: kind.typicalCloudCover,
                                   windSpeed: kind == .windy ? 12 : 4, windFrom: 250)
        switch kind {
        case .fog: sample.visibility = 400
        case .haze, .smoke, .dust: sample.visibility = 4_000
        case .thunderstorm: sample.thunderChance = 0.8
        default: break
        }
        return sample
    }

    private static func clamp(_ x: Double) -> Double { x.isFinite ? min(max(x, 0), 1) : 0 }
    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
}
#endif
