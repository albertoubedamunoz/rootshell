//
//  VisorWindowAccessor.swift
//  rootshell
//
//  Mounted inside the visor WindowGroup's content. Grabs the underlying
//  NSWindow via runtime reflection on NSApplication (Mac Catalyst can't
//  import AppKit) and reconfigures it to behave like a non-activating
//  floating panel that can join all spaces.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import SwiftUI
import UIKit
import ObjectiveC
import Combine
import os

private let logger = Logger(subsystem: "com.rootshell", category: "VisorWindowAccessor")

/// Internal associated-object key — kept separate from WindowAccessor's so we
/// don't collide with the main window's claim.
private var visorClaimKey: UInt8 = 0

struct VisorWindowAccessor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        VisorWindowAccessorView()
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class VisorWindowAccessorView: UIView {
    private var cancellables = Set<AnyCancellable>()
    private var didConfigure = false
    private var keyWatchdogToken: NSObjectProtocol?

    deinit {
        if let keyWatchdogToken {
            NotificationCenter.default.removeObserver(keyWatchdogToken)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window = self.window else { return }
        // Definitively tag this scene's session as the visor's so future
        // scene save/restore callbacks in CatalystSceneDelegate skip it.
        if let session = window.windowScene?.session {
            VisorSceneRegistry.shared.register(session: session)
            // This is the LIVE-summon path — record the scene id so the next
            // launch's backstop can recognize this session if the OS restores
            // it, and clear the in-flight flag now that the scene has landed.
            // (A restored zombie never reaches here; the backstop destroys it
            // before its content mounts.)
            VisorSceneLifecycle.persistedSceneId = session.persistentIdentifier
            VisorSceneLifecycle.summonInFlight = false
        }
        // Try the cheap hide synchronously so SwiftUI's default-sized
        // window doesn't flash at center-screen before configure() runs.
        // Only the slower styleMask/level/etc. work needs the one-runloop
        // defer.
        hideEarlyIfPossible()
        DispatchQueue.main.async { [weak self] in
            self?.configure()
        }

        VisorSettings.shared.$spaceBehavior
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyCollectionBehavior() }
            .store(in: &cancellables)

        Ghostty.App.shared?.surfaceCountDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeForCurrentWindow() }
            .store(in: &cancellables)

        TransparencyManager.shared.transparencyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeForCurrentWindow() }
            .store(in: &cancellables)

        ThemeManager.shared.themeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyChromeForCurrentWindow() }
            .store(in: &cancellables)
    }

    /// Slam the window invisible synchronously so SwiftUI's default-sized
    /// window doesn't visibly flash before our configure() runs.
    /// `VisorController.animateIn` will reset alpha and animate it back to 1
    /// on a real summon.
    ///
    /// We deliberately do NOT call setFrame here. Direct NSWindow.setFrame
    /// on a Catalyst-hosted window can propagate up to the UIWindowScene's
    /// pinned geometry preference, and once Catalyst has a preference
    /// pinned, subsequent setFrame calls (from animateIn) get fought —
    /// leaving the visor stuck at our hide-time frame. Alpha-only hide is
    /// pure NSWindow state and doesn't engage the scene geometry pipeline.
    private func hideEarlyIfPossible() {
        guard let nsWindow = resolveNSWindow() else { return }
        nsWindow.setValue(NSNumber(value: 0.0), forKey: "alphaValue")
    }

    private func configure(attempt: Int = 0) {
        guard !didConfigure, self.window != nil else { return }
        // After ~500ms of failed resolution, also try reclaiming a window
        // the main WindowAccessor tagged with its own session id (the
        // steal leaves resolution permanently stuck otherwise). Not on
        // early attempts: frames are still settling at scene bring-up and
        // normal resolution should win the common case.
        let allowRecovery = attempt >= 10
        guard let nsWindow = resolveNSWindow(allowStolenClaimRecovery: allowRecovery) else {
            scheduleConfigureRetry(after: attempt)
            return
        }
        if attempt > 0 {
            logger.info("Resolved visor NSWindow after \(attempt) retries")
        }
        // Re-assert invisibility before the styleMask change in case the
        // synchronous hideEarlyIfPossible couldn't find the NSWindow yet.
        nsWindow.setValue(NSNumber(value: 0.0), forKey: "alphaValue")

        VisorWindowBridge.shared.register(nsWindow: nsWindow, uiWindow: self.window)
        // Mark BEFORE the styleMask change. Stripping `.titled` makes
        // canBecomeKey return false by default, which would block the
        // visor from ever getting keystrokes; the global swizzle defers
        // to this associated flag and returns true for marked windows
        // only. We can't use `object_setClass` here — UINSSceneView is
        // KVO-observing this window from creation, and reclassing it
        // corrupts KVO's per-instance state and crashes the next KVC
        // call. Method-swizzling NSWindow itself is safe because it
        // only modifies the class dispatch table, not any instance
        // state, so KVO stays healthy.
        VisorWindowKeyOverride.mark(nsWindow)
        applyStyleMask(nsWindow)
        applyLevel(nsWindow, level: .floating)
        applyCollectionBehavior(on: nsWindow)
        applyChrome(nsWindow)
        Ghostty.App.shared?.applyWindowBlur()
        didConfigure = true

        // Launch/restore: macOS restores the visor scene on every launch
        // once it has been summoned in a previous run, and during that
        // restoration the (still titled, pre-mark) window can be made key
        // while invisible — hijacking UIKeyCommand dispatch (the Return
        // key) away from the main terminal window until the user toggles
        // the visor. Steer key status back if that happened, and keep a
        // watchdog in case restoration keys the window after configure.
        //
        // Deliberately do NOT orderOut: or otherwise reorder the hidden
        // window here. Changing its ordering during scene bring-up
        // deactivates the Catalyst scene and breaks the summon animation
        // and first-responder routing. Key status is the only thing we
        // touch.
        handOffKeyIfStolen(nsWindow)
        installKeyWatchdog(on: nsWindow)

        // Restoration can reset alphaValue after our hide (the window was
        // created visible and the scene machinery may still be settling).
        // One delayed re-assert; alpha-only is safe, it doesn't touch
        // ordering or the scene geometry pipeline. Skipped if a summon
        // started in the meantime.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard self != nil,
                  !VisorWindowKeyOverride.visorShouldBeKey,
                  let nsWindow = VisorWindowBridge.shared.nsWindow else { return }
            nsWindow.setValue(NSNumber(value: 0.0), forKey: "alphaValue")
        }
    }

    /// During scene restoration the Catalyst NSWindow can enter
    /// NSApp.windows after didMoveToWindow has fired. The previous
    /// single deferred configure() pass then missed it permanently and
    /// the visor stayed on screen as an unconfigured small white window
    /// until the next summon re-ran configuration. Retry briefly.
    private func scheduleConfigureRetry(after attempt: Int) {
        let maxAttempts = 60 // x 50ms = 3s
        guard attempt < maxAttempts else {
            let diagnostics = windowListDiagnostics()
            logger.error("Gave up resolving visor NSWindow after \(maxAttempts) retries — window list never yielded a claimable window. \(diagnostics)")
            return
        }
        if attempt == 0 {
            let windowCount = Self.appKitWindowCount()
            logger.warning("Could not resolve NSWindow for visor scene; retrying (NSApp.windows count: \(windowCount))")
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.configure(attempt: attempt + 1)
        }
    }

    private static func appKitWindowCount() -> Int {
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return -1
        }
        return windows.count
    }

    /// One-line dump of every NSWindow's frame, claim, and key state plus
    /// our scene's systemFrame, so a field report of the exhaustion error
    /// pins which race fired.
    private func windowListDiagnostics() -> String {
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return "no window list"
        }
        let sceneFrame = self.window?.windowScene?.effectiveGeometry.systemFrame ?? .zero
        let entries = windows.map { window -> String in
            let frame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
            let mainClaim = WindowAccessor.sceneSessionId(for: window) ?? "-"
            let visorClaim = (objc_getAssociatedObject(window, &visorClaimKey) as? String) ?? "-"
            let isKey = (window.value(forKey: "isKeyWindow") as? Bool) == true
            return "[frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)) mainClaim=\(mainClaim) visorClaim=\(visorClaim) key=\(isKey)]"
        }
        return "sceneFrame=\(Int(sceneFrame.origin.x)),\(Int(sceneFrame.origin.y)) \(Int(sceneFrame.width))x\(Int(sceneFrame.height)) windows: \(entries.joined(separator: " "))"
    }

    /// If the hidden visor window holds key status while no summon is in
    /// progress (the launch-restoration race), hand key back to the main
    /// terminal window so UIKit fires didBecomeKey there and the terminal
    /// re-asserts first responder. Leaves the visor window's ordering,
    /// styleMask, and alpha untouched.
    private func handOffKeyIfStolen(_ window: NSObject) {
        guard !VisorWindowKeyOverride.visorShouldBeKey else { return }
        guard (window.value(forKey: "isKeyWindow") as? Bool) == true else { return }
        logger.info("Hidden visor window held key status outside a summon; handing key to main window")
        makeMainWindowKey()
    }

    /// Hand key status to a visible non-visor NSWindow, preferring one
    /// claimed by the main WindowAccessor (a real terminal window) so the
    /// handoff can't surface an auxiliary window. Deliberately not
    /// NSApp.mainWindow: the visor itself may have grabbed main status
    /// during the pre-mark runloop gap at scene restoration.
    private func makeMainWindowKey() {
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return
        }
        let candidates = windows.filter { window in
            guard !VisorWindowClaims.isVisorWindow(window) else { return false }
            return (window.value(forKey: "visible") as? Bool) == true
        }
        let target = candidates.first(where: { WindowAccessor.sceneSessionId(for: $0) != nil })
            ?? candidates.first
        guard let target else {
            logger.warning("No visible non-visor window to hand key to")
            return
        }
        _ = target.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
        logger.info("Handed key to main window")
    }

    /// Self-heal: if anything makes the hidden visor window key while no
    /// summon is in progress (scene restoration can key it after configure),
    /// steer key status back to the main window.
    private func installKeyWatchdog(on window: NSObject) {
        if let keyWatchdogToken {
            NotificationCenter.default.removeObserver(keyWatchdogToken)
        }
        keyWatchdogToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidBecomeKeyNotification"),
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.handOffKeyIfStolen(window)
            }
        }
    }

    private func applyCollectionBehavior() {
        guard didConfigure, let nsWindow = VisorWindowBridge.shared.nsWindow else { return }
        applyCollectionBehavior(on: nsWindow)
    }

    private func applyChromeForCurrentWindow() {
        guard didConfigure, let nsWindow = VisorWindowBridge.shared.nsWindow else { return }
        applyChrome(nsWindow)
        Ghostty.App.shared?.applyWindowBlur()
    }

    private func applyStyleMask(_ window: NSObject) {
        // True panel-style visor:
        //   - Strip .titled / .closable / .miniaturizable — no chrome
        //   - Add .nonactivatingPanel — the magic bit that, on AppKit, lets
        //     this window receive keystrokes without our application
        //     becoming the active app (mirrors NSPanel.nonactivatingPanel).
        //   - Add .resizable — user can still drag edges to resize
        //   - Add .fullSizeContentView — content extends edge-to-edge
        //
        // Catalyst caveat: AppKit needs to rebuild the frame view when the
        // titled bit changes. Earlier this crashed because we had ALSO
        // called `object_setClass(window, ...)` which corrupted KVO state,
        // and the rebuild's KVO teardown then null-deref'd. With KVO
        // healthy (we now use method swizzling instead of reclassing for
        // canBecomeKey), the frame-view swap should complete cleanly.
        let titled: UInt = 1 << 0
        let closable: UInt = 1 << 1
        let miniaturizable: UInt = 1 << 2
        let resizable: UInt = 1 << 3
        let nonactivatingPanel: UInt = 1 << 7
        let fullSizeContentView: UInt = 1 << 15

        let current = (window.value(forKey: "styleMask") as? UInt) ?? 0
        var mask = current
        mask &= ~titled
        mask &= ~closable
        mask &= ~miniaturizable
        mask |= resizable
        mask |= nonactivatingPanel
        mask |= fullSizeContentView
        if mask != current {
            window.setValue(mask, forKey: "styleMask")
        }

        window.setValue(true, forKey: "hasShadow")
        window.setValue(false, forKey: "hidesOnDeactivate")

        // becomesKeyOnlyIfNeeded defaults to true on non-activating panels,
        // which makes the panel wait for an explicit click before keying.
        // We want immediate key focus on summon.
        if window.responds(to: NSSelectorFromString("setBecomesKeyOnlyIfNeeded:")) {
            window.setValue(false, forKey: "becomesKeyOnlyIfNeeded")
        }
    }

    private func applyLevel(_ window: NSObject, level: VisorWindowLevel) {
        window.setValue(level.rawValue, forKey: "level")
    }

    private func applyCollectionBehavior(on window: NSObject) {
        let canJoinAllSpaces: UInt = 1 << 0
        let moveToActiveSpace: UInt = 1 << 1
        let ignoresCycle: UInt = 1 << 6
        let fullScreenAuxiliary: UInt = 1 << 8

        let behavior: UInt
        switch VisorSettings.shared.spaceBehavior {
        case .move:
            behavior = canJoinAllSpaces | fullScreenAuxiliary | ignoresCycle
        case .remain:
            behavior = moveToActiveSpace | fullScreenAuxiliary | ignoresCycle
        }
        window.setValue(behavior, forKey: "collectionBehavior")
    }

    private func applyChrome(_ window: NSObject) {
        // Match regular Catalyst terminal windows: use a barely-visible
        // backing color when terminal transparency is active so NSWindow
        // blur/transparency composes correctly. Unlike regular windows, the
        // visor scene is terminal-only and can be prewarmed before a surface
        // exists, so opacity alone is the right switch here.
        let opacity = TransparencyManager.shared.backgroundOpacity
        let shouldApplyTransparency = opacity < 1.0

        if shouldApplyTransparency {
            self.window?.backgroundColor = .white.withAlphaComponent(0.001)
            self.window?.isOpaque = false
            self.window?.rootViewController?.view.backgroundColor = .clear
            self.window?.rootViewController?.view.isOpaque = false
        } else {
            self.window?.backgroundColor = .systemBackground
            self.window?.isOpaque = true
            self.window?.rootViewController?.view.backgroundColor = .systemBackground
            self.window?.rootViewController?.view.isOpaque = true
        }

        window.setValue(!shouldApplyTransparency, forKey: "opaque")

        guard let nsColorClass = NSClassFromString("NSColor") as? NSObject.Type else { return }

        let backgroundColor: NSObject?
        if shouldApplyTransparency {
            let selector = NSSelectorFromString("colorWithWhite:alpha:")
            if nsColorClass.responds(to: selector), let method = nsColorClass.method(for: selector) {
                typealias ColorFunction = @convention(c) (AnyClass, Selector, CGFloat, CGFloat) -> NSObject
                let colorFunc = unsafeBitCast(method, to: ColorFunction.self)
                backgroundColor = colorFunc(nsColorClass, selector, 1.0, 0.001)
            } else {
                backgroundColor = nsColorClass.value(forKey: "clearColor") as? NSObject
            }
        } else {
            backgroundColor = nsColorClass.value(forKey: "windowBackgroundColor") as? NSObject
        }

        if let backgroundColor {
            window.setValue(backgroundColor, forKey: "backgroundColor")
        }
    }

    /// Find or claim the NSWindow for our (visor) scene.
    ///
    /// Critical: must NOT claim a window that's already claimed by
    /// `WindowAccessor` (the main rootshell scene's accessor). Those carry
    /// a separate associated-object claim under `WindowAccessor`'s
    /// `sceneSessionIdKey`. An earlier bug here claimed the main window
    /// during prewarm and applied the visor's `alpha=0` + off-screen frame
    /// + borderless styleMask to it, leaving the user with no visible main
    /// window.
    private func resolveNSWindow(allowStolenClaimRecovery: Bool = false) -> NSObject? {
        guard let uiWindow = self.window,
              let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let windows = sharedApp.value(forKey: "windows") as? [NSObject] else {
            return nil
        }
        let sessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        guard !sessionId.isEmpty else { return nil }

        // 1. Window already claimed for this session by us.
        if let already = windows.first(where: {
            (objc_getAssociatedObject($0, &visorClaimKey) as? String) == sessionId
        }) {
            return already
        }

        // 2. Anything not claimed by us AND not claimed by the main
        // WindowAccessor (under its own session-id key). The main window
        // is claimed by WindowAccessor very early in the main scene's
        // lifecycle, so by the time the visor scene attaches, the main
        // window has a `WindowAccessor.sceneSessionId(for:)` value set —
        // and that value belongs to the MAIN scene's UIWindowScene, not
        // ours. Skip any window whose existing main-accessor claim
        // doesn't match our visor session id.
        let candidates = windows.filter { window in
            guard objc_getAssociatedObject(window, &visorClaimKey) == nil else { return false }
            if let otherSession = WindowAccessor.sceneSessionId(for: window),
               otherSession != sessionId {
                return false
            }
            return true
        }

        // 3. Among the safe candidates, prefer the key window (the most
        // recently created/focused NSWindow — typically the visor scene
        // we just opened via openWindow). Falls back to the last
        // candidate.
        let target = candidates.first(where: {
            ($0.value(forKey: "isKeyWindow") as? Bool) == true
        }) ?? candidates.last

        guard let target else {
            // 4. Recovery: the main WindowAccessor's claim logic can tag
            // OUR window with the main scene's session id if it catches it
            // key + unclaimed + unmarked in the sub-tick gap before a
            // retry claims it. Such a window is excluded by step 2
            // forever, so retries alone never recover. Identify our window
            // positively by geometry and take the claim back.
            if allowStolenClaimRecovery {
                return recoverStolenWindow(uiWindow: uiWindow, windows: windows, sessionId: sessionId)
            }
            return nil
        }
        objc_setAssociatedObject(target, &visorClaimKey, sessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return target
    }

    /// Find the visor's NSWindow by full-frame match (x, y, width, height)
    /// with our scene's systemFrame. The geometry save/restore code already
    /// relies on systemFrame being macOS screen coordinates; x and size are
    /// directly comparable to the AppKit frame and y is compared through
    /// the bottom-left/top-left flip. Requires a UNIQUE match so a
    /// coincidentally co-located terminal window can never be hijacked, and
    /// only reclaims windows that actually carry a foreign main-accessor
    /// claim.
    private func recoverStolenWindow(
        uiWindow: UIWindow,
        windows: [NSObject],
        sessionId: String
    ) -> NSObject? {
        guard let systemFrame = uiWindow.windowScene?.effectiveGeometry.systemFrame else {
            return nil
        }
        let matches = windows.filter { Self.frameMatches($0, systemFrame: systemFrame) }
        guard matches.count == 1, let stolen = matches.first else {
            if matches.count > 1 {
                let count = matches.count
                logger.warning("Stolen-claim recovery ambiguous: \(count) windows match the visor scene frame")
            }
            return nil
        }
        // Step 2 only rejects foreign-claimed windows, so reaching here
        // with a unique frame match means the claim was stolen. Verify
        // anyway before clearing.
        guard let foreign = WindowAccessor.sceneSessionId(for: stolen), foreign != sessionId else {
            return nil
        }
        logger.warning("Recovering visor NSWindow stolen by main-accessor claim from scene \(foreign)")
        WindowAccessor.clearSceneSessionClaim(for: stolen)
        objc_setAssociatedObject(stolen, &visorClaimKey, sessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return stolen
    }

    private static func frameMatches(_ window: NSObject, systemFrame: CGRect) -> Bool {
        guard let frame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue else {
            return false
        }
        let tolerance: CGFloat = 1.5
        guard abs(frame.width - systemFrame.width) <= tolerance,
              abs(frame.height - systemFrame.height) <= tolerance,
              abs(frame.origin.x - systemFrame.origin.x) <= tolerance else {
            return false
        }
        // systemFrame is top-left-origin; the AppKit frame is bottom-left.
        // Flip through the primary screen height (the screen that defines
        // AppKit's global origin). Without all four coordinates verified, a
        // same-sized main window at a different vertical position would
        // "match" and recovery would clear a LIVE main-window claim, so
        // fail closed when the screen can't be resolved.
        guard let screenHeight = primaryScreenHeight() else { return false }
        let expectedY = screenHeight - systemFrame.maxY
        return abs(frame.origin.y - expectedY) <= tolerance
    }

    private static func primaryScreenHeight() -> CGFloat? {
        guard let nsScreenClass = NSClassFromString("NSScreen") as? NSObject.Type,
              let screens = nsScreenClass.value(forKey: "screens") as? [NSObject],
              let primary = screens.first,
              let frame = (primary.value(forKey: "frame") as? NSValue)?.cgRectValue else {
            return nil
        }
        return frame.height
    }
}

enum VisorWindowLevel: Int {
    /// `NSWindow.Level.floating`
    case floating = 3
    /// `NSWindow.Level.popUpMenu` — used briefly during animation so the
    /// window can render outside `visibleFrame` without clipping behind the
    /// menu bar.
    case popUpMenu = 101
}

/// Side channel between the visor scene (which discovers the NSWindow on
/// appear) and the VisorController (which orders/animates it). Kept tiny
/// and MainActor-isolated.
@MainActor
final class VisorWindowBridge: ObservableObject {
    static let shared = VisorWindowBridge()
    private init() {}

    private(set) weak var nsWindow: NSObject?
    private(set) weak var uiWindow: UIWindow?

    fileprivate func register(nsWindow: NSObject, uiWindow: UIWindow?) {
        self.nsWindow = nsWindow
        self.uiWindow = uiWindow
        // Notify any waiter (the controller may have been asked to show
        // before the scene's content was attached).
        NotificationCenter.default.post(name: .visorWindowAttached, object: nil)
        VisorController.shared.handleWindowAttached()
    }
}

extension Notification.Name {
    static let visorWindowAttached = Notification.Name("com.rootshell.visorWindowAttached")
}

/// Lets the main WindowAccessor's NSWindow-claim logic avoid the visor's
/// window. An earlier race let WindowAccessor's key-window fallback claim
/// the visor's NSWindow under the MAIN scene's session id, after which the
/// visor's resolveNSWindow() skipped its own window forever and the visor
/// stayed on screen as an unconfigured small white window at launch.
enum VisorWindowClaims {
    @MainActor
    static func isVisorWindow(_ window: NSObject) -> Bool {
        if objc_getAssociatedObject(window, &visorClaimKey) != nil { return true }
        return VisorWindowKeyOverride.isMarked(window)
    }
}

/// Tracks which UISceneSession is the visor's so CatalystSceneDelegate can
/// skip geometry restore/save for it. Populated at the earliest opportunity
/// — once from CatalystSceneDelegate.scene(_:willConnectTo:) heuristically,
/// and again from VisorWindowAccessor's didMoveToWindow once we definitively
/// know the session.
@MainActor
final class VisorSceneRegistry {
    static let shared = VisorSceneRegistry()
    private init() {}

    private var sessionIdentifiers: Set<String> = []

    func register(session: UISceneSession) {
        sessionIdentifiers.insert(session.persistentIdentifier)
    }

    func register(sceneIdentifier: String) {
        sessionIdentifiers.insert(sceneIdentifier)
    }

    func isVisor(session: UISceneSession) -> Bool {
        sessionIdentifiers.contains(session.persistentIdentifier)
    }
}

// MARK: - Cross-launch visor scene lifecycle

/// Tracks the visor's scene across launches so the restored zombie can be
/// destroyed before it ever configures (the launch backstop in
/// CatalystSceneDelegate), rather than reactively recovered after it steals
/// key status or flashes a white window.
///
/// `summonInFlight` distinguishes a live summon's `willConnectTo` (we just
/// asked for the scene) from a launch restoration (the OS brought back the
/// previous run's scene). It is deliberately separate from
/// `VisorWindowKeyOverride.visorShouldBeKey`, which stays true the entire
/// time the visor is visible — far wider than the connection window.
@MainActor
enum VisorSceneLifecycle {
    /// True from just before `requestSceneSessionActivation` until the
    /// requested scene connects (or a timeout). The willConnectTo backstop
    /// only destroys a visor scene when this is false.
    static var summonInFlight = false

    private static let defaultsKey = "visor.persistentSceneIdentifier"

    /// The persistentIdentifier of the last live visor scene, surviving
    /// across launches so the restored zombie is recognizable independent of
    /// SwiftUI's undocumented `session.configuration.name`.
    static var persistedSceneId: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    static func beginSummon() {
        summonInFlight = true
        // Failsafe: a failed/ignored activation must not leave the flag stuck
        // true, or the next launch's backstop would skip the zombie forever.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            summonInFlight = false
        }
    }
}

