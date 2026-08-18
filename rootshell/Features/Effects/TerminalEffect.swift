//
//  TerminalEffect.swift
//  rootshell
//
//  Protocol defining the interface for terminal visual effects
//

import SwiftUI
import Combine

/// Theme colors passed to effects from ThemeManager
struct EffectThemeColors: Equatable {
    let background: String    // Hex color
    let foreground: String    // Hex color
    let cursor: String        // Hex color
    let palette: [String]     // Palette colors (up to 16)

    /// Create from ThemeManager.ThemeInfo.ThemeColors
    init(from themeColors: ThemeManager.ThemeInfo.ThemeColors) {
        self.background = themeColors.background
        self.foreground = themeColors.foreground
        self.cursor = themeColors.cursor
        self.palette = themeColors.palette
    }

    /// Default colors for when no theme is available
    static let defaults = EffectThemeColors(
        background: "#1e1e2e",
        foreground: "#cdd6f4",
        cursor: "#f5e0dc",
        palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#cba6f7", "#94e2d5", "#bac2de"]
    )

    private init(background: String, foreground: String, cursor: String, palette: [String]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.palette = palette
    }
}

/// Protocol defining the interface for all terminal visual effects
protocol TerminalEffect: AnyObject, Identifiable {
    /// Unique identifier for this effect type
    var id: String { get }

    /// Human-readable display name
    var displayName: String { get }

    /// SF Symbol name for preview icon
    var previewIcon: String { get }

    /// Short description for UI
    var effectDescription: String { get }

    /// Effect intensity (0.0 = invisible, 1.0 = maximum)
    var intensity: Double { get set }

    /// Animation speed multiplier (0.5 = half speed, 2.0 = double speed)
    var speed: Double { get set }

    /// Theme colors for the effect
    var themeColors: EffectThemeColors { get set }

    /// Publisher for when effect configuration changes
    var configurationDidChange: PassthroughSubject<Void, Never> { get }

    /// Create the SwiftUI view for this effect
    func createEffectView() -> AnyView

    /// Reset to default configuration
    func resetToDefaults()

    /// Encode current configuration for persistence
    func encodeConfiguration() -> [String: Any]

    /// Restore configuration from persisted data
    func decodeConfiguration(_ data: [String: Any])
}

/// Default implementation for id based on type name
extension TerminalEffect {
    var id: String { String(describing: type(of: self)) }
}

/// Type-erased wrapper for TerminalEffect to use in collections
final class AnyTerminalEffect: Identifiable, ObservableObject {
    let id: String
    let displayName: String
    let previewIcon: String
    let effectDescription: String

    /// The underlying effect instance (type-erased)
    private let underlyingEffect: Any

    private let _getIntensity: () -> Double
    private let _setIntensity: (Double) -> Void
    private let _getSpeed: () -> Double
    private let _setSpeed: (Double) -> Void
    private let _getThemeColors: () -> EffectThemeColors
    private let _setThemeColors: (EffectThemeColors) -> Void
    private let _createEffectView: () -> AnyView
    private let _resetToDefaults: () -> Void
    private let _encodeConfiguration: () -> [String: Any]
    private let _decodeConfiguration: ([String: Any]) -> Void
    private let _configurationDidChange: PassthroughSubject<Void, Never>

    private var cancellable: AnyCancellable?

    var intensity: Double {
        get { _getIntensity() }
        set { _setIntensity(newValue) }
    }

    var speed: Double {
        get { _getSpeed() }
        set { _setSpeed(newValue) }
    }

    var themeColors: EffectThemeColors {
        get { _getThemeColors() }
        set { _setThemeColors(newValue) }
    }

    var configurationDidChange: PassthroughSubject<Void, Never> {
        _configurationDidChange
    }

    init<E: TerminalEffect>(_ effect: E) {
        self.id = effect.id
        self.displayName = effect.displayName
        self.previewIcon = effect.previewIcon
        self.effectDescription = effect.effectDescription
        self.underlyingEffect = effect

        self._getIntensity = { effect.intensity }
        self._setIntensity = { effect.intensity = $0 }
        self._getSpeed = { effect.speed }
        self._setSpeed = { effect.speed = $0 }
        self._getThemeColors = { effect.themeColors }
        self._setThemeColors = { effect.themeColors = $0 }
        self._createEffectView = { effect.createEffectView() }
        self._resetToDefaults = { effect.resetToDefaults() }
        self._encodeConfiguration = { effect.encodeConfiguration() }
        self._decodeConfiguration = { effect.decodeConfiguration($0) }
        self._configurationDidChange = effect.configurationDidChange

        // Forward configuration changes to objectWillChange
        cancellable = effect.configurationDidChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Access the underlying effect instance, cast to the specified type
    func asEffect<E: TerminalEffect>(_ type: E.Type) -> E? {
        underlyingEffect as? E
    }

    func createEffectView() -> AnyView {
        _createEffectView()
    }

    func resetToDefaults() {
        _resetToDefaults()
    }

    func encodeConfiguration() -> [String: Any] {
        _encodeConfiguration()
    }

    func decodeConfiguration(_ data: [String: Any]) {
        _decodeConfiguration(data)
    }
}
