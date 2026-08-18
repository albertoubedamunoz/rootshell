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

    // MARK: - UserDefaults Keys

    private static let paletteGenerateKey = "paletteGenerate"
    private static let paletteHarmoniousKey = "paletteHarmonious"

    // MARK: - Observable Properties

    var paletteGenerateEnabled: Bool {
        didSet {
            UserDefaults.standard.set(paletteGenerateEnabled, forKey: Self.paletteGenerateKey)
            NotificationCenter.default.post(name: .paletteConfigChanged, object: nil)
        }
    }

    var paletteHarmoniousEnabled: Bool {
        didSet {
            UserDefaults.standard.set(paletteHarmoniousEnabled, forKey: Self.paletteHarmoniousKey)
            NotificationCenter.default.post(name: .paletteConfigChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        self.paletteGenerateEnabled = UserDefaults.standard.bool(forKey: Self.paletteGenerateKey)
        self.paletteHarmoniousEnabled = UserDefaults.standard.bool(forKey: Self.paletteHarmoniousKey)
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
