#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Keyboard events forwarded to whichever controller currently owns the
/// window's keyboard. Owners change on every focus handoff; the closures
/// installed on the keyboard never do.
enum TerminalTouchKeyboardEvent {
    case modifiersChanged(KeyModifiers)
    case dismiss, pinHidden, switchToSystemKeyboard, compose, paste, tabs, customize
    case toolbarAction(String)
    case heightChanged
    case placementRequested(TerminalTouchKeyboardModel.Placement)
    case nativePlacementChanged(TerminalTouchKeyboardModel.Placement)
    case docked
}

/// Runtime state scoped to a window, optionally partitioned by tab. One
/// keyboard, input root and input controller serve every terminal in the
/// window, so UIKit keeps the same input set while focus moves between them.
/// Weak window keys release everything when a scene closes.
@MainActor
final class TerminalTouchKeyboardWindowState {
    private static let windows = NSMapTable<UIWindow, TerminalTouchKeyboardWindowState>.weakToStrongObjects()
    private var states = TerminalTouchKeyboardModel.StateStore<TerminalFloatingKeyboardState>()
    private(set) weak var window: UIWindow?
    /// Controller whose terminal presents the keyboard. nil between a genuine
    /// focus loss and the next terminal claiming it.
    weak var owner: TerminalKeyboardAccessoryController?
    /// The state whose choices the live keyboard currently shows.
    private(set) var displayedState: TerminalFloatingKeyboardState?
    var overlay: TerminalFloatingKeyboardOverlay?

    private(set) lazy var keyboard: TerminalTouchKeyboardView = makeKeyboard()
    private(set) lazy var input: TerminalTouchKeyboardInputView = makeInput()
    private(set) lazy var toolbarInput = TerminalTouchKeyboardToolbarInputView(keyboard: keyboard)
    private(set) lazy var controller = TerminalTouchKeyboardInputController(keyboardInput: input)

    private init(window: UIWindow) { self.window = window }

    static func forWindow(_ window: UIWindow) -> TerminalTouchKeyboardWindowState {
        if let state = windows.object(forKey: window) { return state }
        let state = TerminalTouchKeyboardWindowState(window: window)
        windows.setObject(state, forKey: window)
        return state
    }

    func state(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        states.state(tabID: tabID, perTab: perTab) { TerminalFloatingKeyboardState() }
    }

    /// Select the state for a terminal and show it on the keyboard. The
    /// outgoing state's choices are captured first, so scope changes and
    /// per-tab switches always start from what the user last saw.
    func activate(tabID: UUID?, perTab: Bool) -> TerminalFloatingKeyboardState {
        snapshotDisplayedState()
        let selected = states.activate(tabID: tabID, perTab: perTab, make: { TerminalFloatingKeyboardState() }) {
            previous, selected in selected.copyChoices(from: previous)
        }
        display(selected)
        return selected
    }

    private func snapshotDisplayedState() {
        guard let displayedState else { return }
        displayedState.presentation = keyboard.presentationState
        displayedState.nativeFloatingPosition = input.floatingPosition
    }

    private func display(_ state: TerminalFloatingKeyboardState) {
        keyboard.setBackgroundEffectSurface(state.backgroundEffect)
        guard displayedState !== state else { return }
        displayedState = state
        input.restoreFloatingPosition(state.nativeFloatingPosition)
        let presentation = state.presentation ?? Self.initialPresentation()
        state.presentation = presentation
        keyboard.restorePresentationState(presentation)
        overlay?.updateState(state)
    }

    /// Fresh tabs start from the configured drawer default, not whichever
    /// state the keyboard happened to display before.
    private static func initialPresentation() -> TerminalTouchKeyboardModel.PresentationState {
        var initial = TerminalTouchKeyboardModel.PresentationState()
        if KeyboardToolbarManager.shared.drawerOpenByDefault {
            initial.toolbarDrawer = KeyboardToolbarManager.shared.drawerToggleMode == .cycle ? .cycling(0) : .stacked(1)
        }
        return initial
    }

    func dismissOverlay() {
        overlay?.detach()
        overlay = nil
    }

