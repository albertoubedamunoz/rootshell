//
//  VisorController.swift
//  rootshell
//
//  Show/hide/toggle for the Quake-style visor terminal window. The visor
//  uses a SwiftUI WindowGroup but reconfigures the underlying NSWindow
//  into a non-activating panel through the Objective-C runtime so hotkey
//  summons do not activate the rest of the Catalyst application.
//

#if STANDALONE && targetEnvironment(macCatalyst)

import Foundation
import Combine
import UIKit
import CoreGraphics
import QuartzCore
import ObjectiveC
import Darwin
import os
import GhosttyKit

@MainActor
final class VisorController: NSObject, ObservableObject {
    static let shared = VisorController()

    @Published private(set) var isVisible = false
    /// Legacy SwiftUI visor content still observes this while that file
    /// remains in the target. The native visor does not render through it.
    @Published private(set) var contentRevealed = false
    @Published private(set) var suppressesTerminalResizeForAnimation = false

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "VisorController")

    private var animator: VisorFrameAnimator?
    private var panelResignKeyObserver: NSObjectProtocol?
    private var showTask: Task<Void, Never>?
    private var showGeneration = 0
    private var windowAttachmentContinuations: [CheckedContinuation<Void, Never>] = []
    private var contentHostContinuations: [CheckedContinuation<Void, Never>] = []
    private var lastConfiguredFrameSize: CGSize?
    private var resizeSuppressionGeneration = 0

    private struct ContentHost {
        let id: UUID
        let hasTerminal: @MainActor () -> Bool
        let ensureTerminal: @MainActor () async -> Bool
    }

    private var contentHost: ContentHost?

    private var nsWindow: NSObject? { VisorWindowBridge.shared.nsWindow }

    private override init() {
        super.init()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else { return }
        guard showTask == nil else { return }
        // Key eligibility must span the whole summon: configure()'s key
        // handoff and the key watchdog (VisorWindowAccessorView) must never
        // steer key status away from a window that is being summoned (a
        // first-ever summon runs configure() while the show is in flight).
        // Note showTask is cleared before animateIn and isVisible only flips
        // in the animation's onFinish, so this can't be derived from those.
        VisorWindowKeyOverride.visorShouldBeKey = true
        ensurePanel()
        showGeneration += 1
        let generation = showGeneration
        showTask = Task { @MainActor in
            await prepareAndAnimateIn(generation: generation)
        }
    }

    func hide() {
        showGeneration += 1
        showTask?.cancel()
        showTask = nil
        guard isVisible else {
            // A cancelled summon must drop key eligibility too.
            VisorWindowKeyOverride.visorShouldBeKey = false
            return
        }
        animateOut()
    }

    private func ensurePanel() {
        guard nsWindow == nil else { return }

        Self.logger.info("Requesting visor scene activation")
        // Mark a summon in flight so the launch backstop in
        // CatalystSceneDelegate.scene(_:willConnectTo:) does NOT mistake this
        // freshly-requested scene for a restored launch zombie and destroy it.
        VisorSceneLifecycle.beginSummon()
        let activity = NSUserActivity(activityType: "com.rootshell.visor")
        activity.targetContentIdentifier = "visor-terminal"
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: activity,
            options: nil,
            errorHandler: { error in
                Self.logger.error("Failed to activate visor scene: \(error.localizedDescription)")
            }
        )
    }

    func registerContentHost(
        id: UUID,
        hasTerminal: @escaping @MainActor () -> Bool,
        ensureTerminal: @escaping @MainActor () async -> Bool
    ) {
        contentHost = ContentHost(
            id: id,
            hasTerminal: hasTerminal,
            ensureTerminal: ensureTerminal
        )
        resumeContentHostWaiters()
    }

    func unregisterContentHost(id: UUID) {
        guard contentHost?.id == id else { return }
        contentHost = nil
    }

    func handleWindowAttached() {
        resumeWindowWaiters()
    }

    private func initialPanelFrame() -> CGRect {
        let settings = VisorSettings.shared
        let screenFrame = currentScreenVisibleFrame(choice: settings.screen) ?? .zero
        let size = settings.position.configuredFrameSize(
            visibleFrame: screenFrame,
            primary: settings.primarySize,
            secondary: settings.secondarySize
        )
        let origin = settings.position.initialOrigin(forSize: size, visibleFrame: screenFrame)
        return CGRect(origin: origin, size: size)
    }

    private func collectionBehavior() -> UInt {
        let canJoinAllSpaces: UInt = 1 << 0
        let moveToActiveSpace: UInt = 1 << 1
        let ignoresCycle: UInt = 1 << 6
        let fullScreenAuxiliary: UInt = 1 << 8

        switch VisorSettings.shared.spaceBehavior {
        case .move:
            return canJoinAllSpaces | fullScreenAuxiliary | ignoresCycle
        case .remain:
            return moveToActiveSpace | fullScreenAuxiliary | ignoresCycle
        }
    }

    // MARK: - Animation

    private func prepareAndAnimateIn(generation: Int) async {
        await waitForWindowAttachment()
        guard generation == showGeneration, !Task.isCancelled else { return }

        await waitForContentHost()
        guard generation == showGeneration, !Task.isCancelled else { return }

        let hasTerminal = await ensureContentHasTerminal()
        guard generation == showGeneration, !Task.isCancelled else { return }
        guard hasTerminal else {
            Self.logger.warning("Visor show cancelled because content host could not create a terminal")
            showTask = nil
            VisorWindowKeyOverride.visorShouldBeKey = false
            return
        }

        showTask = nil
        animateIn()
    }

    private func waitForWindowAttachment() async {
        if nsWindow != nil { return }
        await withCheckedContinuation { continuation in
            windowAttachmentContinuations.append(continuation)
        }
    }

    private func waitForContentHost() async {
        if contentHost != nil { return }
        await withCheckedContinuation { continuation in
            contentHostContinuations.append(continuation)
        }
    }

    private func ensureContentHasTerminal() async -> Bool {
        guard let contentHost else { return false }
        if contentHost.hasTerminal() { return true }
        return await contentHost.ensureTerminal()
    }

    private func resumeWindowWaiters() {
        let continuations = windowAttachmentContinuations
        windowAttachmentContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeContentHostWaiters() {
        let continuations = contentHostContinuations
        contentHostContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func animateIn() {
        guard let window = nsWindow else {
            Self.logger.warning("animateIn called without nsWindow after attachment wait")
            VisorWindowKeyOverride.visorShouldBeKey = false
            return
        }

        let settings = VisorSettings.shared
        guard let screenFrame = currentScreenVisibleFrame(choice: settings.screen) else {
            Self.logger.warning("Could not resolve screen visibleFrame")
            VisorWindowKeyOverride.visorShouldBeKey = false
            return
        }
        let size = settings.position.configuredFrameSize(
            visibleFrame: screenFrame,
            primary: settings.primarySize,
            secondary: settings.secondarySize
        )
        // Suppress only when the summon truly doesn't resize the window.
        // Comparing configured sizes alone is not enough: after a manual
        // drag-resize of the panel, setFrame below snaps the window back to
        // the configured size, and suppressing would drop that resize —
        // leaving the terminal grid at the dragged size (rows clipped past
        // the visible bottom) until some unrelated layout change.
        let currentFrame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
        let shouldSuppressTerminalResize = (lastConfiguredFrameSize?.isVisorEquivalent(to: size) ?? false)
            && currentFrame.size.isVisorEquivalent(to: size)
        lastConfiguredFrameSize = size
        let initialOrigin = settings.position.initialOrigin(forSize: size, visibleFrame: screenFrame)
        let finalOrigin = settings.position.finalOrigin(forSize: size, visibleFrame: screenFrame)

        beginTerminalResizeSuppression(if: shouldSuppressTerminalResize)

        window.setValue(collectionBehavior(), forKey: "collectionBehavior")
        window.setValue(NSNumber(value: 0.0), forKey: "alphaValue")
        window.setValue(Self.popUpMenuWindowLevel, forKey: "level")

        let setFrameSelector = NSSelectorFromString("setFrame:display:")
        if let method = window.method(for: setFrameSelector) {
            typealias SetFrameFn = @convention(c) (AnyObject, Selector, CGRect, ObjCBool) -> Void
            let fn = unsafeBitCast(method, to: SetFrameFn.self)
            fn(window, setFrameSelector, CGRect(origin: initialOrigin, size: size), ObjCBool(false))
        }

        orderFrontAndKey(window, orderFront: true)
        Ghostty.App.shared?.applyWindowBlur()

        contentRevealed = true

        animator?.cancel()
        let anim = VisorFrameAnimator(
            window: window,
            fromFrame: CGRect(origin: initialOrigin, size: size),
            toFrame: CGRect(origin: finalOrigin, size: size),
            fromAlpha: 0,
            toAlpha: 1,
            duration: settings.animationDuration,
            curve: .easeIn,
            onFinish: { [weak self] in
                guard let self else { return }
                window.setValue(Self.floatingWindowLevel, forKey: "level")
                self.isVisible = true
                self.orderFrontAndKey(window, orderFront: false)

                // A height mismatch here would mean the UIKit scene is being
                // laid out from a different size than the AppKit window shows
                // (styleMask strip side effect) — a separate sizing bug from
                // the resize-suppression drops.
                let nsFrame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
                let uiHeight = VisorWindowBridge.shared.uiWindow?.bounds.height ?? -1
                Self.logger.info("Visor summon complete: nsWindow=\(nsFrame.width)x\(nsFrame.height) uiWindowHeight=\(uiHeight)")

                self.endTerminalResizeSuppressionAfterTransition()

                if let panelResignKeyObserver {
                    NotificationCenter.default.removeObserver(panelResignKeyObserver)
                }
                panelResignKeyObserver = NotificationCenter.default.addObserver(
                    forName: Notification.Name("NSWindowDidResignKeyNotification"),
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handlePanelDidResignKey()
                    }
                }
            }
        )
        animator = anim
        anim.start()
    }

    private func orderFrontAndKey(_ window: NSObject, orderFront: Bool) {
        if orderFront {
            _ = window.perform(NSSelectorFromString("orderFrontRegardless"))
        }
        _ = window.perform(NSSelectorFromString("makeKeyWindow"))
        makeAppKitContentFirstResponder(for: window)
    }

    private func makeAppKitContentFirstResponder(for window: NSObject) {
        guard let contentView = window.value(forKey: "contentView") as? NSObject else { return }
        for candidate in appKitFirstResponderCandidates(from: contentView) {
            if makeFirstResponder(candidate, for: window) {
                return
            }
        }
    }

    private func makeFirstResponder(_ responder: NSObject, for window: NSObject) -> Bool {
        let selector = NSSelectorFromString("makeFirstResponder:")
        guard window.responds(to: selector), let method = window.method(for: selector) else { return false }
        typealias MakeFirstResponderFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
        let fn = unsafeBitCast(method, to: MakeFirstResponderFn.self)
        return fn(window, selector, responder)
    }

    private func appKitFirstResponderCandidates(from root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        func visit(_ view: NSObject) {
            if let subviews = view.value(forKey: "subviews") as? [NSObject] {
                for subview in subviews {
                    visit(subview)
                }
            }
            result.append(view)
        }
        visit(root)
        return result
    }

    private func animateOut() {
        guard let window = nsWindow else { return }
        let settings = VisorSettings.shared
        guard let screenFrame = currentScreenVisibleFrame(choice: settings.screen) else { return }

        let currentFrame = (window.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
        let size = currentFrame.size
        let shouldSuppressTerminalResize = lastConfiguredFrameSize?.isVisorEquivalent(to: size) ?? false
        let target = settings.position.initialOrigin(forSize: size, visibleFrame: screenFrame)

        beginTerminalResizeSuppression(if: shouldSuppressTerminalResize)

        window.setValue(Self.popUpMenuWindowLevel, forKey: "level")
        animator?.cancel()
        let anim = VisorFrameAnimator(
            window: window,
            fromFrame: currentFrame,
            toFrame: CGRect(origin: target, size: size),
            fromAlpha: 1,
            toAlpha: 0,
            duration: settings.animationDuration,
            curve: .easeOut,
            onFinish: { [weak self] in
                guard let self else { return }
                _ = window.perform(NSSelectorFromString("orderOut:"), with: nil)
                self.isVisible = false
                VisorWindowKeyOverride.visorShouldBeKey = false
                self.endTerminalResizeSuppressionAfterTransition()
            }
        )
        animator = anim
        anim.start()
    }

    private func beginTerminalResizeSuppression(if shouldSuppress: Bool) {
        resizeSuppressionGeneration += 1
        setResizeSuppression(shouldSuppress)
    }

    private func endTerminalResizeSuppressionAfterTransition() {
        let generation = resizeSuppressionGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard generation == resizeSuppressionGeneration else { return }
            setResizeSuppression(false)
        }
    }

    /// Sole writer of `suppressesTerminalResizeForAnimation`. Layout passes
    /// that land while the flag is set are dropped by
    /// TerminalSurfaceController and UIKit never re-fires them on its own,
    /// so every true→false transition must tell the visor's terminal views
    /// to re-send their current size.
    private func setResizeSuppression(_ newValue: Bool) {
        let wasSuppressing = suppressesTerminalResizeForAnimation
        suppressesTerminalResizeForAnimation = newValue
        if wasSuppressing && !newValue {
            NotificationCenter.default.post(name: .visorResizeSuppressionEnded, object: nil)
        }
    }

    private func handlePanelDidResignKey() {
        guard VisorSettings.shared.autohide, isVisible else { return }
        hide()
    }

    // MARK: - Screen selection

    /// visibleFrame in the AppKit coordinate space (origin = bottom-left).
    fileprivate func currentScreenVisibleFrame(choice: VisorScreenChoice) -> CGRect? {
        guard let nsScreenClass = NSClassFromString("NSScreen") as? NSObject.Type else {
            return nil
        }
        guard let screens = nsScreenClass.value(forKey: "screens") as? [NSObject], !screens.isEmpty else {
            return nil
        }

        let target: NSObject
        switch choice {
        case .main:
            target = (nsScreenClass.value(forKey: "mainScreen") as? NSObject) ?? screens[0]
        case .mouse:
            let cursor = mouseLocationInAppKit() ?? .zero
            target = screens.first(where: { screen in
                let frame = (screen.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
                return frame.contains(cursor)
            }) ?? screens[0]
        case .macosMenuBar:
            target = screens[0]
        }

        return (target.value(forKey: "visibleFrame") as? NSValue)?.cgRectValue
    }

    private func mouseLocationInAppKit() -> CGPoint? {
        guard let nsEventClass = NSClassFromString("NSEvent") as? NSObject.Type else { return nil }
        return (nsEventClass.value(forKey: "mouseLocation") as? NSValue)?.cgPointValue
    }

    fileprivate nonisolated static let floatingWindowLevel = 3
    fileprivate nonisolated static let popUpMenuWindowLevel = 101
}

private extension CGSize {
    func isVisorEquivalent(to other: CGSize) -> Bool {
        abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}

extension Notification.Name {
    /// Posted when `suppressesTerminalResizeForAnimation` transitions
    /// true→false. Visor terminal views respond by re-sending their current
    /// size, recovering any resize dropped during the suppression window.
    static let visorResizeSuppressionEnded = Notification.Name("com.rootshell.visorResizeSuppressionEnded")
}


// MARK: - Frame animator

@MainActor
private final class VisorFrameAnimator {
    private weak var window: NSObject?
    private let fromFrame: CGRect
    private let toFrame: CGRect
    private let fromAlpha: CGFloat
    private let toAlpha: CGFloat
    private let duration: TimeInterval
    private let curve: Curve
    private let onFinish: () -> Void

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var cancelled = false

    enum Curve {
        case easeIn
        case easeOut

        func apply(_ t: Double) -> Double {
            switch self {
            case .easeIn:  return t * t
            case .easeOut: return 1 - (1 - t) * (1 - t)
            }
        }
    }

    init(window: NSObject, fromFrame: CGRect, toFrame: CGRect,
         fromAlpha: CGFloat, toAlpha: CGFloat, duration: TimeInterval,
         curve: Curve, onFinish: @escaping () -> Void) {
        self.window = window
        self.fromFrame = fromFrame
        self.toFrame = toFrame
        self.fromAlpha = fromAlpha
        self.toAlpha = toAlpha
        self.duration = max(0.01, duration)
        self.curve = curve
        self.onFinish = onFinish
    }

    func start() {
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick(link)
    }

    func cancel() {
        cancelled = true
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !cancelled, let window else {
            cancel()
            return
        }
        let elapsed = CACurrentMediaTime() - startTime
        let raw = min(1.0, max(0.0, elapsed / duration))
        let t = curve.apply(raw)

        let frame = CGRect(
            x: fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * t,
            y: fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y) * t,
            width: fromFrame.size.width + (toFrame.size.width - fromFrame.size.width) * t,
            height: fromFrame.size.height + (toFrame.size.height - fromFrame.size.height) * t
        )
        let alpha = fromAlpha + (toAlpha - fromAlpha) * CGFloat(t)

        let selector = NSSelectorFromString("setFrame:display:")
        if let method = window.method(for: selector) {
            typealias SetFrameFn = @convention(c) (AnyObject, Selector, CGRect, ObjCBool) -> Void
            let fn = unsafeBitCast(method, to: SetFrameFn.self)
            fn(window, selector, frame, ObjCBool(true))
        }

        window.setValue(NSNumber(value: Double(alpha)), forKey: "alphaValue")

        if raw >= 1.0 {
            displayLink?.invalidate()
            displayLink = nil
            onFinish()
        }
    }
}

#endif
