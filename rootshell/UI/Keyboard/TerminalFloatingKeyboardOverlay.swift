import UIKit

/// Placement belongs to the terminal's window, and survives switching panes.
@MainActor
final class TerminalFloatingKeyboardState {
    private static let windows = NSMapTable<UIWindow, TerminalFloatingKeyboardState>.weakToStrongObjects()
    var placement = TerminalTouchKeyboardModel.Placement.docked
    var anchor = CGPoint(x: 1, y: 0.85)

    static func forWindow(_ window: UIWindow) -> TerminalFloatingKeyboardState {
        if let state = windows.object(forKey: window) { return state }
        let state = TerminalFloatingKeyboardState()
        windows.setObject(state, forKey: window)
        return state
    }
}

/// A scene-local overlay: only the floating card consumes touches. Everything
/// outside it continues to reach the terminal and the app's ordinary controls.
final class TerminalFloatingKeyboardOverlay: UIView {
    private let keyboard: TerminalTouchKeyboardView
    private let state: TerminalFloatingKeyboardState
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

    private var available: CGRect { bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 12) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard available.width > 0, available.height > 0 else { return }
        keyboard.floatingAvailableHeight = available.height
        let frame = TerminalTouchKeyboardModel.floatingFrame(in: available,
            height: keyboard.intrinsicContentSize.height, anchor: state.anchor)
        if keyboard.frame.size != frame.size {
            if keyboard.frame.width != frame.width { keyboard.cancelInteraction() }
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
        if dragOrigin == nil { dragOrigin = keyboard.frame; keyboard.cancelInteraction() }
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
        keyboard.cancelInteraction()
        keyboard.onFloatingDrag = nil
        keyboard.onFloatingDragCancelled = nil
        keyboard.onFloatingNudge = nil
        keyboard.removeFromSuperview()
        removeFromSuperview()
    }
}
