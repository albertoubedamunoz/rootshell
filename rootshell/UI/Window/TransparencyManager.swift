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

    /// Liquid Glass needs macOS 26; Catalyst's version tracks macOS 26 exactly.
    static var isGlassAvailable: Bool {
        if #available(macCatalyst 26.0, *) { return true }
        return false
    }

    private static let backgroundOpacityKey = "backgroundOpacity"
    private static let backgroundBlurRadiusKey = "backgroundBlurRadius"
    private static let blurEnabledKey = "blurEnabled"
    private static let blurStyleKey = "blurStyle"
    private static let pinnedSidebarTransparencyEnabledKey = "pinnedSidebarTransparencyEnabled"
    private static let defaultBackgroundOpacity: Double = 0.92
    private static let defaultBackgroundBlurRadius: Double = 30.0
    private static let defaultBlurEnabled: Bool = true
    private static let defaultBlurStyle: BlurStyle = .standard
    private static let defaultPinnedSidebarTransparencyEnabled: Bool = false

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
            UserDefaults.standard.set(blurStyle.rawValue, forKey: Self.blurStyleKey)
            transparencyDidChange.send()
        }
    }

    /// `blurStyle` downgraded to `.standard` where glass isn't available.
    var effectiveBlurStyle: BlurStyle {
        Self.isGlassAvailable ? blurStyle : .standard
    }

    var usesGlass: Bool { effectiveBlurStyle != .standard }

    /// Whether the pinned vertical tab sidebar uses the window's background
    /// opacity instead of its normal opaque fill.
    var pinnedSidebarTransparencyEnabled: Bool {
        didSet {
            guard pinnedSidebarTransparencyEnabled != oldValue else { return }
            UserDefaults.standard.set(
                pinnedSidebarTransparencyEnabled,
                forKey: Self.pinnedSidebarTransparencyEnabledKey
            )
        }
    }

    /// Whether transparency is currently disabled (forced to 1.0)
    /// Used by toggle transparency keyboard shortcut
    private(set) var isTransparencyDisabled: Bool = false

    /// Saved opacity when transparency is toggled off
    @ObservationIgnored private var savedOpacity: Double?

    /// Publisher that emits when transparency settings change
    @ObservationIgnored let transparencyDidChange = PassthroughSubject<Void, Never>()

    private init() {
        // Load saved opacity or default to 0.92
        let savedOpacity = UserDefaults.standard.double(forKey: Self.backgroundOpacityKey)
        if savedOpacity > 0 {
            self.backgroundOpacity = savedOpacity
        } else {
            self.backgroundOpacity = Self.defaultBackgroundOpacity
        }

        // Load saved blur radius or default to 30
        // Note: Must check if key exists, since double(forKey:) returns 0 when key is missing
        if UserDefaults.standard.object(forKey: Self.backgroundBlurRadiusKey) != nil {
            self.backgroundBlurRadius = UserDefaults.standard.double(forKey: Self.backgroundBlurRadiusKey)
        } else {
            self.backgroundBlurRadius = Self.defaultBackgroundBlurRadius
        }

        // Load saved blur enabled state or default to true
        if UserDefaults.standard.object(forKey: Self.blurEnabledKey) != nil {
            self.blurEnabled = UserDefaults.standard.bool(forKey: Self.blurEnabledKey)
        } else {
            self.blurEnabled = Self.defaultBlurEnabled
        }

        self.blurStyle = UserDefaults.standard.string(forKey: Self.blurStyleKey)
            .flatMap(BlurStyle.init(rawValue:)) ?? Self.defaultBlurStyle

        if UserDefaults.standard.object(forKey: Self.pinnedSidebarTransparencyEnabledKey) != nil {
            self.pinnedSidebarTransparencyEnabled = UserDefaults.standard.bool(
                forKey: Self.pinnedSidebarTransparencyEnabledKey
            )
        } else {
            self.pinnedSidebarTransparencyEnabled = Self.defaultPinnedSidebarTransparencyEnabled
        }
    }

    /// Save current background opacity to UserDefaults
    private func saveBackgroundOpacity() {
        UserDefaults.standard.set(backgroundOpacity, forKey: Self.backgroundOpacityKey)
    }

    /// Save current background blur radius to UserDefaults
    private func saveBackgroundBlurRadius() {
        UserDefaults.standard.set(backgroundBlurRadius, forKey: Self.backgroundBlurRadiusKey)
    }

    /// Save current blur enabled state to UserDefaults
    private func saveBlurEnabled() {
        UserDefaults.standard.set(blurEnabled, forKey: Self.blurEnabledKey)
    }

    /// Reset to default transparency settings
    func resetToDefaults() {
        backgroundOpacity = Self.defaultBackgroundOpacity
        backgroundBlurRadius = Self.defaultBackgroundBlurRadius
        blurEnabled = Self.defaultBlurEnabled
        blurStyle = Self.defaultBlurStyle
        pinnedSidebarTransparencyEnabled = Self.defaultPinnedSidebarTransparencyEnabled
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
