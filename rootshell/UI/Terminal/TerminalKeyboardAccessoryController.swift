//
//  TerminalKeyboardAccessoryController.swift
//  rootshell
//
//  Owns per-terminal keyboard accessory UI state on behalf of TerminalView.
//

import UIKit
import Combine
import os

@MainActor
protocol TerminalKeyboardAccessoryHost: AnyObject {
    var keyboardHostView: UIView { get }
    var keyboardIsFirstResponder: Bool { get }
    var keyboardAIAgentOverlayActive: Bool { get }
    var keyboardToolbarOnlyMode: Bool { get }
    var keyboardAccessoryHasBottomSafeAreaSpacer: Bool { get }

    @discardableResult
    func keyboardBecomeFirstResponder() -> Bool
    @discardableResult
    func keyboardResignFirstResponder() -> Bool
    func keyboardSetSoftwareKeyboardRequested(_ requested: Bool)
    func keyboardReloadInputViews()
    func keyboardStopShaderAnimationForDismiss()
    func keyboardSetShaderDismissSuppressed(_ suppressed: Bool)
    func keyboardInvalidateKeyCommands()
    func keyboardDidFinishAnimationLayout()
    func keyboardUpdateAccessoryForTraitCollection()
    func keyboardPaste()
    func keyboardToggleCompose()
    func keyboardToggleMouseCapture()
    func keyboardToggleBrightnessHUD()
}

extension TerminalKeyboardAccessoryHost {
    var keyboardAccessoryHasBottomSafeAreaSpacer: Bool { false }
}

@MainActor
final class TerminalKeyboardAccessoryController: NSObject {
    private weak var host: TerminalKeyboardAccessoryHost?

    var keyboardAccessory: KeyboardAccessoryView?
    #if os(visionOS)
    weak var externalToolbar: KeyboardToolbarView?
    #endif

