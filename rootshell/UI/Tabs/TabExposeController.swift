//
//  TabExposeController.swift
//  rootshell
//
//  State machine for the tab exposé: which tabs are in scope, where the
//  reveal is (0 hidden … 1 presented), what the hero tab is, and the
//  progress spring that settles commit/cancel/select. Per window, owned by
//  MainView. `TabExposeView` renders it and drives `tick(now:)` from its
//  display link; MainView supplies the occlusion / tab-switch hooks.
//

import UIKit
import Observation

@MainActor
protocol TabExposeControllerObserver: AnyObject {
    /// `isActive` flipped: start/stop rendering.
    func tabExposeDidChangeActivity(_ controller: TabExposeController)
    /// Scope, hero, or highlight changed: rebuild/refresh cells.
    func tabExposeDidChangeCells(_ controller: TabExposeController)
}

@MainActor
@Observable
final class TabExposeController {
    enum Phase: Equatable {
        case hidden
        /// Finger/trackpad is driving `progress`.
        case interactive
        /// Spring is driving `progress` toward `target` (0 or 1).
        case settling(target: CGFloat)
        case presented
    }

    private enum InteractiveMode {
        case reveal
        case dismiss
    }

    // MARK: - State

    private(set) var phase: Phase = .hidden
    /// Tabs in the current scope, in navigation order.
    private(set) var tabIDs: [UUID] = []
    private(set) var scopeTitle: String?
    /// Shown in the scope header; nil in flat mode.
    private(set) var isScoped = false
    /// The tab whose full-size live picture slides in/out with the tray.
    private(set) var heroTabID: UUID?
    var highlightedTabID: UUID? {
        didSet { if highlightedTabID != oldValue { observer?.tabExposeDidChangeCells(self) } }
    }
    var isActive: Bool { phase != .hidden }

    /// 0 hidden … 1 presented (may overshoot slightly). Read per frame by the
    /// view; deliberately not observed so scrubbing never invalidates SwiftUI.
    @ObservationIgnored private(set) var progress: CGFloat = 0
    /// Set by the view after layout so ↑/↓ move by a row.
    @ObservationIgnored var columns: Int = 1

    // MARK: - Wiring

    @ObservationIgnored weak var tabsModel: TabsModel?
    @ObservationIgnored weak var observer: TabExposeControllerObserver?
    /// Un-occlude scope tabs (and anything else the host needs before showing).
    @ObservationIgnored var onWillPresent: (([UUID]) -> Void)?
    /// Restore occlusion after the overlay is gone.
    @ObservationIgnored var onDidDismiss: (() -> Void)?
    /// Switch the real selection; the overlay stays until the tab is displayed.
    @ObservationIgnored var onSelect: ((UUID) -> Void)?
    @ObservationIgnored var onCommitHaptic: (() -> Void)?
    @ObservationIgnored var reduceMotion: () -> Bool = { false }
    /// The terminal carrying `presentedOverlayKeyHandler` while presented.
    @ObservationIgnored weak var keyHandlerTerminal: Ghostty.TerminalView?

    static func isModifierOnly(_ key: UIKey) -> Bool {
        switch key.keyCode {
        case .keyboardLeftControl, .keyboardLeftShift, .keyboardLeftAlt, .keyboardLeftGUI,
             .keyboardRightControl, .keyboardRightShift, .keyboardRightAlt, .keyboardRightGUI,
             .keyboardCapsLock:
            return true
        default:
            return false
        }
    }

    // MARK: - Private

    @ObservationIgnored private var interactiveMode: InteractiveMode = .reveal
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var springResponse: CGFloat = 0.32
    @ObservationIgnored private var springDamping: CGFloat = 0.86
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    /// After a select settles to 0, wait for the real tab to be displayed before hiding.
    @ObservationIgnored private var hideDeadline: CFTimeInterval = 0
    @ObservationIgnored private var pendingSelectedTabID: UUID?
    @ObservationIgnored private var scopeObservationArmed = false

    // MARK: - Interactive reveal / dismiss

    /// A pull started. From hidden this is a reveal; from presented (or a
    /// settle) the finger takes over wherever the tray currently is.
    func beginInteractive() {
        switch phase {
        case .hidden:
            guard activate() else { return }
            interactiveMode = .reveal
            progress = 0
        case .presented:
            interactiveMode = .dismiss
        case .settling(let target):
            interactiveMode = target >= 1 ? .reveal : .dismiss
        case .interactive:
            break
        }
        velocity = 0
        phase = .interactive
    }

