import Foundation
import Combine

/// Manages window transparency settings (Mac Catalyst only).
///
/// Migrated from `ObservableObject + @Published` to `@Observable` so SwiftUI
/// tracks per-property reads — slider drags on `backgroundOpacity` no longer
/// invalidate views that only read `blurEnabled` (and vice-versa).
@MainActor
@Observable
final class TransparencyManager {
    static let shared = TransparencyManager()

    /// Toggle for sandbox mode blur implementation
    /// true  = NSVisualEffectView (App Store safe, no custom radius)
    /// false = private CGS API (non-sandbox, supports custom radius)
    #if APPSTORE
    static let useSandboxBlur = true
    #else
    static let useSandboxBlur = false
    #endif

    /// How the window background behind the terminal is blurred.
    enum BlurStyle: String, CaseIterable, Identifiable {
        /// CGS radius blur (Standalone) or NSVisualEffectView (App Store).
        case standard
        /// macOS 26 Liquid Glass (NSGlassEffectView).
        case glassRegular
        case glassClear

        var id: String { rawValue }

        /// Value emitted for ghostty's `background-blur`; nil means numeric radius.
        var ghosttyConfigValue: String? {
            switch self {
            case .standard: return nil
            case .glassRegular: return "macos-glass-regular"
            case .glassClear: return "macos-glass-clear"
            }
        }

        var title: String {
            switch self {
            case .standard: return String(localized: "Standard")
            case .glassRegular: return String(localized: "Glass")
            case .glassClear: return String(localized: "Clear Glass")
            }
        }
    }

    /// Liquid Glass needs macOS or iOS 26; Catalyst's version tracks macOS 26 exactly.
    static var isGlassAvailable: Bool {
        #if os(visionOS)
        return false
        #else
        if #available(iOS 26.0, macCatalyst 26.0, *) { return true }
        return false
        #endif
    }

    private static let ownedKeys: Set<String> = [
        Settings.Transparency.backgroundOpacity.name, Settings.Transparency.backgroundBlurRadius.name,
        Settings.Transparency.blurEnabled.name, Settings.Transparency.blurStyle.name,
        Settings.Transparency.pinnedSidebarTransparency.name, Settings.Transparency.backdropTransparency.name,
    ]
    private static let defaultBackgroundOpacity: Double = 0.92
    private static let defaultBackgroundBlurRadius: Double = 30.0
    private static let defaultBlurEnabled: Bool = true
    private static let defaultBlurStyle: BlurStyle = .standard
    private static let defaultPinnedSidebarTransparencyEnabled: Bool = false
    private static let defaultBackdropTransparencyEnabled: Bool = true

    /// Current background opacity (0.0 = fully transparent, 1.0 = opaque)
    var backgroundOpacity: Double {
        didSet {
            guard backgroundOpacity != oldValue else { return }
            saveBackgroundOpacity()
            transparencyDidChange.send()
        }
    }

    /// Current background blur radius (0 = no blur, higher = more blur)
    /// Only used in non-sandbox mode (private CGS API)
    var backgroundBlurRadius: Double {
        didSet {
            guard backgroundBlurRadius != oldValue else { return }
            saveBackgroundBlurRadius()
            transparencyDidChange.send()
        }
    }

    /// Whether blur is enabled (sandbox mode only - simple on/off toggle)
    var blurEnabled: Bool {
        didSet {
            guard blurEnabled != oldValue else { return }
            saveBlurEnabled()
            transparencyDidChange.send()
        }
    }

