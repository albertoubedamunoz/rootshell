//
//  SolarGraphEffect.swift
//  rootshell
//
//  Solar graph visual effect inspired by Apple watchOS solarGraph watch face.
//  Displays a sun arc along the bottom edge that tracks real time of day.
//

import SwiftUI
import Combine
import CoreLocation
import os

/// Solar graph visual effect using real-time sun position
final class SolarGraphEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    let id = "solarGraph"
    let displayName = String(localized: "Solar", comment: "Background effect name: solar graph")
    let previewIcon = "sun.horizon"
    let effectDescription = String(localized: "Sun arc tracks time of day", comment: "Background effect description for solar graph")

    var intensity: Double = 0.35 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var speed: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Solar-Specific Configuration

    /// Whether to show the subtle arc track
    var showArcTrack: Bool = false {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to use device location (vs timezone estimate)
    /// Defaults to true so we prompt for permission on first activation
    var useLocation: Bool = true {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    /// Manual timezone override when not using device location
    var manualTimezone: TimeZone = .current {
        didSet {
            cachedTimes = nil
            cachedDate = nil
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    /// Whether to show stars at night
    var showStars: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether stars should twinkle (animation)
    var starTwinkle: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to show the artistic hotspot (3D depth highlight) on the sun disc
    var showSunHotspot: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    // MARK: - Ocean Configuration

    /// Whether to show the animated ocean surface below the horizon
    var showOcean: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Ocean wave amplitude (0.1 = calm, 1.0 = stormy)
    var oceanWaveAmplitude: Double = 0.4 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Sun reflection strength on water (0.0 = none, 1.0 = bright)
    var oceanReflectionStrength: Double = 0.6 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Ocean wave animation speed multiplier (0.1 = very slow, 1.0 = normal, 3.0 = fast)
    var oceanWaveSpeed: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to show occasional whale animation in demo mode
    var showWhaleAnimation: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to show bird migration flocks during daylight hours
    var showBirdMigration: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    // MARK: - Moon Configuration

    /// Whether to show the moon
    var showMoon: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Moon glow intensity multiplier (0.5 = subtle, 1.0 = normal, 1.5 = bright)
    var moonGlowIntensity: Double = 1.0 {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to show lunar maria (dark patches on moon surface)
    var showMaria: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    /// Whether to show earthshine effect (subtle illumination of dark limb near new moon)
    var showEarthshine: Bool = true {
        didSet { objectWillChange.send(); configurationDidChange.send() }
    }

    // MARK: - Demo Mode State

    /// Reference time for demo mode (shared across all views using this effect)
    var demoStartTime: Date = Date.now

    // MARK: - Ocean Animation Background Handling

    /// Cumulative time offset to skip background periods in ocean animation
    private var oceanTimeOffset: TimeInterval = 0

    /// Last frame time to detect pauses (background, etc.)
    private var lastOceanFrameTime: TimeInterval = 0

    /// Last corrected time to ensure monotonic output
    private var lastCorrectedOceanTime: TimeInterval = 0

    /// Calculate ocean animation time, auto-correcting for background pauses.
    /// Call this on each frame to get the current ocean time.
    /// - Parameter wrap: When true, wraps time to avoid float precision issues in shaders.
    func oceanTime(for frameTime: TimeInterval, wrap: Bool = true) -> Double {
        // Detect time jumps > 0.5 seconds (app was in background or paused)
        if lastOceanFrameTime > 0 {
            let delta = frameTime - lastOceanFrameTime
            if delta > 0.5 {
                // Skip the paused time to prevent catch-up animation
                oceanTimeOffset += delta - (1.0 / 60.0) // Assume normal frame time
            }
        }
        // Multiple TimelineViews may call this out of order; never move backwards.
        lastOceanFrameTime = max(lastOceanFrameTime, frameTime)

        let corrected = frameTime - oceanTimeOffset
        let monotonicCorrected = max(corrected, lastCorrectedOceanTime)
        lastCorrectedOceanTime = monotonicCorrected
        // Return time with offset applied, optionally wrapped to prevent floating point issues
        return wrap ? monotonicCorrected.truncatingRemainder(dividingBy: 10000.0) : monotonicCorrected
    }

    /// Called when app enters background (optional, for logging)
    func didEnterBackground() {
        // The time jump will be auto-detected on next frame
    }

    /// Called when app returns from background (optional, for logging)
    func didReturnFromBackground() {
        // The time jump will be auto-detected on next frame
    }

    // MARK: - Location Service

    let locationService = SolarLocationService()

    // MARK: - Cached Solar Data

    private var cachedTimes: SolarTimes?
    private var cachedDate: Date?

    // MARK: - Initialization

    init() {
        // Don't auto-request location - wait for user to enable useLocation
    }

    // MARK: - TerminalEffect Implementation

    func createEffectView() -> AnyView {
        AnyView(SolarGraphView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.35
        speed = 1.0
        showArcTrack = false
        useLocation = true
        manualTimezone = .current
        showStars = true
        starTwinkle = true
        showSunHotspot = true
        showOcean = true
        oceanWaveAmplitude = 0.4
        oceanReflectionStrength = 0.6
        oceanWaveSpeed = 1.0
        showWhaleAnimation = true
        showBirdMigration = true
        showMoon = true
        moonGlowIntensity = 1.0
        showMaria = true
        showEarthshine = true
    }

    func encodeConfiguration() -> [String: Any] {
        return [
            "intensity": intensity,
            "speed": speed,
            "showArcTrack": showArcTrack,
            "useLocation": useLocation,
            "manualTimezoneId": manualTimezone.identifier,
            "showStars": showStars,
            "starTwinkle": starTwinkle,
            "showSunHotspot": showSunHotspot,
            "showOcean": showOcean,
            "oceanWaveAmplitude": oceanWaveAmplitude,
            "oceanReflectionStrength": oceanReflectionStrength,
            "oceanWaveSpeed": oceanWaveSpeed,
            "showWhaleAnimation": showWhaleAnimation,
            "showBirdMigration": showBirdMigration,
            "showMoon": showMoon,
            "moonGlowIntensity": moonGlowIntensity,
            "showMaria": showMaria,
            "showEarthshine": showEarthshine
        ]
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = intensity
        }
        if let speed = data["speed"] as? Double {
            self.speed = speed
        }
        if let showArcTrack = data["showArcTrack"] as? Bool {
            self.showArcTrack = showArcTrack
        }
        if let useLocation = data["useLocation"] as? Bool {
            self.useLocation = useLocation
        }
        if let timezoneId = data["manualTimezoneId"] as? String,
           let timezone = TimeZone(identifier: timezoneId) {
            self.manualTimezone = timezone
        }
        if let showStars = data["showStars"] as? Bool {
            self.showStars = showStars
        }
        if let starTwinkle = data["starTwinkle"] as? Bool {
            self.starTwinkle = starTwinkle
        }
        if let showSunHotspot = data["showSunHotspot"] as? Bool {
            self.showSunHotspot = showSunHotspot
        }
        if let showOcean = data["showOcean"] as? Bool {
            self.showOcean = showOcean
        }
        if let oceanWaveAmplitude = data["oceanWaveAmplitude"] as? Double {
            self.oceanWaveAmplitude = oceanWaveAmplitude
        }
        if let oceanReflectionStrength = data["oceanReflectionStrength"] as? Double {
            self.oceanReflectionStrength = oceanReflectionStrength
        }
        if let oceanWaveSpeed = data["oceanWaveSpeed"] as? Double {
            self.oceanWaveSpeed = oceanWaveSpeed
        }
        if let showWhaleAnimation = data["showWhaleAnimation"] as? Bool {
            self.showWhaleAnimation = showWhaleAnimation
        }
        if let showBirdMigration = data["showBirdMigration"] as? Bool {
            self.showBirdMigration = showBirdMigration
        }
        if let showMoon = data["showMoon"] as? Bool {
            self.showMoon = showMoon
        }
        if let moonGlowIntensity = data["moonGlowIntensity"] as? Double {
            self.moonGlowIntensity = moonGlowIntensity
        }
        if let showMaria = data["showMaria"] as? Bool {
            self.showMaria = showMaria
        }
        if let showEarthshine = data["showEarthshine"] as? Bool {
            self.showEarthshine = showEarthshine
        }
    }

    // MARK: - Location Handling

    @MainActor
    func refreshLocation() async {
        guard useLocation else { return }

        // Request permission if not determined
        if locationService.authorizationStatus == .notDetermined {
            locationService.requestPermission()
            // Wait for user response
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Check if permission was denied
        let authStatus = locationService.authorizationStatus
        if authStatus == .denied || authStatus == .restricted {
            // Permission denied - disable location and use timezone fallback
            useLocation = false
            Ghostty.logger.info("SolarGraph location denied, using timezone fallback")
            return
        }

        do {
            _ = try await locationService.requestLocation()
            // Clear cached times to recalculate with new location
            cachedTimes = nil
            cachedDate = nil
            configurationDidChange.send()
        } catch {
            // Location failed, will use timezone fallback
            Ghostty.logger.info("SolarGraph using fallback location: \(error.localizedDescription)")
        }
    }

    /// Called when the effect becomes active - triggers initial location request
    @MainActor
    func onActivated() async {
        if useLocation {
            await refreshLocation()
        }
    }

    /// Get the best available location for solar calculations
    /// Uses device location if enabled, otherwise uses manual timezone estimate
    func getBestLocation() -> CLLocationCoordinate2D {
        if useLocation {
            // Use device location
            return locationService.getBestLocation()
        } else {
            // Location disabled (or denied) - use manual timezone
            let lat = SolarCalculator.estimatedLatitude(from: manualTimezone)
            let lon = SolarCalculator.estimatedLongitude(from: manualTimezone)
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    // MARK: - Solar Calculations

    /// Animation update interval based on speed setting
    var animationInterval: TimeInterval {
        if speed <= 1.0 {
            // Real-time mode: update every 30 seconds
            return 30.0
        } else {
            // Demo mode: 60 fps for smooth animation (30 in battery saver)
            return (1.0 / 60.0) * PowerManager.shared.effectIntervalScale
        }
    }

    /// Get solar times for today (cached)
    func getSolarTimes(for date: Date = Date()) -> SolarTimes {
        let calendar = Calendar.current

        // Check if we have valid cached times for today
        if let cached = cachedTimes,
           let cachedDay = cachedDate,
           calendar.isDate(cachedDay, inSameDayAs: date) {
            return cached
        }

        // Calculate new times using best available location
        let location = getBestLocation()
        let times = SolarCalculator.calculateTimes(
            date: date,
            latitude: location.latitude,
            longitude: location.longitude
        )

        // Cache for reuse
        cachedTimes = times
        cachedDate = date

        return times
    }

    /// Calculate day progress at a given time
    /// - Parameter date: The date/time to calculate for
    /// - Returns: Progress from 0 (sunrise) to 1 (sunset), clamped for arc position
    func calculateDayProgress(at date: Date) -> Double {
        if speed <= 1.0 {
            // Real-time mode: use actual solar position
            let times = getSolarTimes(for: date)
            return SolarCalculator.clampedDayProgress(date: date, times: times)
        } else {
            // Demo mode: synthetic accelerated cycle
            // This needs a reference start time from the view
            return 0.5 // Will be overridden by view
        }
    }

    /// Calculate solar data for rendering
    func calculateSolarData(progress: Double, at date: Date) -> SolarData {
        let times = getSolarTimes(for: date)

        // In demo mode, derive altitude from progress instead of real time
        let sunAltitude: Double
        let sunAzimuth: Double

        if speed > 1.0 {
            // Demo mode: synthetic altitude based on progress
            // Progress represents full 24-hour cycle: 0 = midnight, 0.5 = noon, 1 = midnight
            // Map to altitude: -90 at midnight, +60 at noon (using sine curve)
            let maxAltitude = 60.0   // Max altitude at noon
            let minAltitude = -18.0  // Min altitude at midnight (astronomical twilight boundary)

            // Sine wave centered at noon: sin((progress - 0.5) * 2pi) peaks at 0.5
            // But we want: 0 = midnight (low), 0.25 = sunrise, 0.5 = noon (high), 0.75 = sunset, 1 = midnight
            // Use: altitude = midpoint + amplitude * sin((progress - 0.25) * 2 * pi)
            let midpoint = (maxAltitude + minAltitude) / 2.0
            let amplitude = (maxAltitude - minAltitude) / 2.0
            sunAltitude = midpoint + amplitude * sin((progress - 0.25) * 2.0 * .pi)

            // Azimuth: 0 = north, 90 = east, 180 = south, 270 = west
            // At midnight = north (0), sunrise = east (90), noon = south (180), sunset = west (270)
            sunAzimuth = progress * 360.0
        } else {
            // Real-time mode: use actual sun position
            let location = getBestLocation()
            let position = SolarCalculator.calculatePosition(
                date: date,
                latitude: location.latitude,
                longitude: location.longitude
            )
            sunAltitude = position.altitude
            sunAzimuth = position.azimuth
        }

        let phase = SolarPhase(altitude: sunAltitude)

        return SolarData(
            dayProgress: progress,
            sunAltitude: sunAltitude,
            sunAzimuth: sunAzimuth,
            phase: phase,
            times: times,
            isNight: sunAltitude < -6
        )
    }

    // MARK: - Moon Calculations

    /// Calculate moon data for rendering
    /// - Parameters:
    ///   - date: The date for ephemeris calculations (real-time mode)
    ///   - progress: Day progress 0-1 (used in demo mode for positioning)
    func calculateMoonData(at date: Date, progress: Double) -> MoonData {
        let location = getBestLocation()

        if speed > 1.0 {
            // Demo mode: Use synthetic moon position for smooth animation
            // Use the same progress value as the sun to stay in sync
            return calculateDemoModeMoonData(progress: progress, simulatedDate: date)
        } else {
            // Real-time mode: actual moon position
            return MoonCalculator.calculateMoonData(
                date: date,
                latitude: location.latitude,
                longitude: location.longitude
            )
        }
    }

    /// Calculate synthetic moon data for demo mode
    /// Positions moon opposite to sun with smooth phase cycling
    /// - Parameters:
    ///   - progress: Day progress (0-1), same value used for sun positioning
    ///   - simulatedDate: The simulated date for phase calculations
    private func calculateDemoModeMoonData(progress: Double, simulatedDate: Date) -> MoonData {
        // Moon position: roughly opposite to sun in the sky
        // Sun at progress 0.5 (noon) = altitude 60°, azimuth 180° (south)
        // Moon should be high at night (progress ~0) and low during day

        // Moon altitude: high at midnight, low at noon (inverse of sun)
        let maxAltitude = 55.0
        let minAltitude = -20.0
        let midpoint = (maxAltitude + minAltitude) / 2.0
        let amplitude = (maxAltitude - minAltitude) / 2.0
        // Sun uses (progress - 0.25), so moon uses (progress + 0.25) to be opposite
        // At progress=0 (midnight): sin(π/2) = 1 → max altitude
        // At progress=0.5 (noon): sin(3π/2) = -1 → min altitude
        let moonAltitude = midpoint + amplitude * sin((progress + 0.25) * 2.0 * .pi)

        // Moon azimuth: opposite to sun (shifted by 180°)
        let moonAzimuth = (progress * 360.0 + 180.0).truncatingRemainder(dividingBy: 360.0)

        // Phase uses the (accelerated) simulated date so demo mode reflects the real lunar cycle
        // instead of always starting at a new moon.
        let phaseInfo = MoonCalculator.calculatePhase(date: simulatedDate)

        let position = MoonPosition(
            altitude: moonAltitude,
            azimuth: moonAzimuth,
            parallacticAngle: 0  // Simplified for demo
        )

        return MoonData(
            position: position,
            phaseInfo: phaseInfo,
            isAboveHorizon: moonAltitude > -5
        )
    }
}

// MARK: - Solar Data Model

/// Data needed for rendering the solar effect
struct SolarData {
    let dayProgress: Double      // 0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset, 1 = midnight
    let sunAltitude: Double      // Degrees above horizon
    let sunAzimuth: Double       // Degrees from north
    let phase: SolarPhase        // Current time phase
    let times: SolarTimes        // Today's solar times
    let isNight: Bool            // Sun below civil twilight

    /// Normalized altitude for color interpolation (0 = horizon, 1 = noon)
    var normalizedAltitude: Double {
        if sunAltitude < 0 {
            return 0
        }
        return min(sunAltitude / 90.0, 1.0)
    }

    /// How far into current phase (0 to 1)
    var phaseProgress: Double {
        switch phase {
        case .night:
            return max(0, min(1, (sunAltitude + 90) / 72)) // -90 to -18
        case .astronomicalTwilight:
            return max(0, min(1, (sunAltitude + 18) / 6))  // -18 to -12
        case .nauticalTwilight:
            return max(0, min(1, (sunAltitude + 12) / 6))  // -12 to -6
        case .civilTwilight:
            return max(0, min(1, (sunAltitude + 6) / 6))   // -6 to 0
        case .goldenHour:
            return max(0, min(1, sunAltitude / 6))         // 0 to 6
        case .day:
            return max(0, min(1, (sunAltitude - 6) / 84))  // 6 to 90
        }
    }
}

// MARK: - Solar Colors

extension SolarData {

    /// Sky gradient colors for current phase
    var skyGradientColors: (top: Color, bottom: Color) {
        switch phase {
        case .night:
            return (
                Color(red: 0.02, green: 0.02, blue: 0.05),
                Color(red: 0.05, green: 0.05, blue: 0.08)
            )

        case .astronomicalTwilight:
            let p = phaseProgress
            return (
                Color(red: 0.02 + 0.03 * p, green: 0.02 + 0.03 * p, blue: 0.05 + 0.10 * p),
                Color(red: 0.05 + 0.05 * p, green: 0.05 + 0.02 * p, blue: 0.08 + 0.12 * p)
            )

        case .nauticalTwilight:
            let p = phaseProgress
            return (
                Color(red: 0.05 + 0.10 * p, green: 0.05 + 0.07 * p, blue: 0.15 + 0.20 * p),
                Color(red: 0.10 + 0.30 * p, green: 0.07 + 0.15 * p, blue: 0.20 + 0.15 * p)
            )

        case .civilTwilight:
            let p = phaseProgress
            return (
                Color(red: 0.15 + 0.30 * p, green: 0.12 + 0.30 * p, blue: 0.35 + 0.20 * p),
                Color(red: 0.40 + 0.45 * p, green: 0.22 + 0.30 * p, blue: 0.35 - 0.10 * p)
            )

        case .goldenHour:
            let p = phaseProgress
            return (
                Color(red: 0.45 + 0.10 * p, green: 0.42 + 0.13 * p, blue: 0.55 + 0.30 * p),
                Color(red: 0.85 + 0.10 * p, green: 0.52 + 0.23 * p, blue: 0.25 + 0.20 * p)
            )

        case .day:
            let p = min(phaseProgress, 1.0)
            return (
                Color(red: 0.35 + 0.05 * p, green: 0.55 + 0.05 * p, blue: 0.85 + 0.05 * p),
                Color(red: 0.55 + 0.10 * p, green: 0.70 + 0.08 * p, blue: 0.90 + 0.05 * p)
            )
        }
    }

    /// Sun color for current phase
    var sunColor: Color {
        switch phase {
        case .night, .astronomicalTwilight:
            return .clear

        case .nauticalTwilight:
            return Color(red: 1.0, green: 0.5, blue: 0.3).opacity(phaseProgress * 0.5)

        case .civilTwilight:
            return Color(red: 1.0, green: 0.55 + 0.10 * phaseProgress, blue: 0.3 + 0.15 * phaseProgress)

        case .goldenHour:
            return Color(red: 1.0, green: 0.65 + 0.20 * phaseProgress, blue: 0.45 + 0.25 * phaseProgress)

        case .day:
            return Color(red: 1.0, green: 0.95 + 0.03 * phaseProgress, blue: 0.85 + 0.10 * phaseProgress)
        }
    }

    /// Horizon glow color and intensity
    var horizonGlow: (color: Color, intensity: Double) {
        switch phase {
        case .night:
            return (.clear, 0)

        case .astronomicalTwilight:
            return (Color(red: 0.15, green: 0.08, blue: 0.25), phaseProgress * 0.2)

        case .nauticalTwilight:
            return (Color(red: 0.6, green: 0.3, blue: 0.2), 0.2 + phaseProgress * 0.3)

        case .civilTwilight:
            return (Color(red: 1.0, green: 0.5, blue: 0.2), 0.5 + phaseProgress * 0.3)

        case .goldenHour:
            // Peak glow at golden hour
            return (Color(red: 1.0, green: 0.7, blue: 0.3), 0.8 - phaseProgress * 0.4)

        case .day:
            return (Color(red: 1.0, green: 0.95, blue: 0.8), 0.15 - phaseProgress * 0.10)
        }
    }

    /// Sun visibility (for fading at horizon)
    var sunVisibility: Double {
        switch phase {
        case .night, .astronomicalTwilight:
            return 0
        case .nauticalTwilight:
            return phaseProgress * 0.5
        case .civilTwilight:
            return 0.5 + phaseProgress * 0.5
        case .goldenHour, .day:
            return 1.0
        }
    }
}
