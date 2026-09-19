#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit

/// Keeps UIKit's input region self-sizing, including while content floats in
/// the app window. Only the ordinary content view may move between containers.
final class TerminalTouchKeyboardInputView: UIInputView {
    private let keyboard: TerminalTouchKeyboardView
    var hostSize: (() -> CGSize)?
    var shouldHideAfterDocking: (() -> Bool)?
    var onDocked: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    var onNativePlacementChanged: ((TerminalTouchKeyboardModel.Placement) -> Void)?
    private(set) var isNativeFloating = false
    private var suppressed = false
    private var awaitingFloatingLayout = false
    /// A hardware keyboard minimized the floating card into a full-width
    /// strip. UIKit restores the floating container on disconnect; until
    /// then the strip must not be mistaken for a user's dock.
    private var resumesNativeFloating = false
    /// iPadOS keeps the floating choice across launches, and a launch with a
    /// hardware keyboard attached never shows it to us. Remember the last one
    /// we saw so the first disconnect can hold the keys back too.
    private static let lastNativeFloatingKey = "terminalTouchKeyboardLastNativeFloating"
    private var hasObservedNativeLayout = false
    private var transitionFallback: DispatchWorkItem?
    private var transitionTask: Task<Void, Never>?
    private var heightConstraint: NSLayoutConstraint!
    private let floatingPanel = TerminalTouchKeyboardFloatingPanel()
    private var ownsFloatingDragCallbacks = false
    private var floatingPositionUpdateScheduled = false
    private var hostingGeneration = 0
    private var restoredFloatingPosition: (origin: CGPoint, screen: UIScreen)?
    private var floatingPositionDisplayLink: CADisplayLink?

    @MainActor
    private final class FloatingPositionObserver: NSObject {
        weak var input: TerminalTouchKeyboardInputView?

        @objc func update(_ link: CADisplayLink) {
            guard let input else {
                link.invalidate()
                return
            }
            input.maintainFloatingPosition()
        }
    }

    var floatingPosition: (origin: CGPoint, screen: UIScreen)? {
        if keyboard.usesSystemPlacement, isNativeFloating, !suppressed { floatingPanel.preservePosition() }
        return restoredFloatingPosition ?? floatingPanel.savedPosition
    }

    func restoreFloatingPosition(_ position: (origin: CGPoint, screen: UIScreen)?) {
        floatingPanel.detach()
        restoredFloatingPosition = position
    }

    func setUsesSystemPlacement(_ value: Bool) {
        guard keyboard.usesSystemPlacement != value else { return }
        // Restore UIKit's mask and center before the content changes hosts.
        // Keep the native anchor for a later return to the system container.
        let position = floatingPosition
        hostingGeneration += 1
        endFloatingHold()
        releaseFloatingPanel()
        restoredFloatingPosition = position
        keyboard.usesSystemPlacement = value
        setNeedsLayout()
    }

    init(keyboard: TerminalTouchKeyboardView) {
        self.keyboard = keyboard
        super.init(frame: keyboard.frame, inputViewStyle: .default)
        allowsSelfSizing = true
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = heightAnchor.constraint(equalToConstant: keyboard.intrinsicContentSize.height)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        keyboard.useContainerSizing()
        keyboard.onAppearanceChanged = { [weak self] in self?.updateAppearance() }
        // The root tracks content height itself, whether or not a terminal
        // currently owns the keyboard. Settings can change it while unowned.
        keyboard.onHeightChanged = { [weak self] in
            self?.updateHeight()
            self?.onHeightChanged?()
        }
        updateAppearance()
        attachKeyboard()
        transitionTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                guard !animating else { continue }
                self.finishKeyboardTransition()
                // Placement is left alone while UIKit animates the host;
                // restore the anchor once it has settled.
                if self.keyboard.usesSystemPlacement, self.isNativeFloating, !self.suppressed,
                   self.keyboard.superview === self, self.window != nil {
                    self.updateFloatingPanel()
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { transitionTask?.cancel() }
    /// Zero while suppressed and while waiting for UIKit to restore a floating
    /// container: a full-width interim host then has nothing to show.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: suppressed || awaitingFloatingLayout ? 0 : keyboard.intrinsicContentSize.height)
    }

    private var expectsNativeFloating: Bool {
        guard keyboard.usesSystemPlacement else { return false }
        if hasObservedNativeLayout { return isNativeFloating || resumesNativeFloating }
        return UserDefaults.standard.bool(forKey: Self.lastNativeFloatingKey)
    }

    func setSuppressed(_ value: Bool) {
        guard suppressed != value else { return }
        hostingGeneration += 1
        suppressed = value
        if value { releaseFloatingPanel() }
        keyboard.cancelInteraction(preservingModifiers: true)
        if !value && expectsNativeFloating { beginFloatingHold() }
        if keyboard.superview === self { keyboard.isHidden = value || awaitingFloatingLayout }
        updateAppearance()
        updateHeight()
    }

    /// Hold the keys back until a floating frame arrives, the show animation
    /// ends, or a short fallback elapses. UIKit can host the interim
    /// full-width strip without any keyboard animation at all.
    private func beginFloatingHold() {
        awaitingFloatingLayout = true
        transitionFallback?.cancel()
        let fallback = DispatchWorkItem { [weak self] in self?.finishKeyboardTransition() }
        transitionFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: fallback)
    }

