//
//  ImmersiveChromeManager.swift
//  rootshell
//
//  Auto-hides iOS/iPadOS chrome when the user enables Full Screen mode:
//  the status bar and home indicator on iPhone, plus iPadOS 26 window
//  controls on iPad.
//
//  Replaces the original `.immersiveChrome(...)` SwiftUI modifier
//  (e60dd821) which embedded a UIViewControllerRepresentable in the App
//  body and class-pair-swapped the root UIHostingController on every
//  body re-evaluation. That design caused the 0x8BADF00D scene-update
//  watchdog regression because:
//  - `updateUIViewController` ran applyToRoot on every App body re-eval
//    (and on iPad multi-window, every window's relay fired in lockstep)
//  - the per-VC class-pair-swap left a `_ImmersiveChrome_*` subclass on
//    the root UIHostingController that persisted permanently after the
//    first activation, perturbing SwiftUI's scene reconciliation
//  - a recursive `DispatchQueue.main.async` retry loop in applyToRoot
//    could spin during scene transitions
//
//  This replacement uses the same `method_setImplementation`-on-the-
//  hosting-controller-class approach as `StatusBarStyleManager`:
//  - Install once at app launch from a single `install()` call
//  - Swizzle each UIHostingController subclass at most once, replacing
//    the original IMP for prefersStatusBarHidden, prefersHomeIndicator-
//    AutoHidden, childForStatusBarHidden, childForHomeIndicatorAutoHidden
//  - When inactive, the override blocks call the saved original IMP, so
//    SwiftUI's default chrome routing is preserved
//  - The active state is a thread-safe flag toggled in response to
//    UserDefaults changes for the `fullScreenModeEnabled` key
//  - No SwiftUI lifecycle entanglement — no UIViewControllerRepresentable,
//    no per-body work, no per-window relay
//

import SwiftUI
import UIKit
import os
import ObjectiveC

#if !targetEnvironment(macCatalyst) && !os(visionOS)