    /// `signed` is the gesture's distance/length, down-positive: a reveal
    /// pulls down from 0, a dismiss pushes up from 1.
    func updateInteractive(signed: CGFloat) {
        guard phase == .interactive else { return }
        let p: CGFloat
        switch interactiveMode {
        case .reveal: p = signed
        case .dismiss: p = 1 + signed
        }
        progress = rubberBanded(p)
    }

    /// Release. `velocity` is along the gesture axis, down-positive, pt/s.
    func endInteractive(velocity v: CGFloat) {
        guard phase == .interactive else { return }
        let commit: Bool
        switch interactiveMode {
        case .reveal:
            commit = progress >= 0.25 || v > 600
            if commit { onCommitHaptic?() }
            settle(to: commit ? 1 : 0, fast: !commit)
        case .dismiss:
            commit = progress <= 0.75 || v < -600
            settle(to: commit ? 0 : 1, fast: commit)
        }
    }

    func cancelInteractive() {
        guard phase == .interactive else { return }
        switch interactiveMode {
        case .reveal: settle(to: 0, fast: true)
        case .dismiss: settle(to: 1, fast: false)
        }
    }

    // MARK: - Programmatic

    func toggle() {
        if isActive {
            cancel()
        } else {
            present()
        }
    }

    func present() {
        guard !isActive, activate() else { return }
        progress = 0
        settle(to: 1, fast: false)
    }

    /// Dismiss without changing the selection.
    func cancel() {
        guard isActive else { return }
        pendingSelectedTabID = nil
        heroTabID = tabsModel?.selectedTabID ?? heroTabID
        observer?.tabExposeDidChangeCells(self)
        settle(to: 0, fast: true)
    }

    /// Switch to `id`: it becomes the hero that slides back in while the
    /// tray leaves; the real selection changes immediately.
    func select(_ id: UUID) {
        guard isActive, tabIDs.contains(id) else { return }
        heroTabID = id
        highlightedTabID = id
        pendingSelectedTabID = id
        observer?.tabExposeDidChangeCells(self)
        if tabsModel?.selectedTabID != id {
            onSelect?(id)
        }
        settle(to: 0, fast: false)
    }

    /// Immediate teardown (scene background, scope emptied).
    func forceHide(reason: String) {
        guard isActive else { return }
        progress = 0
        velocity = 0
        finishHide()
    }

    // MARK: - Highlight / keyboard

    func moveHighlight(by delta: Int, wrap: Bool) {
        guard !tabIDs.isEmpty else { return }
        let current = highlightedTabID.flatMap { tabIDs.firstIndex(of: $0) } ?? 0
        var next = current + delta
        if wrap {
            next = ((next % tabIDs.count) + tabIDs.count) % tabIDs.count
        } else {
            next = min(max(next, 0), tabIDs.count - 1)
        }
        highlightedTabID = tabIDs[next]
    }

    /// Keys routed from the focused terminal while presented. Returns false
    /// for anything the exposé doesn't own (the host dismisses and lets it through).
    func handleKey(_ key: UIKey) -> Bool {
        guard isActive else { return false }
        switch key.keyCode {
        case .keyboardEscape:
            cancel()
            return true
        case .keyboardReturnOrEnter, .keyboardSpacebar:
            if let id = highlightedTabID { select(id) } else { cancel() }
            return true
        case .keyboardLeftArrow:
            moveHighlight(by: -1, wrap: true)
            return true
        case .keyboardRightArrow:
            moveHighlight(by: 1, wrap: true)
            return true
        case .keyboardUpArrow:
            moveHighlight(by: -max(columns, 1), wrap: false)
            return true
        case .keyboardDownArrow:
            moveHighlight(by: max(columns, 1), wrap: false)
            return true
        case .keyboardTab:
            moveHighlight(by: key.modifierFlags.contains(.shift) ? -1 : 1, wrap: true)
            return true
        case .keyboardHome:
            highlightedTabID = tabIDs.first
            return true
        case .keyboardEnd:
            highlightedTabID = tabIDs.last
            return true
        default:
            break
        }
        if key.modifierFlags.isDisjoint(with: [.control, .alternate]),
           key.characters.count == 1,
           let digit = key.characters.first?.wholeNumberValue,
           (1...9).contains(digit),
           digit <= tabIDs.count {
            select(tabIDs[digit - 1])
            return true
        }
        return false
    }

    // MARK: - Ticking (driven by the view's display link)