    var shouldShowKeyboardToolbar = false
    var activeKeyboardModifiers: KeyModifiers = []
    var onActiveKeyboardModifiersChanged: ((KeyModifiers) -> Void)?
    var keyboardManuallyDismissed = false
    var toolbarOnlyMode = false {
        didSet {
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var keyboardPinnedHidden = false
    private(set) var bottomEdgeHomeGestureProtectionEnabled = false {
        didSet {
            guard oldValue != bottomEdgeHomeGestureProtectionEnabled else { return }
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var keyboardToolbarCollapsed = false {
        didSet {
            guard oldValue != keyboardToolbarCollapsed else { return }
            updateCollapsedKeyboardToolbarButtonVisibility()
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }
    var dismissTapStartPoint: CGPoint?

    private var collapsedKeyboardToolbarButton: UIButton?
    private var collapsedKeyboardToolbarButtonCenter: CGPoint?
    private var collapsedKeyboardToolbarButtonWasMoved = false
    private let collapsedKeyboardToolbarButtonSize = CGSize(width: 46, height: 46)
    private var emptyInputViewHeightConstraint: NSLayoutConstraint?
    private lazy var emptyInputView: UIView = {
        let view = UIView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraint = view.heightAnchor.constraint(equalToConstant: 0)
        constraint.isActive = true
        emptyInputViewHeightConstraint = constraint
        return view
    }()

    private var keyboardStateDebounceTimer: Timer?
    private var keyboardStateTask: Task<Void, Never>?
    private var keyboardVisibilityTask: Task<Void, Never>?
    private var keyboardAnimationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(host: TerminalKeyboardAccessoryHost) {
        self.host = host
    }

    var activeToolbarView: KeyboardToolbarView? {
        #if os(visionOS)
        return externalToolbar
        #else
        return keyboardAccessory?.toolbarView
        #endif
    }

    var reservesKeyboardToolbarAtBottom: Bool {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return false
        #else
        guard let host else { return false }
        return host.keyboardIsFirstResponder
            && !host.keyboardAIAgentOverlayActive
            && !keyboardToolbarCollapsed
            && (shouldShowKeyboardToolbar || toolbarOnlyMode)
        #endif
    }

    var reservedKeyboardToolbarHeightAtBottom: CGFloat {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return 0
        #else
        guard reservesKeyboardToolbarAtBottom,
              let host else { return 0 }
        let fallbackHeight = KeyboardSizes.current(traitCollection: host.keyboardHostView.traitCollection).toolbar.height
        if let accessoryHeight = keyboardAccessory?.bounds.height,
           accessoryHeight > 0 {
            return max(fallbackHeight, accessoryHeight)
        }
        let toolbarHeight = activeToolbarView?.bounds.height ?? 0
        if toolbarHeight > 0 {
            return max(fallbackHeight, toolbarHeight)
        }
        return max(fallbackHeight, keyboardAccessory?.intrinsicContentSize.height ?? fallbackHeight)
        #endif
    }

    var defersBottomSystemGesture: Bool {
        bottomEdgeHomeGestureProtectionEnabled
            && host?.keyboardIsFirstResponder == true
    }

    var inputAccessoryView: UIView? {
        guard let host else { return nil }
        let isVisible = shouldShowKeyboardToolbar
            && !host.keyboardAIAgentOverlayActive
            && !keyboardToolbarCollapsed
        updateBottomEdgeHomeGestureProtection(accessoryIsVisible: isVisible)
        return isVisible ? keyboardAccessory : nil
    }

    var inputView: UIView? {
        toolbarOnlyMode ? emptyInputView : nil
    }

    /// Empty primary input view used when a host wants the accessory docked
    /// without presenting the system software keyboard. This does not mutate
    /// the controller's user-driven persistent-toolbar state.
    var accessoryOnlyInputView: UIView {
        _ = emptyInputView
        emptyInputViewHeightConstraint?.constant = 0
        return emptyInputView
    }

    func setupKeyboard(delegate: KeyboardButtonDelegate) {
        guard let host else { return }

        #if !os(visionOS)
        keyboardAccessory = KeyboardAccessoryView(sizes: KeyboardSizes.current(traitCollection: host.keyboardHostView.traitCollection))
        keyboardAccessory?.delegate = delegate

        keyboardAccessory?.onModifiersChanged = { [weak self] modifiers in
            self?.activeKeyboardModifiers = modifiers
            self?.onActiveKeyboardModifiersChanged?(modifiers)
            Ghostty.logger.debug("TerminalView: Toolbar modifiers changed to rawValue: \(modifiers.rawValue)")
        }

        keyboardAccessory?.onDismissRequested = { [weak self] in
            guard let self else { return }
            if self.toolbarOnlyMode {
                self.exitToolbarOnlyMode()
            } else {
                let persistentToolbar = UserDefaults.standard.bool(forKey: "persistentToolbar")
                if persistentToolbar {
                    self.enterToolbarOnlyMode()
                } else {
                    self.keyboardManuallyDismissed = true
                    self.host?.keyboardSetShaderDismissSuppressed(true)
                    self.host?.keyboardStopShaderAnimationForDismiss()
                    _ = self.host?.keyboardResignFirstResponder()
                }
            }
        }

        keyboardAccessory?.onCollapseRequested = { [weak self] in
            self?.collapseKeyboardToolbar()
        }

        keyboardAccessory?.onPinHiddenRequested = { [weak self] in
            guard let self else { return }
            if self.keyboardPinnedHidden {
                self.exitToolbarOnlyMode()
            } else {
                self.keyboardPinnedHidden = true
                self.enterToolbarOnlyMode()
                self.keyboardAccessory?.setDismissButtonPinned(true)
            }
        }

        keyboardAccessory?.onTabSwitcherRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .showTabSwitcher, object: host)
        }

        keyboardAccessory?.onToolbarSettingsRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .showToolbarSettings, object: host)
        }

        keyboardAccessory?.onPasteRequested = { [weak self] in
            self?.host?.keyboardPaste()
        }

        keyboardAccessory?.onToggleFullScreenRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleFullScreen, object: host)
        }