    /// Stored blur style preference. Consumers should read `effectiveBlurStyle`.
    var blurStyle: BlurStyle {
        didSet {
            guard blurStyle != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Transparency.blurStyle, blurStyle) }
            transparencyDidChange.send()
        }
    }

    /// `blurStyle` downgraded to `.standard` where glass isn't available.
    var effectiveBlurStyle: BlurStyle {
        Self.isGlassAvailable ? blurStyle : .standard
    }

    var usesGlass: Bool { effectiveBlurStyle != .standard }

    /// Opacity the terminal draws at. Off the Mac only the Theme Gradient
    /// backdrop can show through, so opacity applies just while it is on.
    var effectiveBackgroundOpacity: Double {
        #if targetEnvironment(macCatalyst)
        return backgroundOpacity
        #else
        return EffectManager.shared.isBackdropEnabled ? backgroundOpacity : 1.0
        #endif
    }

    /// Whether the pinned vertical tab sidebar uses the window's background
    /// opacity instead of its normal opaque fill.
    var pinnedSidebarTransparencyEnabled: Bool {
        didSet {
            guard pinnedSidebarTransparencyEnabled != oldValue, !isReloading else { return }
            SettingsStore.shared.set(Settings.Transparency.pinnedSidebarTransparency, pinnedSidebarTransparencyEnabled)
        }
    }

    /// Mac only: whether the Theme Gradient backdrop takes the window opacity
    /// too, showing the desktop through it instead of only through the terminal.
    var backdropTransparencyEnabled: Bool {
        didSet {
            guard backdropTransparencyEnabled != oldValue, !isReloading else { return }
            SettingsStore.shared.set(Settings.Transparency.backdropTransparency, backdropTransparencyEnabled)
        }
    }

    /// Opacity the Theme Gradient backdrop draws at.
    var effectiveBackdropOpacity: Double {
        #if targetEnvironment(macCatalyst)
        return backdropTransparencyEnabled ? backgroundOpacity : 1.0
        #else
        return 1.0
        #endif
    }

    /// Set while `reload(keys:)` re-assigns properties so didSet skips the store write.
    @ObservationIgnored private var isReloading = false

    /// Whether transparency is currently disabled (forced to 1.0)
    /// Used by toggle transparency keyboard shortcut
    private(set) var isTransparencyDisabled: Bool = false

    /// Saved opacity when transparency is toggled off
    @ObservationIgnored private var savedOpacity: Double?

    /// Publisher that emits when transparency settings change
    @ObservationIgnored let transparencyDidChange = PassthroughSubject<Void, Never>()

    private init() {
        self.backgroundOpacity = Self.storedBackgroundOpacity()
        self.backgroundBlurRadius = SettingsStore.shared.get(Settings.Transparency.backgroundBlurRadius)
        self.blurEnabled = SettingsStore.shared.get(Settings.Transparency.blurEnabled)
        self.blurStyle = SettingsStore.shared.get(Settings.Transparency.blurStyle)
        self.pinnedSidebarTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.pinnedSidebarTransparency)
        self.backdropTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.backdropTransparency)
        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// A stored opacity of 0 (or less) falls back to the default.
    private static func storedBackgroundOpacity() -> Double {
        let saved = SettingsStore.shared.get(Settings.Transparency.backgroundOpacity)
        return saved > 0 ? saved : defaultBackgroundOpacity
    }

    /// Re-read owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Transparency.backgroundOpacity.name) {
            backgroundOpacity = Self.storedBackgroundOpacity()
        }
        if keys.contains(Settings.Transparency.backgroundBlurRadius.name) {
            backgroundBlurRadius = SettingsStore.shared.get(Settings.Transparency.backgroundBlurRadius)
        }
        if keys.contains(Settings.Transparency.blurEnabled.name) {
            blurEnabled = SettingsStore.shared.get(Settings.Transparency.blurEnabled)
        }
        if keys.contains(Settings.Transparency.blurStyle.name) {
            blurStyle = SettingsStore.shared.get(Settings.Transparency.blurStyle)
        }
        if keys.contains(Settings.Transparency.pinnedSidebarTransparency.name) {
            pinnedSidebarTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.pinnedSidebarTransparency)
        }
        if keys.contains(Settings.Transparency.backdropTransparency.name) {
            backdropTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.backdropTransparency)
        }
    }

    private func saveBackgroundOpacity() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Transparency.backgroundOpacity, backgroundOpacity)
    }

    private func saveBackgroundBlurRadius() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Transparency.backgroundBlurRadius, backgroundBlurRadius)
    }

    private func saveBlurEnabled() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Transparency.blurEnabled, blurEnabled)
    }

    /// Reset to default transparency settings
    func resetToDefaults() {
        backgroundOpacity = Self.defaultBackgroundOpacity
        backgroundBlurRadius = Self.defaultBackgroundBlurRadius
        blurEnabled = Self.defaultBlurEnabled
        blurStyle = Self.defaultBlurStyle
        pinnedSidebarTransparencyEnabled = Self.defaultPinnedSidebarTransparencyEnabled
        backdropTransparencyEnabled = Self.defaultBackdropTransparencyEnabled
    }

    /// Toggle transparency on/off (Mac Catalyst only)
    /// When toggling off, saves current opacity and sets to fully opaque.
    /// When toggling on, restores the saved opacity value.
    func toggleTransparency() {
        if isTransparencyDisabled {
            // Restore saved opacity
            if let saved = savedOpacity {
                backgroundOpacity = saved
            }
            isTransparencyDisabled = false
        } else {
            // Save current opacity and set to fully opaque
            savedOpacity = backgroundOpacity
            backgroundOpacity = 1.0
            isTransparencyDisabled = true
        }
    }
}
