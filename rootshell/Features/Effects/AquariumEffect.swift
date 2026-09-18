// AquariumEffect.swift
// rootshell

import SwiftUI
import Combine
import UIKit

final class AquariumEffect: TerminalEffect, ObservableObject {
    let id = "aquarium"
    let displayName = String(localized: "Aquarium", comment: "Background effect name")
    let previewIcon = "fish.fill"
    let effectDescription = String(localized: "A living reef with schooling fish, swaying kelp, and underwater light", comment: "Aquarium effect description")
    let configurationDidChange = PassthroughSubject<Void, Never>()
    let objectWillChange = ObservableObjectPublisher()

    private static var defaultConfiguration: AquariumConfiguration {
        AquariumConfiguration(fishCount: UIDevice.current.userInterfaceIdiom == .phone ? 3 : 8)
    }

    private var storedConfiguration = AquariumEffect.defaultConfiguration
    var configuration: AquariumConfiguration {
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
    var speed: Double {
        get { configuration.speed }
        set { configuration.speed = newValue }
    }
    var themeColors: EffectThemeColors = .defaults {
        willSet { if newValue != themeColors { objectWillChange.send() } }
        // Theme updates redraw the view, but are not user configuration writes.
    }
    var aquariumPalette: AquariumPalette {
        .make(configuration: configuration, background: themeColors.background, palette: themeColors.palette)
    }
    func createEffectView() -> AnyView { AnyView(AquariumView(effect: self)) }
    func resetToDefaults() { configuration = Self.defaultConfiguration }
    func encodeConfiguration() -> [String: Any] { configuration.dictionary }
    func decodeConfiguration(_ data: [String: Any]) {
        configuration = .decode(data, defaults: Self.defaultConfiguration)
    }
}
