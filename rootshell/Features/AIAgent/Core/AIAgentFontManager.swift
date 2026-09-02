#if !CHINA_BUILD
//
//  AIAgentFontManager.swift
//  rootshell
//
//  Manages text size settings for the AI Agent chat interface.
//  Provides in-app control for text scaling independent of system Dynamic Type.
//

import Foundation
import Combine
import UIKit

/// Manages text size settings for AI Agent chat views
@MainActor
class AIAgentFontManager: ObservableObject {
    static let shared = AIAgentFontManager()

    // MARK: - Keys

    private static let defaultTextSize: Double = 14.0
    private static let minTextSize: Double = 10.0
    private static let maxTextSize: Double = 24.0

    // MARK: - Published Properties

    /// Currently selected text size for AI Agent chat
    @Published var textSize: Double {
        didSet {
            if !isReloading { saveTextSize() }
            textSizeDidChange.send(textSize)
        }
    }

    private var isReloading = false

    // MARK: - Publishers

    /// Published when text size changes - views can subscribe to update
    let textSizeDidChange = PassthroughSubject<Double, Never>()

    // MARK: - Computed Properties

    /// Text size range for slider
    var textSizeRange: ClosedRange<Double> {
        Self.minTextSize...Self.maxTextSize
    }

    /// Default text size
    var defaultTextSize: Double {
        Self.defaultTextSize
    }

    /// Scaling factor relative to default (1.0 = default)
    var scaleFactor: CGFloat {
        CGFloat(textSize / Self.defaultTextSize)
    }

    // MARK: - Initialization

    private init() {
        self.textSize = Self.storedTextSize
        SettingsRefreshHub.shared.register(keys: [Settings.AI.textSize.name]) { [weak self] _ in
            self?.reload()
        }
    }

    // MARK: - Persistence

    private static var storedTextSize: Double {
        let savedSize = SettingsStore.shared.get(Settings.AI.textSize)
        return savedSize > 0 ? savedSize : defaultTextSize
    }

    private func saveTextSize() {
        SettingsStore.shared.set(Settings.AI.textSize, textSize)
    }

    private func reload() {
        isReloading = true
        defer { isReloading = false }
        textSize = Self.storedTextSize
    }

    // MARK: - Actions

    /// Reset text size to default
    func resetToDefault() {
        textSize = Self.defaultTextSize
    }

    // MARK: - Font Creation

    /// Create a monospaced UIFont at the current text size
    func monospacedFont(weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(textSize), weight: weight)
    }

    /// Create a scaled header font for markdown
    func headerFont(level: Int) -> UIFont {
        let baseSize: CGFloat
        switch level {
        case 1: baseSize = CGFloat(textSize) * 1.43  // ~20pt at default 14
        case 2: baseSize = CGFloat(textSize) * 1.29  // ~18pt at default 14
        case 3: baseSize = CGFloat(textSize) * 1.14  // ~16pt at default 14
        default: baseSize = CGFloat(textSize) * 1.07 // ~15pt at default 14
        }
        return UIFont.monospacedSystemFont(ofSize: baseSize, weight: .bold)
    }
}
#endif
