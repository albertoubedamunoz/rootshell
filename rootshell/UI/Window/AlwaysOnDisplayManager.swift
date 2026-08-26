//
//  AlwaysOnDisplayManager.swift
//  rootshell
//
//  Global "Always On Display" setting: while a hold is active the system idle
//  timer is disabled so the screen never auto-locks or dims during
//  long-running terminal work (builds, SSH sessions, `tail -f`, monitoring).
//
//  The setting is a duration, not a plain switch (see `AlwaysOnDisplayDuration`):
//  Off, 1...30 minutes, or Always. A timed hold behaves like a custom auto-lock
//  interval — every touch or key press restarts the window, so the screen stays
//  awake while you work and hands control back to the system once you stop.
//
//  iOS/iPadOS only:
//  - `UIApplication.isIdleTimerDisabled` is the correct API on native iOS/iPad.
//  - Mac Catalyst exposes the property but it is a no-op for Mac display sleep
//    (governed by power assertions, not the idle timer).
//  - visionOS has no traditional auto-lock idle timer (the headset sleeps when
//    removed), so the concept is not meaningful.
//  The whole file is gated to native iOS/iPad; the `#else` provides no-op
//  hooks so the App body and the key-input path compile unchanged everywhere.
//
//  Mirrors `PaddingManager` (@Observable singleton persisting to UserDefaults
//  with a synchronous `didSet`, bound into settings via @Bindable) and
//  `ImmersiveChromeManager` (single launch-time install + lifecycle re-apply).
//

import SwiftUI
import UIKit

#if !targetEnvironment(macCatalyst) && !os(visionOS)

/// How long the screen is kept awake after the last user interaction.
///
/// Persisted as the raw slider position: `0` = off, `1...30` = minutes,
/// `31` = always. Keeping the storage and the slider on one integer scale is
/// what lets a single `Slider` walk Off -> 1 min -> ... -> 30 min -> Always.
enum AlwaysOnDisplayDuration: Equatable {
    case off
    case minutes(Int) // 1...maxMinutes
    case always

    static let maxMinutes = 30

    /// `Slider` bounds covering every case, Off through Always.
    static let sliderRange: ClosedRange<Double> = 0...Double(maxMinutes + 1)

    init(rawValue: Int) {
        if rawValue <= 0 {
            self = .off
        } else if rawValue > Self.maxMinutes {
            self = .always
        } else {
            self = .minutes(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .off: return 0
        case .minutes(let minutes): return min(max(minutes, 1), Self.maxMinutes)
        case .always: return Self.maxMinutes + 1
        }
    }

    /// Whether the idle timer should currently be disabled for this setting.
    var keepsScreenAwake: Bool { self != .off }

    /// The awake window, or nil when there is nothing to time (Off never holds
    /// the screen awake, Always holds it without a deadline).
    var holdInterval: TimeInterval? {
        guard case .minutes(let minutes) = self else { return nil }
        return TimeInterval(minutes) * 60
    }

    /// Compact value shown next to the row title.
    var displayValue: String {
        switch self {
        case .off:
            return String(localized: "Off", comment: "Always On Display duration: disabled")
        case .minutes(let minutes):
            return String(localized: "\(minutes) min", comment: "Always On Display duration in minutes")
        case .always:
            return String(localized: "Always", comment: "Always On Display duration: never auto-lock")
        }
    }

    /// Caption under the slider explaining what the current value does.
    var explanation: String {
        switch self {
        case .off:
            return String(localized: "The screen dims and locks on the system's normal auto-lock schedule.",
                          comment: "Always On Display footer: disabled")
        case .minutes(let minutes):
            return String(localized: "Keeps the screen awake while you work. It locks \(minutes) minute\(minutes == 1 ? "" : "s") after your last touch or key press.",
                          comment: "Always On Display footer: timed hold")
        case .always:
            return String(localized: "Keeps the screen awake the whole time rootshell is in the foreground. It never auto-locks or dims.",
                          comment: "Always On Display footer: never auto-lock")
        }
    }
}

@MainActor
@Observable
final class AlwaysOnDisplayManager {
    static let shared = AlwaysOnDisplayManager()

