// LiveWeatherEffect.swift
// rootshell

#if !CHINA_BUILD
import SwiftUI
import Combine

final class LiveWeatherEffect: TerminalEffect, ObservableObject {
    let id = "liveWeather"
    let displayName = String(localized: "Live Weather", comment: "Background effect name")
    let previewIcon = "cloud.sun.rain.fill"
    let effectDescription = String(localized: "The sky and weather outside, following the day", comment: "Live Weather effect description")
    let configurationDidChange = PassthroughSubject<Void, Never>()
    let objectWillChange = ObservableObjectPublisher()

    private var storedConfiguration = LiveWeatherConfiguration()
    var configuration: LiveWeatherConfiguration {
        get { storedConfiguration }
        set {
            let value = newValue.sanitized()
            guard value != storedConfiguration else { return }
            objectWillChange.send()
            storedConfiguration = value
            configurationDidChange.send()
        }
    }
    var intensity: Double {
        get { configuration.intensity }
        set { configuration.intensity = newValue }
    }
    /// Weather moves at its own pace; the shared Speed control is hidden.
    var speed: Double {
        get { 1 }
        set {}
    }
    var themeColors: EffectThemeColors = .defaults {
        willSet { if newValue != themeColors { objectWillChange.send() } }
    }
    /// Matches EffectManager.isLightTheme, which picks the host blend mode.
    var isLightBackground: Bool {
        Color(hex: themeColors.background)?.isLight ?? false
    }

    // Demo previews for tuning; never persisted or synced.
    var previewCondition: WeatherConditionKind? {
        willSet { if newValue != previewCondition { objectWillChange.send() } }
    }
    var previewTime: WeatherSkyGeometry.PreviewTime? {
        willSet { if newValue != previewTime { objectWillChange.send() } }
    }

    func onActivated() {
        if configuration.locationSource == .device { WeatherStore.shared.requestLocationPermission() }
    }

    func createEffectView() -> AnyView { AnyView(LiveWeatherView(effect: self)) }
    func resetToDefaults() {
        configuration = LiveWeatherConfiguration()
        previewCondition = nil
        previewTime = nil
    }
    func encodeConfiguration() -> [String: Any] { configuration.dictionary }
    func decodeConfiguration(_ data: [String: Any]) { configuration = .decode(data) }
}
#endif
