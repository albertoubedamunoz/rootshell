//
//  PaddingManager.swift
//  rootshell
//
//  Centralized padding calculations for terminal content.
//  Ensures consistent spacing between text and edges/toolbars across all contexts.
//

import Foundation
import UIKit
import os

/// Manages padding calculations for terminal content.
/// Provides proportional padding based on cell/font size for visual consistency
/// and user-overridable window padding for the Ghostty config.
@MainActor
@Observable
final class PaddingManager {
    static let shared = PaddingManager()

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.rootshell", category: "PaddingManager")

    private static let ownedKeys: Set<String> = [
        Settings.Terminal.paddingXOverride.name,
        Settings.Terminal.paddingYOverride.name,
        Settings.Window.extendUnderHomeIndicator.name,
    ]

    private static let allowedRange: ClosedRange<Int> = 0...32

    /// Ghostty insets the grid by padding × 96/72 points (see
    /// MainView.terminalTopGridAlignmentPadding).
    private static let pointsPerPaddingUnit: CGFloat = 96.0 / 72.0

    /// Padding (4pt inset) that keeps the first cell inside a Rounded Panes
    /// card corner; applied only when the user's padding would not.
    static let roundedPanesMinimum = 3

    /// Mirrors Settings.Window.roundedPanes for the effective-padding floor.
    private(set) var roundedPanes: Bool

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    /// User override for horizontal window padding. nil means use the platform default.
    var paddingXOverride: Int? {
        didSet {
            guard paddingXOverride != oldValue, !isReloading else { return }
            persist(paddingXOverride, for: Settings.Terminal.paddingXOverride)
        }
    }

    /// User override for vertical window padding. nil means use the platform default.
    var paddingYOverride: Int? {
        didSet {
            guard paddingYOverride != oldValue, !isReloading else { return }
            persist(paddingYOverride, for: Settings.Terminal.paddingYOverride)
        }
    }