@MainActor
final class ImmersiveChromeManager {
    static let shared = ImmersiveChromeManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "ImmersiveChrome")
    private nonisolated static let userDefaultsKey = "fullScreenModeEnabled"

    /// Thread-safe active flag. UIKit invokes the swizzled getters from
    /// main, but we use a lock anyway so a future caller from a different
    /// thread is safe and doesn't tear data.
    private nonisolated static let activeFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Transient immersion holds (VNC full-screen takeover). Counted so
    /// overlapping holders compose; independent of the persistent toggle.
    private nonisolated static let transientHolds = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Whether immersive chrome is currently active.
    nonisolated static var isActive: Bool {
        activeFlag.withLock { $0 } || transientHolds.withLock { $0 > 0 }
    }

    /// Begin a transient chrome hide (status bar + home indicator) that is
    /// not tied to the persistent Full Screen setting. Arms the swizzle on
    /// first use, exactly like the persistent path.
    func beginTransientImmersion() {
        Self.transientHolds.withLock { $0 += 1 }
        installSwizzleIfNeeded()
        swizzleExistingWindows()
        refreshChromeOnAllWindows()
    }

    /// End a transient chrome hide begun with `beginTransientImmersion()`.
    func endTransientImmersion() {
        Self.transientHolds.withLock { $0 = max(0, $0 - 1) }
        refreshChromeOnAllWindows()
    }

    private func refreshChromeOnAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
                window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }

    /// Marker associated with each UIHostingController subclass we have
    /// already swizzled, so we don't double-install.
    private static let markerKey = UnsafeRawPointer(bitPattern: "ImmersiveChromeSwizzled".hashValue)!

    private var isInstalled = false
    private var defaultsObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?

    private init() {
        // Seed the atomic with the persisted value so the first swizzle
        // sees the right state before `install()` is called.
        let initial = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        Self.activeFlag.withLock { $0 = initial }
    }

    /// Whether this device should ever swizzle. Mac Catalyst and visionOS
    /// do not have the UIKit status bar / home-indicator chrome this manager
    /// controls. On iPhone and iPad, swizzling is still deferred until the
    /// user enables fullscreen at least once.
    private static var isApplicableDevice: Bool {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone, .pad:
            return true
        default:
            return false
        }
    }

    /// Install observation for the `fullScreenModeEnabled` toggle.
    /// Idempotent. Swizzling itself is deferred to `installSwizzleIfNeeded`,
    /// which runs **only** when the user has actually enabled fullscreen at
    /// least once. A user who never toggles it on never has any
    /// UIHostingController methods replaced.
    func install() {
        guard Self.isApplicableDevice else { return }
        guard !isInstalled else { return }
        isInstalled = true
        let initial = Self.isActive
        Self.logger.info("Installing ImmersiveChromeManager (initial active=\(initial))")

        // Watch for the toggle. UserDefaults.didChangeNotification fires on
        // any key change in standard defaults; we re-read our key and only
        // act on transitions inside `handleActiveChange(to:)`.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            let nowActive = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
            Task { @MainActor in
                ImmersiveChromeManager.shared.handleActiveChange(to: nowActive)
            }
        }

        // If fullscreen was already on at launch (persisted), arm the
        // swizzle now and run an initial pass over current windows.
        // Otherwise we wait — `handleActiveChange` will do it on the first
        // false→true transition.
        if initial {
            installSwizzleIfNeeded()
        }
    }

    /// Set `true` once we have started observing windows for swizzling.
    /// Swizzling itself is per-class behind a separate associated-object
    /// marker, so this is just gating the *observer* setup.
    private var swizzleArmed = false

    /// First-true-transition arming: install the window observer and run
    /// the initial pass. This is the only place that ever subscribes to
    /// UIWindow.didBecomeKeyNotification, so iPad users who never toggle
    /// fullscreen on never observe windows or swizzle anything.
    private func installSwizzleIfNeeded() {
        guard Self.isApplicableDevice else { return }
        guard !swizzleArmed else { return }
        swizzleArmed = true
        Self.logger.info("Arming UIHostingController swizzle (first fullscreen activation)")

        // Swizzle the hosting-controller class of every new key window.
        // Each distinct UIHostingController subclass is swizzled at most
        // once via the associated-object marker.
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? UIWindow else { return }
            Task { @MainActor in
                ImmersiveChromeManager.shared.swizzleHostingControllerIfNeeded(for: window)
            }
        }

        // Swizzle any existing windows synchronously after the current
        // dispatch frame so SwiftUI has a chance to install its root VC.
        DispatchQueue.main.async {
            ImmersiveChromeManager.shared.swizzleExistingWindows()
        }
    }

    private func handleActiveChange(to nowActive: Bool) {
        let previous = Self.activeFlag.withLock { state -> Bool in
            let p = state
            state = nowActive
            return p
        }
        guard previous != nowActive else { return }
        Self.logger.info("Active changed: \(previous) -> \(nowActive)")
        // First false→true transition arms the swizzle. Once armed, the
        // swizzle stays in place for the lifetime of the process (matching
        // the behavior of class-pair-swap before).
        if nowActive {
            installSwizzleIfNeeded()
        }
        refreshChromeOnAllWindows()
    }

    private func swizzleExistingWindows() {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                swizzleHostingControllerIfNeeded(for: window)
            }
        }
    }

    private func swizzleHostingControllerIfNeeded(for window: UIWindow) {
        guard let rootVC = window.rootViewController else { return }
        swizzleIfHostingController(rootVC)
    }

    private func swizzleIfHostingController(_ vc: UIViewController) {
        let className = NSStringFromClass(type(of: vc))
        guard className.contains("HostingController") else { return }

        let vcClass: AnyClass = type(of: vc)
        if objc_getAssociatedObject(vcClass, Self.markerKey) != nil {
            return
        }
        objc_setAssociatedObject(vcClass, Self.markerKey, true, .OBJC_ASSOCIATION_RETAIN)

        Self.logger.info("Swizzling chrome getters on class \(className)")

        // Bool getters: prefersStatusBarHidden, prefersHomeIndicatorAutoHidden.
        // When active we return true; when inactive we delegate to the
        // original UIHostingController implementation.
        installBoolOverride(
            on: vcClass,
            selector: #selector(getter: UIViewController.prefersStatusBarHidden)
        )
        installBoolOverride(
            on: vcClass,
            selector: #selector(getter: UIViewController.prefersHomeIndicatorAutoHidden)
        )
        // Child getters: childForStatusBarHidden, childForHomeIndicatorAutoHidden.
        // When active we return nil so UIKit uses the root VC's overridden
        // bool value. When inactive we delegate so SwiftUI's child routing
        // (sheets, nav stacks, etc.) is preserved.
        installChildOverride(
            on: vcClass,
            selector: #selector(getter: UIViewController.childForStatusBarHidden)
        )
        installChildOverride(
            on: vcClass,
            selector: #selector(getter: UIViewController.childForHomeIndicatorAutoHidden)
        )

        // If the toggle is already on at swizzle time (e.g. user had Full
        // Screen enabled at launch), kick UIKit to re-query.
        if Self.isActive {
            vc.setNeedsStatusBarAppearanceUpdate()
            vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    private typealias BoolGetterIMP = @convention(c) (AnyObject, Selector) -> Bool
    private typealias ChildGetterIMP = @convention(c) (AnyObject, Selector) -> UIViewController?

    private func installBoolOverride(on cls: AnyClass, selector: Selector) {
        guard let method = class_getInstanceMethod(cls, selector) else {
            let className = NSStringFromClass(cls)
            let selName = NSStringFromSelector(selector)
            Self.logger.warning("No method \(selName) on \(className)")
            return
        }
        let originalIMP = method_getImplementation(method)
        let originalFn = unsafeBitCast(originalIMP, to: BoolGetterIMP.self)
        let block: @convention(block) (UIViewController) -> Bool = { vc in
            if ImmersiveChromeManager.isActive { return true }
            return originalFn(vc, selector)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
    }

    private func installChildOverride(on cls: AnyClass, selector: Selector) {
        guard let method = class_getInstanceMethod(cls, selector) else {
            let className = NSStringFromClass(cls)
            let selName = NSStringFromSelector(selector)
            Self.logger.warning("No method \(selName) on \(className)")
            return
        }
        let originalIMP = method_getImplementation(method)
        let originalFn = unsafeBitCast(originalIMP, to: ChildGetterIMP.self)
        let block: @convention(block) (UIViewController) -> UIViewController? = { vc in
            if ImmersiveChromeManager.isActive { return nil }
            return originalFn(vc, selector)
        }
        let newIMP = imp_implementationWithBlock(block)
        method_setImplementation(method, newIMP)
    }
}

// MARK: - Install hook

private struct ImmersiveChromeInstallModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            ImmersiveChromeManager.shared.install()
        }
    }
}

extension View {
    /// Installs the fullscreen chrome auto-hide manager on the first
    /// appearance. Idempotent. Safe to apply on every platform — compiles
    /// to a no-op modifier on Mac Catalyst and visionOS.
    func immersiveChromeForFullScreen() -> some View {
        modifier(ImmersiveChromeInstallModifier())
    }
}

#else

// Mac Catalyst / visionOS: no status bar / home indicator chrome to hide.
extension View {
    func immersiveChromeForFullScreen() -> some View {
        self
    }
}

#endif