    private nonisolated static let storageKey = "alwaysOnDisplayMinutes"
    /// Pre-slider builds stored a plain on/off switch, where "on" meant
    /// "never auto-lock". Migrated to `storageKey` on first launch.
    private nonisolated static let legacyToggleKey = "alwaysOnDisplayEnabled"

    /// How long the screen is held awake after the last interaction.
    var duration: AlwaysOnDisplayDuration {
        didSet {
            guard duration != oldValue else { return }
            UserDefaults.standard.set(duration.rawValue, forKey: Self.storageKey)
            armHold() // synchronous -> instant effect
        }
    }

    /// Bridge for `Slider`, which works in `Double` while the setting is a
    /// discrete step. Reads `duration`, so @Observable still tracks it.
    var sliderValue: Double {
        get { Double(duration.rawValue) }
        set { duration = AlwaysOnDisplayDuration(rawValue: Int(newValue.rounded())) }
    }

    private var isInstalled = false
    private var holdTimer: Timer?
    /// Coalesces the per-touch rearm; see `noteUserInteraction()`.
    private var lastArmed: ContinuousClock.Instant?

    private init() {
        // didSet does NOT fire during init, so this does not apply early.
        // This is only an optimistic seed: on a locked/background launch where
        // protected data is unavailable, the read returns nothing. `install()`
        // re-reads the real value once protected data is available, so a
        // persisted duration is never masked for the process lifetime.
        self.duration = Self.persistedDuration()
    }

