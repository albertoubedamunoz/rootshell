//
//  PaletteManager.swift
//  rootshell
//
//  Manages palette generation settings (palette-generate, palette-harmonious)
//

import Foundation

extension Notification.Name {
    static let paletteConfigChanged = Notification.Name("paletteConfigChanged")
}

@MainActor
@Observable
class PaletteManager {
    static let shared = PaletteManager()

    // MARK: - Observable Properties

    var paletteGenerateEnabled: Bool {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Palette.generate, paletteGenerateEnabled) }
            NotificationCenter.default.post(name: .paletteConfigChanged, object: nil)
        }
    }

    var paletteHarmoniousEnabled: Bool {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Palette.harmonious, paletteHarmoniousEnabled) }
            NotificationCenter.default.post(name: .paletteConfigChanged, object: nil)
        }
    }

    @ObservationIgnored private var isReloading = false

    // MARK: - Initialization

    private init() {
        self.paletteGenerateEnabled = SettingsStore.shared.get(Settings.Palette.generate)
        self.paletteHarmoniousEnabled = SettingsStore.shared.get(Settings.Palette.harmonious)
        SettingsRefreshHub.shared.register(
            keys: [Settings.Palette.generate.name, Settings.Palette.harmonious.name]
        ) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-read owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Palette.generate.name) {
            paletteGenerateEnabled = SettingsStore.shared.get(Settings.Palette.generate)
        }
        if keys.contains(Settings.Palette.harmonious.name) {
            paletteHarmoniousEnabled = SettingsStore.shared.get(Settings.Palette.harmonious)
        }
    }

    // MARK: - Config Generation

    func generatePaletteConfigLines() -> [String] {
        var lines: [String] = []
        lines.append("palette-generate = \(paletteGenerateEnabled)")
        if paletteGenerateEnabled {
            lines.append("palette-harmonious = \(paletteHarmoniousEnabled)")
        }
        return lines
    }
}