    /// Advance the settle spring. Returns true while the overlay needs frames.
    @discardableResult
    func tick(now: CFTimeInterval) -> Bool {
        defer { lastTick = now }
        guard isActive else { return false }

        if case .settling(let target) = phase {
            let dt = lastTick == 0 ? 1.0 / 60.0 : min(max(now - lastTick, 0), 1.0 / 20.0)
            stepSpring(toward: target, dt: CGFloat(dt))
            if abs(progress - target) < 0.002, abs(velocity) < 0.01 {
                progress = target
                velocity = 0
                if target >= 1 {
                    phase = .presented
                } else {
                    settledAtZero(now: now)
                }
            }
        } else if phase == .hidden {
            return false
        }
        return isActive
    }

    private func settledAtZero(now: CFTimeInterval) {
        // A select waits (briefly) for the real tab to be displayed so the
        // swap under the overlay is invisible.
        if let pending = pendingSelectedTabID {
            if hideDeadline == 0 { hideDeadline = now + 0.6 }
            let displayed = tabsModel?.displayedTabID
            guard displayed == pending || now >= hideDeadline else { return }
        }
        finishHide()
    }

    private func stepSpring(toward target: CGFloat, dt: CGFloat) {
        let omega = 2 * CGFloat.pi / max(springResponse, 0.05)
        let accel = -omega * omega * (progress - target) - 2 * springDamping * omega * velocity
        velocity += accel * dt
        progress += velocity * dt
    }

    // MARK: - Internals

    /// Snapshot the scope and tell the host we're about to show. False if there is nothing to show.
    private func activate() -> Bool {
        guard let tabsModel else { return false }
        refreshScope(announce: false)
        guard !tabIDs.isEmpty else { return false }
        heroTabID = tabsModel.selectedTabID
        highlightedTabID = tabsModel.selectedTabID.flatMap { tabIDs.contains($0) ? $0 : nil } ?? tabIDs.first
        pendingSelectedTabID = nil
        hideDeadline = 0
        lastTick = 0
        onWillPresent?(tabIDs)
        phase = .interactive
        observer?.tabExposeDidChangeActivity(self)
        observer?.tabExposeDidChangeCells(self)
        armScopeObservation()
        return true
    }

    private func settle(to target: CGFloat, fast: Bool) {
        if reduceMotion() {
            progress = target
            velocity = 0
            if target >= 1 {
                phase = .presented
                observer?.tabExposeDidChangeCells(self)
            } else {
                phase = .settling(target: 0)
                settledAtZero(now: CACurrentMediaTime())
            }
            return
        }
        springResponse = fast ? 0.26 : 0.32
        springDamping = fast ? 0.9 : 0.86
        hideDeadline = 0
        phase = .settling(target: target)
    }

    private func finishHide() {
        phase = .hidden
        progress = 0
        velocity = 0
        pendingSelectedTabID = nil
        hideDeadline = 0
        scopeObservationArmed = false
        observer?.tabExposeDidChangeActivity(self)
        onDidDismiss?()
    }

    private func rubberBanded(_ p: CGFloat) -> CGFloat {
        if p <= 0 { return 0 }
        if p <= 1 { return p }
        return 1 + 0.08 * tanh((p - 1) * 4)
    }

    /// Re-read the scope from the model. Tabs that left are dropped (their
    /// cells vanish); a new selection made elsewhere becomes a select.
    func refreshScope(announce: Bool = true) {
        guard let tabsModel else { return }
        let projection = tabsModel.orderProjection
        let ids = projection.navigationTabIDs
        let title = projection.activeScopeTitle
        let scoped: Bool = {
            if case .flat = projection.mode { return false }
            return true
        }()
        let changed = ids != tabIDs || title != scopeTitle || scoped != isScoped
        tabIDs = ids
        scopeTitle = title
        isScoped = scoped
        guard isActive else { return }

        if ids.isEmpty {
            forceHide(reason: "scopeEmpty")
            return
        }
        if let h = highlightedTabID, !ids.contains(h) {
            highlightedTabID = ids.first
        }
        if let selected = tabsModel.selectedTabID, selected != heroTabID,
           ids.contains(selected), pendingSelectedTabID == nil || pendingSelectedTabID != selected {
            // Selection changed under us (⌘N, sidebar...): ride it out as a select.
            if phase == .presented || phase == .interactive {
                select(selected)
                return
            }
            heroTabID = selected
        } else if let hero = heroTabID, !ids.contains(hero) {
            heroTabID = tabsModel.selectedTabID
        }
        if changed, announce {
            observer?.tabExposeDidChangeCells(self)
        }
    }

    private func armScopeObservation() {
        guard isActive, let tabsModel else { return }
        scopeObservationArmed = true
        withObservationTracking {
            _ = tabsModel.orderProjection
            _ = tabsModel.selectedTabID
            _ = tabsModel.displayedTabID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.scopeObservationArmed else { return }
                self.refreshScope()
                self.armScopeObservation()
            }
        }
    }
}