// MARK: - Method-swizzled canBecomeKey/canBecomeMain

/// Make the visor's NSWindow behave like an NSPanel.nonactivatingPanel by
/// globally swizzling a few NSWindow methods. The swizzled implementations
/// only change behavior for windows we've explicitly marked via an
/// associated object; non-marked windows are unaffected.
///
/// What we override and why:
///   * `canBecomeKey` → true (marked). Required because we strip `.titled`
///     from styleMask, which otherwise makes this return false.
///   * `canBecomeMain` → **false** (marked). NSPanel returns false here —
///     panels are accessory windows that aren't candidates for app's main
///     window. AppKit uses canBecomeMain as part of its decision to
///     activate the app when ordering a window front. Returning false
///     prevents app activation on `orderFront`/`makeKey`.
///   * `isKindOfClass:` → claims NSPanel ancestry (marked). AppKit's
///     internal "is this a nonactivating panel" check appears to use
///     `isKindOfClass:NSPanel`, not just the styleMask bit. Without this,
///     Catalyst's UINSWindow (a direct NSWindow subclass, not NSPanel)
///     isn't treated as a panel and the nonactivatingPanel styleMask is
///     ignored.
///
/// Why method swizzling instead of `object_setClass`:
///   `object_setClass` swaps a single window's class to a dynamic NSPanel
///   subclass. But UINSSceneView is KVO-observing the window from creation,
///   and KVO depends on the original class's dispatch table. Reclassing
///   leaves the KVO setter overrides in the bypassed KVO subclass, so the
///   next KVC call crashes inside KVO. Method swizzling modifies the
///   class dispatch table itself, not any instance state, so KVO stays
///   healthy.
private var visorKeyOverrideKey: UInt8 = 0

