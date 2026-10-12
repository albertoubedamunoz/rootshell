// WeatherTimeline.swift
// rootshell

#if !CHINA_BUILD
import Foundation

/// Evolves the scene between fetches: current conditions first, then the
/// hourly forecast, interpolated so nothing jumps on the hour.
nonisolated enum WeatherTimeline {
    static let currentHold: TimeInterval = 30 * 60
    static let handoff: TimeInterval = 30 * 60

    static func target(at date: Date, snapshot: WeatherSnapshot) -> WeatherVisualState {
        let current = WeatherVisualState.target(for: snapshot.current)
        let elapsed = date.timeIntervalSince(snapshot.fetchedAt)
        guard elapsed > currentHold, let forecast = forecast(at: date, hourly: snapshot.hourly) else { return current }
        let t = smoothstep(min(max((elapsed - currentHold) / handoff, 0), 1))
        return .lerp(current, forecast, t)
    }

    /// Hourly samples are interpolated across each hour they describe.
    static func forecast(at date: Date, hourly: [WeatherSample]) -> WeatherVisualState? {
        guard let first = hourly.first else { return nil }
        if date <= first.date { return .target(for: first) }
        for (a, b) in zip(hourly, hourly.dropFirst()) where date >= a.date && date < b.date {
            let span = b.date.timeIntervalSince(a.date)
            let t = span > 0 ? date.timeIntervalSince(a.date) / span : 0
            return .lerp(.target(for: a), .target(for: b), smoothstep(t))
        }
        return hourly.last.map { .target(for: $0) }
    }

    private static func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
#endif