        keyboardAccessory?.onToggleTabBarRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleTabBar, object: host)
        }

        keyboardAccessory?.onNewConnectionRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .newTab, object: host)
        }

        keyboardAccessory?.onAppSettingsRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .openSettings, object: host)
        }

        keyboardAccessory?.onComposeRequested = { [weak self] in
            self?.host?.keyboardToggleCompose()
        }

        keyboardAccessory?.onToggleMouseCaptureRequested = { [weak self] in
            self?.host?.keyboardToggleMouseCapture()
        }

        keyboardAccessory?.onBrightnessBoostRequested = { [weak self] in
            self?.host?.keyboardToggleBrightnessHUD()
        }

        keyboardAccessory?.onAIAgentRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleAIAgent, object: host)
        }

        keyboardAccessory?.onClipboardManagerRequested = { [weak host] in
            guard let host else { return }
            NotificationCenter.default.post(name: .toggleClipboardManager, object: host)
        }

        keyboardAccessory?.onLayoutInvalidated = { [weak self] in
            self?.refreshKeyboardLayoutAfterAccessoryChange()
        }

        let tabSwitcherObserver = NotificationCenter.default.addObserver(
            forName: .tabSwitcherVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let visible = notification.userInfo?["visible"] as? Bool
            Task { @MainActor [weak self] in
                guard let visible else { return }
                self?.keyboardAccessory?.setTabSwitcherActive(visible)
            }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(tabSwitcherObserver) })

        let hwToolbarObserver = NotificationCenter.default.addObserver(
            forName: .keyboardToolbarHardwareSettingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleKeyboardToolbarUpdate(reason: "hardwareToolbarSetting")
            }
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(hwToolbarObserver) })
        #endif

        let tracker = KeyboardTracker.shared
        let showWithHardware = UserDefaults.standard.bool(forKey: "showToolbarWithHardwareKeyboard")
        let initialShowToolbar = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
        shouldShowKeyboardToolbar = initialShowToolbar
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        let initialToolbarVisible = shouldShowKeyboardToolbar
        Ghostty.logger.debug(
            "TerminalView.setupKeyboard: Initial state - isHardware=\(tracker.isHardwareKeyboard), softwareVisible=\(tracker.isSoftwareKeyboardVisible), showToolbar=\(initialToolbarVisible)"
        )

        keyboardStateTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                guard let self else { break }
                self.scheduleKeyboardToolbarUpdate(reason: "hardware")
            }
        }

        keyboardVisibilityTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                guard let self else { break }
                self.scheduleKeyboardToolbarUpdate(reason: "softwareVisibility")
            }
        }

        keyboardAnimationTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                if !animating {
                    self.host?.keyboardDidFinishAnimationLayout()
                }
            }
        }

        host.keyboardHostView.registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { (view: UIView, _: UITraitCollection) in
            Task { @MainActor in
                guard let terminalHost = view as? TerminalKeyboardAccessoryHost else { return }
                terminalHost.keyboardUpdateAccessoryForTraitCollection()
            }
        }

        _ = host.keyboardBecomeFirstResponder()
        host.keyboardReloadInputViews()

        KeybindManager.shared.keybindsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                Task { @MainActor [weak self] in
                    self?.host?.keyboardInvalidateKeyCommands()
                    self?.host?.keyboardReloadInputViews()
                }
            }
            .store(in: &cancellables)

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        EffectManager.shared.keyboardStateDidChange
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.host?.keyboardReloadInputViews()
                    self?.updateCollapsedKeyboardToolbarButtonLayout()
                }
            }
            .store(in: &cancellables)
        #endif
    }

    func setupCollapsedKeyboardToolbarButton() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let host else { return }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.bounds = CGRect(origin: .zero, size: collapsedKeyboardToolbarButtonSize)
        button.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.62)
        button.tintColor = .label
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 0.5
        button.layer.borderColor = UIColor.separator.withAlphaComponent(0.55).cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.alpha = 0
        button.isHidden = true
        button.accessibilityLabel = String(localized: "Restore Keyboard Toolbar")

        let imageConfig = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        button.setImage(UIImage(systemName: "keyboard", withConfiguration: imageConfig), for: .normal)
        button.addTarget(self, action: #selector(restoreCollapsedKeyboardToolbar), for: .touchUpInside)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleCollapsedKeyboardToolbarButtonPan(_:)))
        button.addGestureRecognizer(panGesture)

        host.keyboardHostView.addSubview(button)
        collapsedKeyboardToolbarButton = button
        #endif
    }

    func tearDown() {
        keyboardStateDebounceTimer?.invalidate()
        keyboardStateDebounceTimer = nil
        keyboardStateTask?.cancel()
        keyboardStateTask = nil
        keyboardVisibilityTask?.cancel()
        keyboardVisibilityTask = nil
        keyboardAnimationTask?.cancel()
        keyboardAnimationTask = nil
        cancellables.removeAll()
    }

    func setAIAgentOverlayActive(_ active: Bool) {
        updateCollapsedKeyboardToolbarButtonVisibility()
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        host?.keyboardReloadInputViews()
    }

    func enterToolbarOnlyMode() {
        _ = emptyInputView
        emptyInputViewHeightConstraint?.constant = 0
        toolbarOnlyMode = true
        host?.keyboardSetSoftwareKeyboardRequested(false)
        host?.keyboardSetShaderDismissSuppressed(true)
        host?.keyboardStopShaderAnimationForDismiss()
        keyboardAccessory?.setDismissButtonShowsRestore(true)
        host?.keyboardReloadInputViews()
    }

    func exitToolbarOnlyMode() {
        keyboardPinnedHidden = false
        keyboardAccessory?.setDismissButtonPinned(false)
        toolbarOnlyMode = false
        host?.keyboardSetSoftwareKeyboardRequested(true)
        host?.keyboardSetShaderDismissSuppressed(false)
        keyboardAccessory?.setDismissButtonShowsRestore(false)
        host?.keyboardReloadInputViews()
    }

    func resetFocusLossState() {
        if toolbarOnlyMode {
            toolbarOnlyMode = false
            keyboardAccessory?.setDismissButtonShowsRestore(false)
        }
        if keyboardToolbarCollapsed {
            keyboardToolbarCollapsed = false
        }
    }

    func rearmPinnedHiddenIfNeeded() {
        if keyboardPinnedHidden && !toolbarOnlyMode {
            enterToolbarOnlyMode()
            keyboardAccessory?.setDismissButtonPinned(true)
        }
    }

    func hitTestCollapsedKeyboardToolbarButton(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard keyboardToolbarCollapsed,
              let button = collapsedKeyboardToolbarButton,
              !button.isHidden,
              button.alpha > 0.01,
              button.isUserInteractionEnabled,
              let host else {
            return nil
        }

        let buttonPoint = host.keyboardHostView.convert(point, to: button)
        return button.hitTest(buttonPoint, with: event)
        #else
        return nil
        #endif
    }

    func updateCollapsedKeyboardToolbarButtonLayout() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton,
              keyboardToolbarCollapsed else { return }

        button.bounds = CGRect(origin: .zero, size: collapsedKeyboardToolbarButtonSize)
        let targetCenter = collapsedKeyboardToolbarButtonWasMoved
            ? (collapsedKeyboardToolbarButtonCenter ?? defaultCollapsedKeyboardToolbarButtonCenter())
            : defaultCollapsedKeyboardToolbarButtonCenter()
        let clampedCenter = clampedCollapsedKeyboardToolbarButtonCenter(targetCenter)
        collapsedKeyboardToolbarButtonCenter = clampedCenter
        button.center = clampedCenter
        host?.keyboardHostView.bringSubviewToFront(button)
        #endif
    }

    private func collapseKeyboardToolbar() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        collapsedKeyboardToolbarButtonWasMoved = false
        collapsedKeyboardToolbarButtonCenter = defaultCollapsedKeyboardToolbarButtonCenter()
        keyboardToolbarCollapsed = true
        host?.keyboardReloadInputViews()
        updateCollapsedKeyboardToolbarButtonVisibility()
        #endif
    }

    @objc private func restoreCollapsedKeyboardToolbar() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        keyboardToolbarCollapsed = false
        if host?.keyboardIsFirstResponder != true {
            _ = host?.keyboardBecomeFirstResponder()
        }
        host?.keyboardReloadInputViews()
        #endif
    }

    private func updateCollapsedKeyboardToolbarButtonVisibility() {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton else { return }
        let shouldShowButton = keyboardToolbarCollapsed
            && host?.keyboardIsFirstResponder == true
            && host?.keyboardAIAgentOverlayActive != true

        if shouldShowButton {
            if collapsedKeyboardToolbarButtonCenter == nil {
                collapsedKeyboardToolbarButtonCenter = defaultCollapsedKeyboardToolbarButtonCenter()
            }
            updateCollapsedKeyboardToolbarButtonLayout()
            host?.keyboardHostView.bringSubviewToFront(button)
            button.isHidden = false
        }

        UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            button.alpha = shouldShowButton ? 0.82 : 0
        } completion: { _ in
            button.isHidden = !shouldShowButton
        }
        #endif
    }

    private func defaultCollapsedKeyboardToolbarButtonCenter() -> CGPoint {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let view = host?.keyboardHostView else { return .zero }
        let margin: CGFloat = 10
        let halfWidth = collapsedKeyboardToolbarButtonSize.width / 2
        let halfHeight = collapsedKeyboardToolbarButtonSize.height / 2
        let bottomLimit = view.bounds.maxY - view.safeAreaInsets.bottom

        let x = view.bounds.maxX - view.safeAreaInsets.right - margin - halfWidth
        let y = bottomLimit - margin - halfHeight
        return clampedCollapsedKeyboardToolbarButtonCenter(CGPoint(x: x, y: y))
        #else
        return .zero
        #endif
    }

    private func clampedCollapsedKeyboardToolbarButtonCenter(_ center: CGPoint) -> CGPoint {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let view = host?.keyboardHostView else { return center }
        let margin: CGFloat = 10
        let halfWidth = collapsedKeyboardToolbarButtonSize.width / 2
        let halfHeight = collapsedKeyboardToolbarButtonSize.height / 2
        let minX = view.bounds.minX + view.safeAreaInsets.left + margin + halfWidth
        let maxX = view.bounds.maxX - view.safeAreaInsets.right - margin - halfWidth
        let minY = view.bounds.minY + view.safeAreaInsets.top + margin + halfHeight
        let maxY = view.bounds.maxY - view.safeAreaInsets.bottom - margin - halfHeight

        return CGPoint(
            x: min(max(center.x, minX), max(minX, maxX)),
            y: min(max(center.y, minY), max(minY, maxY))
        )
        #else
        return center
        #endif
    }

    @objc private func handleCollapsedKeyboardToolbarButtonPan(_ gesture: UIPanGestureRecognizer) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let button = collapsedKeyboardToolbarButton else { return }
        let translation = gesture.translation(in: host?.keyboardHostView)
        var nextCenter = CGPoint(
            x: button.center.x + translation.x,
            y: button.center.y + translation.y
        )
        nextCenter = clampedCollapsedKeyboardToolbarButtonCenter(nextCenter)

        switch gesture.state {
        case .began, .changed:
            collapsedKeyboardToolbarButtonWasMoved = true
            button.center = nextCenter
            collapsedKeyboardToolbarButtonCenter = nextCenter
            gesture.setTranslation(.zero, in: host?.keyboardHostView)
        case .ended, .cancelled, .failed:
            collapsedKeyboardToolbarButtonWasMoved = true
            UIView.animate(withDuration: 0.16, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                button.center = nextCenter
            }
            collapsedKeyboardToolbarButtonCenter = nextCenter
        default:
            break
        }
        #endif
    }

    private func scheduleKeyboardToolbarUpdate(reason: String) {
        keyboardStateDebounceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateKeyboardToolbarVisibility(reason: reason)
            }
        }
        keyboardStateDebounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshKeyboardLayoutAfterAccessoryChange() {
        EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        host?.keyboardHostView.setNeedsLayout()
        host?.keyboardHostView.superview?.setNeedsLayout()
        host?.keyboardHostView.window?.setNeedsLayout()

        guard host?.keyboardIsFirstResponder == true else { return }

        host?.keyboardReloadInputViews()

        Task { @MainActor [weak self] in
            guard let self, self.host?.keyboardIsFirstResponder == true else { return }
            self.host?.keyboardReloadInputViews()
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
        }
    }

    private func updateKeyboardToolbarVisibility(reason: String) {
        let tracker = KeyboardTracker.shared
        let showWithHardware = UserDefaults.standard.bool(forKey: "showToolbarWithHardwareKeyboard")
        let newShouldShow = !tracker.isHardwareKeyboard || tracker.isSoftwareKeyboardVisible || showWithHardware
        if !newShouldShow && toolbarOnlyMode {
            toolbarOnlyMode = false
            keyboardAccessory?.setDismissButtonShowsRestore(false)
        }
        if !newShouldShow && keyboardPinnedHidden {
            keyboardPinnedHidden = false
            keyboardAccessory?.setDismissButtonPinned(false)
        }
        if !newShouldShow && keyboardToolbarCollapsed {
            keyboardToolbarCollapsed = false
        }
        if shouldShowKeyboardToolbar != newShouldShow {
            Ghostty.logger.debug(
                "TerminalView: Keyboard toolbar visibility updated (\(reason)) - isHardware=\(tracker.isHardwareKeyboard), softwareVisible=\(tracker.isSoftwareKeyboardVisible), showToolbar=\(newShouldShow)"
            )
            shouldShowKeyboardToolbar = newShouldShow
            EffectManager.shared.notifyKeyboardToolbarLayoutChanged()
            host?.keyboardReloadInputViews()
        }
        updateBottomEdgeHomeGestureProtection()
    }

    private func updateBottomEdgeHomeGestureProtection(accessoryIsVisible: Bool? = nil) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let idiom = UIDevice.current.userInterfaceIdiom
        let isVisible = accessoryIsVisible ?? (
            shouldShowKeyboardToolbar
                && host?.keyboardAIAgentOverlayActive != true
                && !keyboardToolbarCollapsed
        )
        let tracker = KeyboardTracker.shared
        let accessoryHeight = max(
            keyboardAccessory?.bounds.height ?? 0,
            keyboardAccessory?.intrinsicContentSize.height ?? 0
        )
        let safeAreaBottom = host?.keyboardHostView.window?.safeAreaInsets.bottom ?? 0
        let hardwareAccessoryOnly = tracker.isHardwareKeyboard
            && tracker.keyboardFrame.height <= accessoryHeight + safeAreaBottom + 2
        let toolbarIsAtScreenEdge = hardwareAccessoryOnly || !EffectManager.shared.isKeyboardDocked
        let enabled = (idiom == .phone || idiom == .pad)
            && isVisible
            && host?.keyboardAccessoryHasBottomSafeAreaSpacer != true
            && toolbarIsAtScreenEdge
        bottomEdgeHomeGestureProtectionEnabled = enabled
        keyboardAccessory?.setBottomEdgeHomeGestureProtectionEnabled(enabled)
        #else
        bottomEdgeHomeGestureProtectionEnabled = false
        keyboardAccessory?.setBottomEdgeHomeGestureProtectionEnabled(false)
        #endif
    }
}
