//
//  KeyboardAccessoryView.swift
//  rootshell
//
//  UIInputView wrapper for keyboard toolbar
//

import UIKit

class KeyboardAccessoryView: UIInputView {
    // MARK: - Properties

    private(set) var toolbarView: KeyboardToolbarView
    weak var delegate: KeyboardButtonDelegate? {
        didSet {
            toolbarView.delegate = delegate
        }
    }

    /// Callback when toolbar modifiers change
    var onModifiersChanged: ((KeyModifiers) -> Void)? {
        didSet {
            toolbarView.onModifiersChanged = onModifiersChanged
        }
    }

    /// Callback when dismiss button is tapped
    var onDismissRequested: (() -> Void)? {
        didSet {
            toolbarView.onDismissRequested = onDismissRequested
        }
    }

    /// Callback when toolbar collapse is requested
    var onCollapseRequested: (() -> Void)? {
        didSet {
            toolbarView.onCollapseRequested = onCollapseRequested
        }
    }

    /// Callback when the dismiss button is long-pressed to pin the keyboard hidden
    var onPinHiddenRequested: (() -> Void)? {
        didSet {
            toolbarView.onPinHiddenRequested = onPinHiddenRequested
        }
    }

    /// Callback when tab switcher button is tapped
    var onTabSwitcherRequested: (() -> Void)? {
        didSet {
            toolbarView.onTabSwitcherRequested = onTabSwitcherRequested
        }
    }

    /// Callback when compose button is tapped
    var onComposeRequested: (() -> Void)? {
        didSet {
            toolbarView.onComposeRequested = onComposeRequested
        }
    }

    /// Callback when toolbar settings button is tapped
    var onToolbarSettingsRequested: (() -> Void)? {
        didSet {
            toolbarView.onToolbarSettingsRequested = onToolbarSettingsRequested
        }
    }

    /// Callback when paste button is tapped
    var onPasteRequested: (() -> Void)? {
        didSet {
            toolbarView.onPasteRequested = onPasteRequested
        }
    }

    /// Callback when toggle full screen button is tapped
    var onToggleFullScreenRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleFullScreenRequested = onToggleFullScreenRequested
        }
    }

    /// Callback when toggle tab bar button is tapped
    var onToggleTabBarRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleTabBarRequested = onToggleTabBarRequested
        }
    }

    /// Callback when new connection button is tapped
    var onNewConnectionRequested: (() -> Void)? {
        didSet {
            toolbarView.onNewConnectionRequested = onNewConnectionRequested
        }
    }

    /// Callback when app settings button is tapped
    var onAppSettingsRequested: (() -> Void)? {
        didSet {
            toolbarView.onAppSettingsRequested = onAppSettingsRequested
        }
    }

    /// Callback when toggle mouse capture button is tapped
    var onToggleMouseCaptureRequested: (() -> Void)? {
        didSet {
            toolbarView.onToggleMouseCaptureRequested = onToggleMouseCaptureRequested
        }
    }

    /// Callback when AI agent button is tapped
    var onAIAgentRequested: (() -> Void)? {
        didSet {
            toolbarView.onAIAgentRequested = onAIAgentRequested
        }
    }

    /// Callback when the brightness-boost button is tapped
    var onBrightnessBoostRequested: (() -> Void)? {
        didSet {
            toolbarView.onBrightnessBoostRequested = onBrightnessBoostRequested
        }
    }

    /// Callback when the clipboard manager button is tapped
    var onClipboardManagerRequested: (() -> Void)? {
        didSet {
            toolbarView.onClipboardManagerRequested = onClipboardManagerRequested
        }
    }

    /// Callback when accessory layout changes and input views should refresh
    var onLayoutInvalidated: (() -> Void)?

    private var layoutChangeObserver: NSObjectProtocol?
    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    private var bottomEdgePanGesture: UIScreenEdgePanGestureRecognizer?
    #endif

    // MARK: - Initialization

    init(sizes: KeyboardSizes = .current()) {
        toolbarView = KeyboardToolbarView(sizes: sizes)

        let frame = CGRect(
            x: 0,
            y: 0,
            width: 0,
            height: sizes.toolbar.height
        )

        super.init(frame: frame, inputViewStyle: .keyboard)

        setupView()
        observeLayoutChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = layoutChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupView() {
        // Both the terminal and VNC responders return this as inputAccessoryView.
        // Disable autoresizing-mask constraints so UIKit re-queries the intrinsic
        // height when drawer rows open or close and keeps the bottom keyboard edge
        // anchored while the accessory grows upward.
        translatesAutoresizingMaskIntoConstraints = false
        allowsSelfSizing = true
        backgroundColor = .clear

        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Propagate drawer state changes for height updates
        toolbarView.onDrawerStateChanged = { [weak self] in
            self?.invalidateLayoutAndNotify()
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let bottomEdgePanGesture = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleBottomEdgePan(_:))
        )
        bottomEdgePanGesture.edges = .bottom
        bottomEdgePanGesture.cancelsTouchesInView = true
        bottomEdgePanGesture.isEnabled = false
        addGestureRecognizer(bottomEdgePanGesture)
        self.bottomEdgePanGesture = bottomEdgePanGesture
        #endif
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    @objc private func handleBottomEdgePan(_: UIScreenEdgePanGestureRecognizer) {
        // Recognition itself is the behavior: it cancels the toolbar control's
        // touch before touch-up, without performing an app action.
    }
    #endif

    /// Invalidate the intrinsic height before asking the active responder to
    /// reload its input views. UIKit then grows the accessory upward from the
    /// keyboard instead of retaining a stale concrete frame.
    private func invalidateLayoutAndNotify() {
        toolbarView.setNeedsLayout()
        setNeedsLayout()
        invalidateIntrinsicContentSize()
        onLayoutInvalidated?()
    }

    private func observeLayoutChanges() {
        layoutChangeObserver = NotificationCenter.default.addObserver(
            forName: KeyboardToolbarManager.layoutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildToolbar()
        }
    }

    /// Rebuild the toolbar view in response to a layout configuration change.
    private func rebuildToolbar() {
        toolbarView.rebuildForCurrentWidth()
        invalidateLayoutAndNotify()
    }

    // MARK: - Layout

    override var intrinsicContentSize: CGSize {
        return toolbarView.intrinsicContentSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: toolbarView.intrinsicContentSize.height)
    }

    // MARK: - Public Methods

    func updateForTraitCollection(_ traitCollection: UITraitCollection) {
        let newSizes = KeyboardSizes.current(traitCollection: traitCollection)
        toolbarView.updateSizes(newSizes)
        invalidateLayoutAndNotify()
    }

    func setBottomEdgeHomeGestureProtectionEnabled(_ enabled: Bool) {
        toolbarView.setDefersKeysForBottomEdgeGesture(enabled)
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        bottomEdgePanGesture?.isEnabled = enabled
        #endif
    }

    func setDismissButtonPinned(_ pinned: Bool) {
        toolbarView.setDismissButtonPinned(pinned)
    }

    func setDismissButtonShowsRestore(_ showsRestore: Bool) {
        toolbarView.setDismissButtonShowsRestore(showsRestore)
    }

    func setTabSwitcherActive(_ active: Bool) {
        toolbarView.setTabSwitcherActive(active)
    }

    func setMouseCaptureOverrideActive(_ active: Bool) {
        toolbarView.setMouseCaptureOverrideActive(active)
    }
}