    /// Idempotent. Loads and applies the persisted state once protected data is
    /// available, then re-applies whenever the app becomes active.
    ///
    /// The persisted value is always re-read from `UserDefaults` (not the
    /// possibly-stale in-memory seed): a locked/background launch can make
    /// `UserDefaults` read as empty, which would otherwise mask a persisted
    /// duration for the whole process. `isIdleTimerDisabled` also resets to
    /// false on a fresh launch, so re-applying on `didBecomeActive` keeps state
    /// robust — and starts a fresh awake window on every return to the app.
    func install() {
        guard !isInstalled else { return }
        isInstalled = true
        ProtectedDataGuard.whenAvailable {
            AlwaysOnDisplayManager.shared.reloadAndApply()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AlwaysOnDisplayManager.shared.reloadAndApply()
            }
        }
        // Backgrounding hands the screen back to the system: UIKit asks for the
        // assertion to be dropped once it is not needed, and `whenAvailable`
        // above is deliberately not gated on activation, so a background launch
        // or unlock must not leave a hold armed where nobody can see the screen.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AlwaysOnDisplayManager.shared.suspendHold()
            }
        }
        // New scenes/windows (iPadOS multi-window, Stage Manager) need their own
        // touch observer; the app's first window is usually already up here.
        // This also catches the keyboard-hosting windows that never appear in
        // `UIWindowScene.windows`, so taps on the software keyboard count too.
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { notification in
            let window = notification.object as? UIWindow
            Task { @MainActor in
                guard let window else { return }
                AlwaysOnDisplayManager.shared.attachInteractionObserver(to: window)
            }
        }
        // Typing is not a touch. Hardware keys go to the responder chain, so
        // text edited anywhere in the app — Quick Connect, search fields,
        // dialogs — counts as interaction. (The terminal is not a UITextField;
        // it calls `noteAlwaysOnDisplayInteraction()` from `pressesBegan`.)
        for name in [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    AlwaysOnDisplayManager.shared.noteUserInteraction()
                }
            }
        }
        attachInteractionObservers()
    }

    /// Restarts the awake window. Called for every touch-down, hardware key
    /// press and text edit, so it stays cheap: Off and Always have no window to
    /// restart, and rapid input is coalesced to at most one rearm per second
    /// (a window is a minute or more, so the lost fraction is irrelevant).
    func noteUserInteraction() {
        guard duration.holdInterval != nil else { return }
        if let lastArmed, ContinuousClock.now - lastArmed < .seconds(1) { return }
        armHold() // owns `lastArmed`
    }

    /// Re-read the persisted setting (protected data assumed available here) and
    /// apply it to the system idle timer.
    private func reloadAndApply() {
        Self.migrateLegacyToggleIfNeeded()
        let persisted = Self.persistedDuration()
        if persisted != duration {
            duration = persisted // didSet persists (no-op, same value) + arms
        } else {
            armHold()
        }
    }

    /// (Re)start the awake window for the current setting and apply it to the
    /// system idle timer.
    private func armHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        lastArmed = nil

        // A background launch or unlock reaches here through `whenAvailable`;
        // arming then would hold an assertion for a screen nobody is looking at.
        // `didBecomeActive` arms for real once the app is in front.
        guard UIApplication.shared.applicationState != .background else {
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        UIApplication.shared.isIdleTimerDisabled = duration.keepsScreenAwake

        guard let interval = duration.holdInterval else { return }
        lastArmed = ContinuousClock.now
        // Scheduled in `.common` so a long scroll or text-selection drag cannot
        // postpone the deadline, and fired synchronously on the main run loop:
        // hopping through a `Task` would let a rearm land between the fire and
        // the callback, and the stale callback would then tear down the newer
        // hold. The identity check below covers that shape regardless.
        let timer = Timer(timeInterval: interval, repeats: false) { timer in
            MainActor.assumeIsolated {
                AlwaysOnDisplayManager.shared.expireHold(timer)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// The window elapsed without any interaction: hand the screen back to the
    /// system idle timer, which decides when to dim and lock from here. The
    /// setting is not spent — the next touch or key press arms a fresh window.
    private func expireHold(_ timer: Timer) {
        // Anything that rearms invalidates the timer it replaces, so a timer
        // that is no longer the current one has already been superseded.
        guard timer === holdTimer else { return }
        holdTimer = nil
        lastArmed = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Going to the background: drop the assertion and the pending timer but
    /// keep `duration`, so the setting is intact when the app comes back and
    /// `didBecomeActive` arms a fresh window.
    private func suspendHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        lastArmed = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Persistence

    private static func persistedDuration() -> AlwaysOnDisplayDuration {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: storageKey) as? Int {
            return AlwaysOnDisplayDuration(rawValue: raw)
        }
        return defaults.bool(forKey: legacyToggleKey) ? .always : .off
    }

    /// Fold a pre-slider "on" switch into the duration setting. Only ever runs
    /// where protected data is available, so an unreadable `UserDefaults` on a
    /// locked launch cannot mistake a persisted setting for "never configured"
    /// and write the default over it.
    private static func migrateLegacyToggleIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: legacyToggleKey) != nil else { return }
        if defaults.object(forKey: storageKey) == nil, defaults.bool(forKey: legacyToggleKey) {
            defaults.set(AlwaysOnDisplayDuration.always.rawValue, forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyToggleKey)
    }

    // MARK: - Interaction observation

    private func attachInteractionObservers() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                attachInteractionObserver(to: window)
            }
        }
    }

    fileprivate func attachInteractionObserver(to window: UIWindow) {
        let alreadyAttached = window.gestureRecognizers?.contains { $0 is InteractionObserverGesture } ?? false
        guard !alreadyAttached else { return }
        window.addGestureRecognizer(InteractionObserverGesture())
    }
}

/// Window-level touch observer: fails immediately on the first touch, so it
/// sees every touch-down without ever claiming a gesture, delaying delivery or
/// cancelling touches in the view below.
private final class InteractionObserverGesture: UIGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
        AlwaysOnDisplayManager.shared.noteUserInteraction()
    }
}

// MARK: - Install hook

private struct AlwaysOnDisplayInstallModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            AlwaysOnDisplayManager.shared.install()
        }
    }
}

extension View {
    /// Installs the always-on-display manager on the first appearance.
    /// Idempotent. No-op on Mac Catalyst / visionOS.
    func alwaysOnDisplay() -> some View {
        modifier(AlwaysOnDisplayInstallModifier())
    }
}

/// Restarts the always-on-display awake window from input paths the window
/// touch observer cannot see — hardware key presses reach the responder chain,
/// not `touchesBegan`. No-op on platforms without an idle timer.
@MainActor
func noteAlwaysOnDisplayInteraction() {
    AlwaysOnDisplayManager.shared.noteUserInteraction()
}

#else

// Mac Catalyst / visionOS: no meaningful idle timer to control.
extension View {
    func alwaysOnDisplay() -> some View {
        self
    }
}

@MainActor
func noteAlwaysOnDisplayInteraction() {}

#endif