    private func endFloatingHold() {
        transitionFallback?.cancel()
        transitionFallback = nil
        awaitingFloatingLayout = false
        resumesNativeFloating = false
    }

    private func finishKeyboardTransition() {
        guard awaitingFloatingLayout else { return }
        // A genuine system docking must still be honored once the transition
        // finishes, even if UIKit never restores a narrow floating container.
        endFloatingHold()
        updateHeight()
        setNeedsLayout()
    }

    func updateHeight() {
        let height = intrinsicContentSize.height
        guard abs(heightConstraint.constant - height) > 0.5 else { return }
        // Capture the visible position before UIKit resizes/recenters its host,
        // including when the user has not dragged the keyboard yet.
        if keyboard.usesSystemPlacement, isNativeFloating, !suppressed {
            floatingPanel.preservePosition()
        }
        heightConstraint.constant = height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateAppearance() {
        backgroundColor = suppressed || awaitingFloatingLayout
            || (keyboard.isFloating && !UIAccessibility.isReduceTransparencyEnabled)
            ? .clear : keyboard.containerBackgroundColor
        overrideUserInterfaceStyle = keyboard.overrideUserInterfaceStyle
    }

    override func layoutSubviews() {
        let size = hostSize?() ?? .zero
        // UIKit sends intermediate zero-size layouts while replacing input sets.
        // They are not a user's request to dock the floating keyboard.
        guard !suppressed, keyboard.superview === self, bounds.width > 0, size.width > 0 else {
            super.layoutSubviews()
            return
        }
        let floating = TerminalTouchKeyboardModel.isFloatingInput(
            width: bounds.width, hostWidth: size.width,
            isPad: traitCollection.userInterfaceIdiom == .pad)
        if awaitingFloatingLayout && !floating {
            // On hardware disconnect UIKit can first reuse its full-width
            // hardware host. Do not render docked keys into that interim frame.
            keyboard.isHidden = true
            super.layoutSubviews()
            return
        }
        if floating {
            endFloatingHold()
            updateAppearance()
        }
        if hasObservedNativeLayout == false || floating != isNativeFloating {
            hasObservedNativeLayout = true
            if keyboard.usesSystemPlacement { UserDefaults.standard.set(floating, forKey: Self.lastNativeFloatingKey) }
        }
        let docked = isNativeFloating && !floating
        let generation = hostingGeneration
        if docked && shouldHideAfterDocking?() == true {
            // A hardware keyboard minimized the floating card. Collapse the
            // existing self-sizing input root before it can grow to docked
            // height; replacing it with an empty UIView preserves the native
            // floating container's old frame on some iPadOS versions. Remember
            // the floating placement so the disconnect can restore it without
            // first rendering keys into the interim full-width host.
            isNativeFloating = false
            resumesNativeFloating = true
            setSuppressed(true)
            keyboard.setFloating(false)
            let dockingGeneration = hostingGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hostingGeneration == dockingGeneration,
                      !self.isNativeFloating, self.keyboard.superview === self else { return }
                self.onDocked?()
            }
            super.layoutSubviews()
            return
        }
        if floating != isNativeFloating {
            isNativeFloating = floating
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hostingGeneration == generation,
                      !self.suppressed, self.keyboard.superview === self,
                      self.isNativeFloating == floating else { return }
                self.onNativePlacementChanged?(floating ? .floating : .docked)
            }
        }
        // A native keyboard window may be only as tall as its current card.
        // Feeding that height back into row sizing shrinks the keys on each
        // layout. Use the display's height, independent of the current card.
        let availableHeight = keyboard.usesSystemPlacement
            ? (window?.windowScene?.screen.bounds.height ?? size.height) : size.height
        keyboard.floatingAvailableHeight = max(230, availableHeight - 48)
        keyboard.setFloating(floating)
        updateHeight()
        super.layoutSubviews()
        updateFloatingPanel()
        keyboard.isHidden = false
        // Our layout can run before UIKit finishes positioning the containing
        // host. Apply the anchor again after that enclosing layout has returned.
        if keyboard.usesSystemPlacement, isNativeFloating, !floatingPositionUpdateScheduled {
            floatingPositionUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.floatingPositionUpdateScheduled = false
                guard self.hostingGeneration == generation, self.window != nil else { return }
                self.updateFloatingPanel()
            }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window {
            hostingGeneration += 1
            if keyboard.usesSystemPlacement, isNativeFloating, !suppressed {
                // Capture before reparenting, but do not reset the old host's
                // center while our content is still visibly attached to it.
                floatingPanel.preservePosition()
                floatingPanel.cancelDrag()
            }
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseFloatingPanel()
        } else {
            setNeedsLayout()
        }
    }

    private func updateFloatingPanel() {
        guard keyboard.usesSystemPlacement, isNativeFloating, !suppressed,
              keyboard.superview === self else {
            releaseFloatingPanel()
            return
        }
        if let position = restoredFloatingPosition {
            floatingPanel.savedPosition = position
            restoredFloatingPosition = nil
        }
        floatingPanel.update(input: self, content: keyboard)
        if window != nil, floatingPositionDisplayLink == nil {
            let observer = FloatingPositionObserver()
            observer.input = self
            let link = CADisplayLink(target: observer, selector: #selector(FloatingPositionObserver.update(_:)))
            floatingPositionDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
        ownsFloatingDragCallbacks = true
        keyboard.onFloatingDrag = { [weak self] translation, ended in
            self?.moveFloatingPanel(translation, ended: ended)
        }
        keyboard.onFloatingDragCancelled = { [weak self] in self?.floatingPanel.cancelDrag() }
        keyboard.onFloatingNudge = { [weak self] delta in self?.moveFloatingPanel(delta, ended: true) }
    }

    private func moveFloatingPanel(_ translation: CGPoint, ended: Bool) {
        guard keyboard.usesSystemPlacement, isNativeFloating, !suppressed,
              keyboard.superview === self else { return }
        // A host may be replaced between input-root layout passes. Reacquire
        // it here too, so the handle never depends on toggling input views.
        floatingPanel.update(input: self, content: keyboard)
        floatingPanel.move(translation, ended: ended)
    }

    private func releaseFloatingPanel() {
        floatingPositionDisplayLink?.invalidate()
        floatingPositionDisplayLink = nil
        // UIKit can briefly remove or redock the input root during a responder
        // handoff. That is not a request to forget the floating screen anchor.
        floatingPanel.detach(preservingPosition: true)
        guard ownsFloatingDragCallbacks else { return }
        ownsFloatingDragCallbacks = false
        keyboard.onFloatingDrag = nil
        keyboard.onFloatingDragCancelled = nil
        keyboard.onFloatingNudge = nil
    }

    private func maintainFloatingPosition() {
        guard window != nil, keyboard.usesSystemPlacement, isNativeFloating,
              !suppressed, keyboard.superview === self else { return }
        // UIKit can move an ancestor without laying out this input view again.
        // Follow those changes through the whole responder transition, rather
        // than correcting only once on the next main-queue turn.
        floatingPanel.maintainPosition(input: self, content: keyboard)
    }

    func attachKeyboard() {
        guard keyboard.superview !== self else { return }
        // The system container can remain floating while our content lives in
        // the app overlay. Do not request docked height when reattaching to it.
        keyboard.setFloating(isNativeFloating)
        keyboard.isHidden = suppressed || awaitingFloatingLayout
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboard)
        NSLayoutConstraint.activate([
            keyboard.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboard.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboard.topAnchor.constraint(equalTo: topAnchor),
            keyboard.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateHeight()
    }
}

/// Retains a self-sizing input root across software/hardware presentation changes.
final class TerminalTouchKeyboardInputController: UIInputViewController {
    private let keyboardInput: TerminalTouchKeyboardInputView

    init(keyboardInput: TerminalTouchKeyboardInputView) {
        self.keyboardInput = keyboardInput
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { inputView = keyboardInput }
}

/// An app input view replaces the system keys, including their drag handle.
/// UIKit can nevertheless keep a taller floating hosting item (the old system
/// keyboard's footer). Clip that item to our card and move the item as a whole,
/// so rendering and hit testing travel together in the keyboard's own window.
/// No keyboard-window frame or private selector is changed.
@MainActor
private final class TerminalTouchKeyboardFloatingPanel {
    private weak var panel: UIView?
    private weak var content: UIView?
    private let cardMask = CAShapeLayer()
    private var baseCenter = CGPoint.zero
    private var lastAppliedCenter: CGPoint?
    private var desiredOrigin: CGPoint?
    private weak var positionScreen: UIScreen?
    private var originalMask: CALayer?
    private var dragOrigin: CGPoint?
    /// UIKit put the host back after a center we wrote. From then on its
    /// placement owns `center`; drags apply a translation transform instead,
    /// which that placement usually leaves alone. Restored on detach.
    private var placementRejected = false
    private var originalTransform = CGAffineTransform.identity

    var savedPosition: (origin: CGPoint, screen: UIScreen)? {
        get {
            guard let desiredOrigin, let positionScreen else { return nil }
            return (desiredOrigin, positionScreen)
        }
        set {
            desiredOrigin = newValue?.origin
            positionScreen = newValue?.screen
        }
    }

    func preservePosition() {
        guard desiredOrigin == nil, let panel, let content, let window = panel.window,
              content.isDescendant(of: panel) else { return }
        positionScreen = window.screen
        desiredOrigin = window.screen.coordinateSpace.convert(
            content.convert(content.bounds, to: window), from: window).origin
    }

    func update(input: UIView, content: UIView) {
        guard let window = input.window else { detach(preservingPosition: true); return }
        if let positionScreen, positionScreen !== window.screen { detach() }
        // Stop before the full-screen tracking view. Only the narrow hosting
        // item containing this input belongs to this floating keyboard.
        // A self-sizing pass can temporarily leave an ancestor at its old
        // height, including after a drawer toggle with no drag in progress.
        // Once found, never probe downward again: an inner view is laid out by
        // its parent, so moving it has no visible effect and strands the drag
        // handle. Climbing further up is allowed, because a host chosen during
        // presentation can itself be such an inner view.
        var candidate = input
        if let panel, panel.window === window, input.isDescendant(of: panel) { candidate = panel }
        while let parent = candidate.superview, parent !== window,
              abs(parent.bounds.width - input.bounds.width) < 1,
              parent.bounds.height >= input.bounds.height,
              parent.bounds.height <= input.bounds.height + 100 {
            candidate = parent
        }
        guard candidate !== input else { detach(preservingPosition: true); return }
        if panel !== candidate {
            detach(preservingPosition: true)
            panel = candidate
            baseCenter = candidate.center
            originalMask = candidate.layer.mask
            candidate.layer.mask = cardMask
        }
        self.content = content
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cardMask.frame = candidate.bounds
        cardMask.path = UIBezierPath(roundedRect: content.convert(content.bounds, to: candidate),
                                    cornerRadius: content.layer.cornerRadius).cgPath
        cardMask.fillColor = UIColor.black.cgColor
        CATransaction.commit()
        // Leave initial UIKit presentation alone, then retain the position
        // captured by a drag or a content-height change.
        if let desiredOrigin { position(at: desiredOrigin) }
    }

    func maintainPosition(input: UIView, content: UIView) {
        guard let window = input.window else { return }
        guard let panel, panel.window === window, input.isDescendant(of: panel),
              positionScreen == nil || positionScreen === window.screen,
              self.content === content else {
            update(input: input, content: content)
            return
        }
        // Geometry-only work: do not rebuild the mask or keyboard effect on
        // every frame. Normal input layout continues to own their sizing.
        // Once UIKit has rejected our placement it re-asserts it on every
        // layout pass; re-applying per frame only fights that. Drags still
        // move the card explicitly through the transform path.
        guard !placementRejected else { return }
        if let desiredOrigin { position(at: desiredOrigin) }
    }

    /// Store anchors in screen coordinates: UIKit may resize, move, or replace
    /// its window during an input-height change. Convert the window-space drag
    /// vector without incorporating the window's screen offset.
    func move(_ translation: CGPoint, ended: Bool) {
        guard let content, let window = panel?.window else { return }
        let space = window.screen.coordinateSpace
        positionScreen = window.screen
        if dragOrigin == nil {
            dragOrigin = space.convert(content.convert(content.bounds, to: window), from: window).origin
        }
        guard let origin = dragOrigin else { return }
        let start = space.convert(CGPoint.zero, from: window)
        let end = space.convert(translation, from: window)
        let destination = CGPoint(x: origin.x + end.x - start.x, y: origin.y + end.y - start.y)
        desiredOrigin = destination
        position(at: destination)
        if ended { dragOrigin = nil }
    }

    private func position(at origin: CGPoint) {
        guard let panel, let content, let window = panel.window,
              let parent = panel.superview else { return }
        // While UIKit animates the keyboard in, the host's center moves on
        // its own. Reading that as a rejected write would lock in an offset
        // measured mid-animation and strand the card somewhere else.
        guard !KeyboardTracker.shared.isKeyboardAnimating else { return }
        // Preserve UIKit's current scale/rotation. Capturing its transform at
        // attachment can freeze a transient pinch/presentation scale forever.
        if !placementRejected, panel.center != lastAppliedCenter {
            baseCenter = panel.center
            if let lastAppliedCenter {
                // UIKit re-asserted its own placement after our write, and it
                // keeps doing so after every later write. Writing center again
                // only makes the card fight and freeze: leave center to UIKit
                // and let drags move the card by transform instead. The saved
                // anchor is dropped; after a re-host UIKit decides where the
                // card sits.
                self.lastAppliedCenter = nil
                placementRejected = true
                originalTransform = panel.transform
                if dragOrigin == nil {
                    desiredOrigin = nil
                    return
                }
            }
        }
        let space = window.screen.coordinateSpace
        let frame = space.convert(content.convert(content.bounds, to: window), from: window)
        let available = space.bounds.inset(by: window.safeAreaInsets).insetBy(dx: 12, dy: 12)
        let proposed = CGRect(origin: origin, size: frame.size)
        let moved = TerminalTouchKeyboardModel.clampedFloatingDragFrame(proposed, in: available)
        // Clamping an intermediate resize frame must not replace the anchor:
        // UIKit can report a temporarily larger host before layout settles.
        let before = parent.convert(space.convert(frame.origin, to: window), from: window)
        let after = parent.convert(space.convert(moved.origin, to: window), from: window)
        guard abs(after.x - before.x) > 0.5 || abs(after.y - before.y) > 0.5 else { return }
        // Both deltas are in the parent's coordinates, so UIKit's own
        // transform is applied exactly once. No implicit animation may trail
        // the finger.
        UIView.performWithoutAnimation {
            if placementRejected {
                panel.transform = panel.transform.concatenating(
                    CGAffineTransform(translationX: after.x - before.x, y: after.y - before.y))
            } else {
                panel.center = CGPoint(x: panel.center.x + after.x - before.x,
                                       y: panel.center.y + after.y - before.y)
                lastAppliedCenter = panel.center
            }
        }
    }

    func cancelDrag() { dragOrigin = nil }

    func detach(preservingPosition: Bool = false) {
        if let panel {
            if panel.center == lastAppliedCenter { panel.center = baseCenter }
            if placementRejected { panel.transform = originalTransform }
            if panel.layer.mask === cardMask { panel.layer.mask = originalMask }
        }
        panel = nil
        content = nil
        originalMask = nil
        lastAppliedCenter = nil
        placementRejected = false
        originalTransform = .identity
        if !preservingPosition {
            desiredOrigin = nil
            positionScreen = nil
            dragOrigin = nil
        }
    }
}

#endif
