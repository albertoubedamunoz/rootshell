import Foundation
import Combine
import SwiftUI
import OSLog

#if canImport(UIKit)
import UIKit
#endif

/// Manages appearance mode (light/dark/system) for the app UI
@MainActor
class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AppearanceManager")

    /// Appearance mode options
    enum AppearanceMode: String, CaseIterable {
        case automatic = "automatic"
        case light = "light"
        case dark = "dark"

        var displayName: String {
            switch self {
            case .automatic: return String(localized: "Automatic", comment: "Appearance mode: follow system setting")
            case .light: return String(localized: "Light", comment: "Appearance mode: light theme")
            case .dark: return String(localized: "Dark", comment: "Appearance mode: dark theme")
            }
        }

        /// Convert to SwiftUI ColorScheme (nil means system default)
        var colorScheme: ColorScheme? {
            switch self {
            case .automatic: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        #if canImport(UIKit)
        /// UIKit trait override equivalent (.unspecified means follow system)
        var interfaceStyle: UIUserInterfaceStyle {
            switch self {
            case .automatic: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
        #endif
    }

    private static let appearanceKey = "appearanceMode"
    private static let themedUIKey = "themedUI"

    /// Currently selected appearance mode
    @Published var currentAppearanceMode: AppearanceMode {
        didSet {
            applyWindowOverrides()
            guard ProtectedDataGuard.isAvailable else { return }
            saveAppearanceMode()
            appearanceModeDidChange.send(currentAppearanceMode)
        }
    }

    /// Whether to apply terminal theme colors to sheets and settings
    @Published var themedUIEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            UserDefaults.standard.set(themedUIEnabled, forKey: Self.themedUIKey)
        }
    }

    /// Publisher that emits when appearance mode changes
    let appearanceModeDidChange = PassthroughSubject<AppearanceMode, Never>()

    /// Computed property for SwiftUI's preferredColorScheme modifier
    var colorScheme: ColorScheme? {
        currentAppearanceMode.colorScheme
    }

    #if canImport(UIKit)
    private var windowObserver: NSObjectProtocol?
    #endif

    private init() {
        // Load saved appearance mode or default to automatic
        if let savedMode = UserDefaults.standard.string(forKey: Self.appearanceKey),
           let mode = AppearanceMode(rawValue: savedMode) {
            self.currentAppearanceMode = mode
        } else {
            self.currentAppearanceMode = .automatic
        }
        self.themedUIEnabled = UserDefaults.standard.object(forKey: Self.themedUIKey) as? Bool ?? true

        #if canImport(UIKit)
        // Stamp the override onto every window as it appears (covers windows
        // created after a mode change, restored scenes, visor, AI agent).
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppearanceManager.shared.applyWindowOverrides()
            }
        }
        #endif
    }

    /// Save current appearance mode to UserDefaults
    private func saveAppearanceMode() {
        UserDefaults.standard.set(currentAppearanceMode.rawValue, forKey: Self.appearanceKey)
    }

    // MARK: - Window-level appearance enforcement

    /// Forces the window-level appearance to match the selected mode.
    ///
    /// `.preferredColorScheme` only overrides the SwiftUI environment; system
    /// materials (Liquid Glass, blur) resolve against the window's trait
    /// collection, and on Mac Catalyst against the AppKit window appearance.
    /// Without this override, a forced-Dark app with the OS in Light mode
    /// renders the selected-tab glass white whenever the window is inactive
    /// (or whenever Reduce Transparency / Increase Contrast flattens glass to
    /// an appearance-resolved fill). See GitHub issue #250.
    func applyWindowOverrides() {
        #if canImport(UIKit)
        let style = currentAppearanceMode.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
        applyAppKitAppearance()
    }

    /// Catalyst: also pin NSApplication.appearance so the titlebar and the
    /// AppKit-side material passes (including inactive-window rendering)
    /// resolve to the forced mode. Uses the same ObjC-runtime bridge pattern
    /// as WindowAccessor.
    private func applyAppKitAppearance() {
        #if targetEnvironment(macCatalyst)
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject else {
            Self.logger.warning("Failed to resolve NSApplication for appearance override")
            return
        }

        let appearanceName: String?
        switch currentAppearanceMode {
        case .automatic: appearanceName = nil
        case .light: appearanceName = "NSAppearanceNameAqua"
        case .dark: appearanceName = "NSAppearanceNameDarkAqua"
        }

        var appearance: NSObject?
        if let appearanceName {
            guard let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type,
                  let resolved = appearanceClass.perform(
                      NSSelectorFromString("appearanceNamed:"),
                      with: appearanceName
                  )?.takeUnretainedValue() as? NSObject else {
                Self.logger.warning("Failed to resolve NSAppearance \(appearanceName)")
                return
            }
            appearance = resolved
        }

        sharedApp.setValue(appearance, forKey: "appearance")
        #endif
    }
}