    /// Master switch for the home-indicator bottom reservation.
    ///
    /// Default (false) reserves the home-indicator strip in every mode (including
    /// Full Screen), keeping a touch-safe gap so the system home-swipe gesture
    /// doesn't intercept touches meant for text selection near the bottom edge.
    /// When true the terminal runs edge-to-edge (flush) with no reservation. Only
    /// meaningful — and only surfaced in Settings — on devices with a home indicator.
    var extendUnderHomeIndicator: Bool {
        didSet {
            guard extendUnderHomeIndicator != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Window.extendUnderHomeIndicator, extendUnderHomeIndicator) }
            NotificationCenter.default.post(name: .terminalBottomInsetInvalidated, object: nil)
        }
    }

    private init() {
        let store = SettingsStore.shared
        self.paddingXOverride = store.get(Settings.Terminal.paddingXOverride)
        self.paddingYOverride = store.get(Settings.Terminal.paddingYOverride)
        self.extendUnderHomeIndicator = store.get(Settings.Window.extendUnderHomeIndicator)
        self.roundedPanes = store.get(Settings.Window.roundedPanes)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
        // Any origin: a local toggle never reaches the refresh hub.
        _ = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncRoundedPanes() }
        }
    }

    private func syncRoundedPanes() {
        let rounded = SettingsStore.shared.get(Settings.Window.roundedPanes)
        guard rounded != roundedPanes else { return }
        let before = (effectivePaddingX, effectivePaddingY)
        roundedPanes = rounded
        guard before != (effectivePaddingX, effectivePaddingY) else { return }
        // Regenerating the config file carries the new window-padding-x/y.
        if let app = Ghostty.App.shared,
           app.config.setFontSize(Int(FontManager.shared.currentFontSize)) {
            app.pushGlobalConfigToApp()
        }
    }

    private func persist(_ value: Int?, for key: SettingKey<Int?>) {
        if let value {
            SettingsStore.shared.set(key, value)
        } else {
            SettingsStore.shared.reset(key)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Terminal.paddingXOverride.name) { paddingXOverride = store.get(Settings.Terminal.paddingXOverride) }
        if keys.contains(Settings.Terminal.paddingYOverride.name) { paddingYOverride = store.get(Settings.Terminal.paddingYOverride) }
        if keys.contains(Settings.Window.extendUnderHomeIndicator.name) {
            extendUnderHomeIndicator = store.get(Settings.Window.extendUnderHomeIndicator)
        }
    }

    // MARK: - Defaults

    /// Platform-tuned default horizontal padding.
    /// Catalyst windows have larger rounded corner masks; phones stay snug.
    var defaultPaddingX: Int {
#if targetEnvironment(macCatalyst)
        return 10
#else
        return UIDevice.current.userInterfaceIdiom == .phone ? 6 : 8
#endif
    }

    /// Platform-tuned default vertical padding.
    var defaultPaddingY: Int {
#if targetEnvironment(macCatalyst)
        return 6
#else
        return UIDevice.current.userInterfaceIdiom == .phone ? 3 : 4
#endif
    }

    /// The user's chosen padding (override or platform default).
    var userPaddingX: Int { paddingXOverride ?? defaultPaddingX }
    var userPaddingY: Int { paddingYOverride ?? defaultPaddingY }

    /// Padding Ghostty and the multiplexer size math use: the user's choice,
    /// raised to the Rounded Panes floor when cards clip the corners.
    var effectivePaddingX: Int { roundedPanesRaisesPadding ? max(userPaddingX, Self.roundedPanesMinimum) : userPaddingX }
    var effectivePaddingY: Int { roundedPanesRaisesPadding ? max(userPaddingY, Self.roundedPanesMinimum) : userPaddingY }

    /// True when the first cell's corner would fall outside the card's curve.
    /// The 1pt radius margin covers the continuous corner shape.
    var roundedPanesRaisesPadding: Bool {
        guard roundedPanes else { return false }
        let radius = PaneCardStyle.cornerRadius + 1
        let dx = max(0, radius - CGFloat(userPaddingX) * Self.pointsPerPaddingUnit)
        let dy = max(0, radius - CGFloat(userPaddingY) * Self.pointsPerPaddingUnit)
        return dx * dx + dy * dy > radius * radius
    }

    /// True when the user has set an override on either axis.
    var isCustom: Bool { paddingXOverride != nil || paddingYOverride != nil }

    // MARK: - Mutation

    func setPaddingX(_ value: Int) {
        paddingXOverride = clamp(value)
    }

    func setPaddingY(_ value: Int) {
        paddingYOverride = clamp(value)
    }

    func resetToDefaults() {
        paddingXOverride = nil
        paddingYOverride = nil
    }

    private func clamp(_ value: Int) -> Int {
        min(max(value, Self.allowedRange.lowerBound), Self.allowedRange.upperBound)
    }

    // MARK: - Proportional Padding

    /// Calculate padding proportional to cell height.
    /// This ensures consistent visual spacing at any font size.
    /// - Parameter cellHeight: The cell height (typically fontSize * 1.2)
    /// - Returns: Padding in points
    func proportionalPadding(cellHeight: CGFloat) -> CGFloat {
        // Use ~40% of cell height as padding
        // At 13pt font (~15.6pt cell), this gives ~6pt
        // At 10pt font (~12pt cell), this gives ~5pt
        // At 18pt font (~21.6pt cell), this gives ~9pt
        let padding = cellHeight * 0.4

        // Clamp to reasonable range: min 4pt, max 12pt
        return min(max(padding, 4), 12)
    }

    /// Calculate Ghostty config padding values.
    /// Returns the user-overridden values when set, otherwise platform defaults
    /// chosen to keep text clear of rounded corners.
    ///
    /// Keep balance disabled so the grid stays pinned to the explicit top-left
    /// padding. Balanced padding redistributes the sub-cell remainder across both
    /// edges, which adds a top gap (content sits lower) and drifts the text during
    /// live resize.
    /// - Returns: Tuple of (x, y, balance) for window padding config keys.
    func configPadding() -> (x: Int, y: Int, balance: Bool) {
        return (effectivePaddingX, effectivePaddingY, false)
    }
}
