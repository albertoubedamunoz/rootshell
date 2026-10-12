// WeatherVisualAnimator.swift
// rootshell

#if !CHINA_BUILD
import Foundation

/// Fades from what was on screen toward a target that may itself keep moving
/// (the forecast timeline). Restarting mid-fade begins from the displayed
/// value, so a new snapshot never jumps.
nonisolated struct WeatherVisualAnimator: Sendable {
    private var origin: WeatherVisualState?
    private var start: Double = 0
    private var duration: Double = 0

    mutating func begin(from displayed: WeatherVisualState, at now: Double, duration: Double) {
        guard duration > 0 else { origin = nil; return }
        origin = displayed
        start = now
        self.duration = duration
    }

    func isActive(at now: Double) -> Bool {
        origin != nil && now - start < duration
    }

    func apply(_ target: WeatherVisualState, at now: Double) -> WeatherVisualState {
        guard let origin, duration > 0 else { return target }
        let t = min(max((now - start) / duration, 0), 1)
        guard t < 1 else { return target }
        // Smootherstep: zero velocity and acceleration at both ends.
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        return .lerp(origin, target, eased)
    }
}

/// Accumulates animation time; long gaps are dropped, not replayed, so
/// returning from the background never fast-forwards the weather.
nonisolated struct WeatherClock: Sendable {
    private(set) var time: Double = 0
    private var last: Double?
    mutating func suspend() { last = nil }
    @discardableResult
    mutating func advance(now: Double, paused: Bool) -> Double {
        guard now.isFinite, !paused else { last = nil; return 0 }
        defer { last = now }
        guard let previous = last else { return 0 }
        let elapsed = now - previous
        guard elapsed >= 0, elapsed <= 0.5 else { return 0 }
        time += elapsed
        return elapsed
    }
}
#endif
