import Foundation

extension Notification.Name {
    /// Posted when the global HDR brightness-boost gain changes. `GhosttyApp`
    /// observes this and pushes the new value to every live surface.
    static let brightnessDidChange = Notification.Name("com.rootshell.brightnessDidChange")
}

/// Global, persisted HDR "brightness boost" gain applied to terminal and VNC
/// surfaces. 1.0 = SDR (no boost); values above 1.0 request EDR headroom and
/// drive rendered content above SDR white on EDR-capable displays.
///
/// Modeled on `TransparencyManager` (`@Observable` singleton with a UserDefaults
/// `didSet`), but broadcasts changes via `NotificationCenter` rather than Combine
/// (project convention), matching the renderer/cursor subscription pattern in
/// `GhosttyApp`.
@MainActor
@Observable
final class BrightnessManager {
    static let shared = BrightnessManager()

    /// The neutral (SDR) gain.
    static let defaultGain: Double = 1.0

    /// Hard ceiling on the gain regardless of how much EDR headroom a display
    /// reports, so text can't be boosted to a blinding multiple on an XDR panel.
    /// The slider further clamps to the display's actual headroom.
    static let maxGainCap: Double = 2.0

    /// Multiplicative brightness gain. Clamped to `[1.0, maxGainCap]`.
    var gain: Double {
        didSet {
            let clamped = min(max(gain, 1.0), Self.maxGainCap)
            if clamped != gain {
                // Re-enter once to apply the clamp, then this guard stops us.
                gain = clamped
                return
            }
            guard gain != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Power.brightnessGain, gain) }
            NotificationCenter.default.post(name: .brightnessDidChange, object: nil)
        }
    }

    @ObservationIgnored private var isReloading = false

    /// Whether a boost is currently active (gain above SDR).
    var isBoosted: Bool { gain > 1.0 }

    /// The modern per-layer EDR presentation API is only available on the 26
    /// OS generation. Keep this centralized so persisted gains are a strict
    /// rendering no-op on older supported releases.
    static var isHDRBoostAvailable: Bool {
        #if os(visionOS)
        return false
        #else
        if #available(iOS 26.0, macCatalyst 26.0, macOS 26.0, *) {
            return true
        }
        return false
        #endif
    }

    /// Gain that is safe to hand to a renderer on the current runtime.
    var effectiveGain: Double {
        Self.isHDRBoostAvailable ? gain : Self.defaultGain
    }

    private init() {
        gain = Self.storedGain()
        SettingsRefreshHub.shared.register(keys: [Settings.Power.brightnessGain.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    private static func storedGain() -> Double {
        min(max(SettingsStore.shared.get(Settings.Power.brightnessGain), 1.0), maxGainCap)
    }

    /// Re-read the gain after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Power.brightnessGain.name) {
            gain = Self.storedGain()
        }
    }

    /// Reset back to SDR.
    func reset() {
        gain = Self.defaultGain
    }
}