enum VisorWindowKeyOverride {
    private static var swizzleInstalled = false

    /// True only while a summon is in progress or the visor is visible.
    /// Consulted by the configure-time key handoff and the key watchdog in
    /// VisorWindowAccessorView so they never steer key status away from a
    /// window that is being summoned. Written by VisorController.
    @MainActor static var visorShouldBeKey = false

    @MainActor
    static func mark(_ window: NSObject) {
        installSwizzleIfNeeded()
        objc_setAssociatedObject(
            window,
            &visorKeyOverrideKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    fileprivate static func isMarked(_ instance: AnyObject) -> Bool {
        objc_getAssociatedObject(instance, &visorKeyOverrideKey) != nil
    }

    @MainActor
    private static func installSwizzleIfNeeded() {
        guard !swizzleInstalled else { return }
        swizzleInstalled = true

        guard let nsWindowClass: AnyClass = NSClassFromString("NSWindow") else {
            logger.warning("NSWindow class missing; visor swizzle skipped")
            return
        }
        installBoolSwizzle(
            class: nsWindowClass,
            selector: NSSelectorFromString("canBecomeKey"),
            markedReturns: true
        )
        installBoolSwizzle(
            class: nsWindowClass,
            selector: NSSelectorFromString("canBecomeMain"),
            markedReturns: false
        )
        installIsKindOfClassSwizzle(class: nsWindowClass)

        // Private/uncommon NSWindow methods that AppKit may consult to
        // identify a nonactivating panel:
        //
        //   `_isNonactivatingPanel` — private method that NSPanel overrides
        //   based on its styleMask. Adding this on NSWindow lets us
        //   return true regardless of class. If AppKit's panel-routing
        //   uses this check, our impersonation succeeds here.
        //
        //   `worksWhenModal` — public NSPanel method (returns true for
        //   nonactivating panels so they receive events during modal
        //   dialogs). Adding/overriding on NSWindow returns true for
        //   marked windows; AppKit sometimes uses this as a panel-ness
        //   heuristic.
        installPredicateSwizzle(
            class: nsWindowClass,
            selector: NSSelectorFromString("_isNonactivatingPanel"),
            markedReturns: true
        )
        installPredicateSwizzle(
            class: nsWindowClass,
            selector: NSSelectorFromString("worksWhenModal"),
            markedReturns: true
        )
    }

    /// Swizzles a `-(BOOL)method` on `cls`. For marked windows, the IMP
    /// returns `markedReturns`. For everything else, it forwards to the
    /// original IMP.
    private static func installBoolSwizzle(
        class cls: AnyClass,
        selector sel: Selector,
        markedReturns: Bool
    ) {
        guard let method = class_getInstanceMethod(cls, sel) else {
            logger.warning("Could not find -[\(NSStringFromClass(cls)) \(NSStringFromSelector(sel))]")
            return
        }
        let originalIMP = method_getImplementation(method)
        typealias OriginalFn = @convention(c) (AnyObject, Selector) -> Bool
        let originalFn = unsafeBitCast(originalIMP, to: OriginalFn.self)

        let replacement: @convention(block) (AnyObject) -> Bool = { instance in
            if isMarked(instance) { return markedReturns }
            return originalFn(instance, sel)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// Like `installBoolSwizzle` but uses `class_replaceMethod` so it can
    /// add methods that NSWindow doesn't originally have (e.g. private
    /// methods that only exist on NSPanel). For marked windows the IMP
    /// returns `markedReturns`; for everything else it forwards to the
    /// previous IMP if one existed, or returns the inverse default.
    private static func installPredicateSwizzle(
        class cls: AnyClass,
        selector sel: Selector,
        markedReturns: Bool
    ) {
        // Capture the existing implementation if any, so non-marked
        // instances behave like they did before our swizzle.
        let existingMethod = class_getInstanceMethod(cls, sel)
        let existingIMP: IMP? = existingMethod.map(method_getImplementation)
        let existingFn: ((AnyObject, Selector) -> Bool)?
        if let existingIMP {
            typealias OriginalFn = @convention(c) (AnyObject, Selector) -> Bool
            let fn = unsafeBitCast(existingIMP, to: OriginalFn.self)
            existingFn = { obj, s in fn(obj, s) }
        } else {
            existingFn = nil
        }

        let replacement: @convention(block) (AnyObject) -> Bool = { instance in
            if isMarked(instance) { return markedReturns }
            return existingFn?(instance, sel) ?? !markedReturns
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(replacement), "B@:")
    }

    /// Adds an `isKindOfClass:` override on NSWindow that claims NSPanel
    /// ancestry for marked instances. Non-marked instances see the
    /// original NSObject behavior. This is the same trick KVO itself
    /// uses to hide its dynamic subclasses.
    private static func installIsKindOfClassSwizzle(class cls: AnyClass) {
        let sel = NSSelectorFromString("isKindOfClass:")
        // The method is inherited from NSObject; look it up there.
        guard let method = class_getInstanceMethod(cls, sel) else {
            logger.warning("Could not find -[NSObject isKindOfClass:]")
            return
        }
        let originalIMP = method_getImplementation(method)
        typealias OriginalFn = @convention(c) (AnyObject, Selector, AnyClass) -> Bool
        let originalFn = unsafeBitCast(originalIMP, to: OriginalFn.self)

        let panelClass: AnyClass? = NSClassFromString("NSPanel")

        let replacement: @convention(block) (AnyObject, AnyClass) -> Bool = { instance, queryClass in
            if isMarked(instance), let panelClass, queryClass === panelClass {
                return true
            }
            return originalFn(instance, sel, queryClass)
        }
        // `class_replaceMethod` adds the method to NSWindow's dispatch table
        // directly so it overrides the inherited NSObject implementation
        // only for NSWindow instances. Returns the previous IMP (which is
        // NSObject's, since NSWindow didn't have its own).
        class_replaceMethod(cls, sel, imp_implementationWithBlock(replacement), "B@:#")
    }
}

#endif