    private func makeKeyboard() -> TerminalTouchKeyboardView {
        let keyboard = TerminalTouchKeyboardView()
        keyboard.setBackgroundEffectSurface(nil)
        keyboard.onModifiersChanged = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.modifiersChanged($0)) }
        keyboard.onDismiss = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.dismiss) }
        keyboard.onPinHidden = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.pinHidden) }
        keyboard.onSwitchKeyboard = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.switchToSystemKeyboard) }
        keyboard.onCompose = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.compose) }
        keyboard.onPaste = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.paste) }
        keyboard.onTabs = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.tabs) }
        keyboard.onCustomize = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.customize) }
        keyboard.onToolbarAction = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.toolbarAction($0)) }
        keyboard.onPlacementRequested = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.placementRequested($0)) }
        return keyboard
    }

    private func makeInput() -> TerminalTouchKeyboardInputView {
        let input = TerminalTouchKeyboardInputView(keyboard: keyboard)
        input.hostSize = { [weak self] in self?.window?.bounds.size ?? .zero }
        input.onHeightChanged = { [weak self] in
            self?.toolbarInput.updateHeight()
            self?.owner?.handleTouchKeyboardEvent(.heightChanged)
        }
        input.onAppearanceChanged = { [weak self] in self?.toolbarInput.updateAppearance() }
        input.onNativePlacementChanged = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.nativePlacementChanged($0)) }
        input.shouldHideAfterDocking = { [weak self] in self?.owner?.touchKeyboardShouldHideAfterDocking == true }
        input.onDocked = { [weak self] in self?.owner?.handleTouchKeyboardEvent(.docked) }
        return input
    }
}

@MainActor
final class TerminalFloatingKeyboardState {
    var backgroundEffect = TerminalKeyboardEffectSurface()
    var nativeFloatingPosition: (origin: CGPoint, screen: UIScreen)?
    var presentation: TerminalTouchKeyboardModel.PresentationState?
    var temporarilyUseSystemKeyboard = false
    var requestedWithHardware = false
    var placement = TerminalTouchKeyboardModel.Placement.docked
    var anchor = CGPoint(x: 1, y: 0.85)

    func copyChoices(from other: TerminalFloatingKeyboardState) {
        guard self !== other else { return }
        // Move the live renderer with the visible choices when changing scope.
        // Swap ownership so separate tabs never retain the same effect surface.
        let previousEffect = backgroundEffect
        backgroundEffect = other.backgroundEffect
        other.backgroundEffect = previousEffect
        nativeFloatingPosition = other.nativeFloatingPosition
        presentation = other.presentation
        temporarilyUseSystemKeyboard = other.temporarilyUseSystemKeyboard
        requestedWithHardware = other.requestedWithHardware
        placement = other.placement
        anchor = other.anchor
    }
}

/// A scene-local overlay: only the floating card consumes touches. Everything
/// outside it continues to reach the terminal and the app's ordinary controls.
final class TerminalFloatingKeyboardOverlay: UIView {
    private let keyboard: TerminalTouchKeyboardView
    private var state: TerminalFloatingKeyboardState
    private var dragOrigin: CGRect?
    var onDock: (() -> Void)?
    var isHostActive: (() -> Bool)?

    init(keyboard: TerminalTouchKeyboardView, state: TerminalFloatingKeyboardState) {
        self.keyboard = keyboard
        self.state = state
        super.init(frame: .zero)
        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(keyboard)
        keyboard.onFloatingDrag = { [weak self] translation, ended in self?.move(translation, ended: ended) }
        keyboard.onFloatingDragCancelled = { [weak self] in self?.dragOrigin = nil }
        keyboard.onFloatingNudge = { [weak self] delta in self?.move(delta, ended: true, allowDock: false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateState(_ state: TerminalFloatingKeyboardState) {
        guard self.state !== state else { return }
        self.state = state
        dragOrigin = nil
        setNeedsLayout()
    }

    private var available: CGRect { bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 12) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard available.width > 0, available.height > 0 else { return }
        keyboard.floatingAvailableHeight = available.height
        let frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if keyboard.frame.size != frame.size {
            if keyboard.frame.width != frame.width { keyboard.cancelInteraction(preservingModifiers: true) }
            dragOrigin = nil
        }
        keyboard.frame = frame
    }

    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isHostActive?() == true, !isHidden, alpha > 0.01,
              keyboard.frame.contains(point) else { return nil }
        return keyboard.hitTest(convert(point, to: keyboard), with: event)
    }

    private func move(_ translation: CGPoint, ended: Bool, allowDock: Bool = true) {
        guard isHostActive?() == true else { return }
        if dragOrigin == nil { dragOrigin = keyboard.frame; keyboard.cancelInteraction(preservingModifiers: true) }
        guard let origin = dragOrigin else { return }
        let proposed = origin.offsetBy(dx: translation.x, dy: translation.y)
        state.anchor = TerminalTouchKeyboardModel.floatingAnchor(for: proposed, in: available)
        keyboard.frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if ended {
            dragOrigin = nil
            if allowDock && TerminalTouchKeyboardModel.shouldDockAfterDrag(proposed, in: available) { onDock?() }
        }
    }

    func detach() {
        // UIKit may already have mounted the compact toolbar host. A stale
        // overlay must not remove the keyboard from its new container.
        if keyboard.superview === self {
            keyboard.cancelInteraction(preservingModifiers: true)
            keyboard.onFloatingDrag = nil
            keyboard.onFloatingDragCancelled = nil
            keyboard.onFloatingNudge = nil
            keyboard.removeFromSuperview()
        }
        removeFromSuperview()
    }
}

#endif
