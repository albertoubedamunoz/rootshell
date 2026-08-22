//
//  TabExposeView.swift
//  rootshell
//
//  The tab exposé overlay: an opaque backdrop, a full-size live mirror of the
//  hero tab that slides down as you pull, and a tray of live tab previews that
//  slides in from above to fill the space. Pure UIKit so the reveal can be
//  scrubbed per frame without invalidating SwiftUI; one display link steps
//  the controller's spring and refreshes the mirrors. Hosted as the top layer
//  of the terminal content area (`TabExposeHost`).
//

import UIKit
import SwiftUI

@MainActor
final class TabExposeView: UIView, TabExposeControllerObserver {
    struct Configuration {
        /// User setting: two-finger / trackpad pull-down reveal.
        var gestureEnabled: () -> Bool = { true }
        /// No sheet, no in-flight tab swipe, etc.
        var canBeginReveal: () -> Bool = { true }
        /// Extra band into the terminal when nothing sits above it (tab bar hidden).
        /// Two-finger / trackpad only.
        var fallbackBandHeight: () -> CGFloat = { 0 }
        /// Height of the tab bar strip directly above the terminal where a
        /// one-finger pull may start (0 = no one-finger reveal).
        var oneFingerBandHeight: () -> CGFloat = { 0 }
        var trackpadGain: CGFloat = 2
    }

    struct Appearance {
        var backgroundColor: UIColor = .black
        var accentColor: UIColor = .systemBlue
        var textColor: UIColor = .white
        var showsCaptions: Bool = true
        /// Caption for a cell (title + badges); index is the navigation position.
        var captionProvider: ((TabModel, Int) -> AnyView)?
    }

    let controller: TabExposeController
    var configuration = Configuration()
    var appearance = Appearance() {
        didSet { applyAppearance() }
    }

    private let backdrop = UIView()
    private let hero = TabPreviewMirrorView()
    private let tray = UIScrollView()
    private let header = UIView()
    private let headerIcon = UIImageView()
    private let headerLabel = UILabel()
    private var cells: [TabExposeCellView] = []
    private var layoutResult = TabExposeLayout.Result.empty
    private var heroRect: CGRect = .zero
    private var displayLink: CADisplayLink?
    private var lastAppliedProgress: CGFloat = -1
    private lazy var edgePan: InteractiveEdgePanRecognizer = makeEdgePan()
    private lazy var scopePan: InteractiveEdgePanRecognizer = makeScopePan()

    init(controller: TabExposeController) {
        self.controller = controller
        super.init(frame: .zero)
        controller.observer = self
        isHidden = true
        isUserInteractionEnabled = true
        clipsToBounds = true

        backdrop.isUserInteractionEnabled = false
        addSubview(backdrop)

        tray.showsHorizontalScrollIndicator = false
        tray.alwaysBounceVertical = false
        tray.contentInsetAdjustmentBehavior = .never
        tray.delaysContentTouches = false
        // UIKit 26 applies an automatic glass "scroll edge effect" to scroll
        // views it considers under a bar; on Catalyst the window titlebar
        // qualifies and the effect blurs/tints the whole tray. The tray is a
        // live preview grid, never bar-adjacent content: opt out entirely.
        if #available(iOS 26.0, macCatalyst 26.0, visionOS 26.0, *) {
            tray.topEdgeEffect.isHidden = true
            tray.bottomEdgeEffect.isHidden = true
            tray.leftEdgeEffect.isHidden = true
            tray.rightEdgeEffect.isHidden = true
        }
        addSubview(tray)

        headerIcon.contentMode = .scaleAspectFit
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(headerIcon)
        header.addSubview(headerLabel)
        header.isUserInteractionEnabled = false
        tray.addSubview(header)

        hero.isUserInteractionEnabled = false
        addSubview(hero)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        #if !os(visionOS)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Hosting

    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if !os(visionOS)
        edgePan.install(on: window)
        scopePan.install(on: window)
        #endif
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard controller.isActive else { return nil }
        return super.hitTest(point, with: event)
    }

    // MARK: - Controller observer

    func tabExposeDidChangeActivity(_ controller: TabExposeController) {
        if controller.isActive {
            isHidden = false
            lastAppliedProgress = -1
            rebuildCells()
            setNeedsLayout()
            layoutIfNeeded()
            scrollHighlightedCellIntoView(animated: false)
            startDisplayLink()
            if controller.wantsFirstResponderFallback {
                becomeFirstResponder()
            }
        } else {
            stopDisplayLink()
            if isFirstResponder { resignFirstResponder() }
            isHidden = true
            hero.tab = nil
            for cell in cells { cell.removeFromSuperview() }
            cells.removeAll()
        }
    }

    // MARK: - First-responder fallback (no terminal to hook keys on)

    override var canBecomeFirstResponder: Bool {
        controller.isActive && controller.wantsFirstResponderFallback
    }

    override var keyCommands: [UIKeyCommand]? {
        guard controller.isActive, controller.wantsFirstResponderFallback else { return nil }
        var inputs: [(String, UIKeyModifierFlags)] = [
            (UIKeyCommand.inputEscape, []), ("\r", []), (" ", []), ("\t", []), ("\t", .shift),
            (UIKeyCommand.inputUpArrow, []), (UIKeyCommand.inputDownArrow, []),
            (UIKeyCommand.inputLeftArrow, []), (UIKeyCommand.inputRightArrow, []),
            (UIKeyCommand.inputHome, []), (UIKeyCommand.inputEnd, []),
        ]
        inputs += (1...9).map { (String($0), []) }
        return inputs.map { input, flags in
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(handleFallbackKeyCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleFallbackKeyCommand(_ command: UIKeyCommand) {
        guard let event = OverlayKeyEvent(keyCommand: command) else { return }
        _ = controller.handleKey(event)
    }

    func tabExposeDidChangeCells(_ controller: TabExposeController) {
        guard controller.isActive else { return }
        let transition = controller.takeScopeTransition()
        let entering = rebuildCells(slideOutDirection: transition)
        setNeedsLayout()
        if let transition, !controller.reduceMotion() {
            layoutIfNeeded()
            slideIn(entering, from: transition)
        }
        scrollHighlightedCellIntoView(animated: true)
    }

    /// Scope switch: the old grid slides out toward `-direction`, the new one
    /// slides in from `+direction` (swipe left = next = content comes from the right).
    private func slideIn(_ entering: [TabExposeCellView], from direction: Int) {
        let dx = CGFloat(direction) * 48
        for cell in entering {
            cell.alpha = 0
            cell.transform = CGAffineTransform(translationX: dx, y: 0)
        }
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            for cell in entering {
                cell.alpha = 1
                cell.transform = cell.isHighlighted ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
            }
        }
    }

    // MARK: - Cells

    /// Returns the cells created by this rebuild. With `slideOutDirection`,
    /// stale cells animate out instead of vanishing.
    @discardableResult
    private func rebuildCells(slideOutDirection: Int? = nil) -> [TabExposeCellView] {
        guard let tabsModel = controller.tabsModel else { return [] }
        var byID = Dictionary(uniqueKeysWithValues: cells.map { ($0.tabID, $0) })
        var ordered: [TabExposeCellView] = []
        var entering: [TabExposeCellView] = []
        for (index, id) in controller.tabIDs.enumerated() {
            guard let tab = tabsModel.tab(withID: id) else { continue }
            let cell: TabExposeCellView
            if let existing = byID.removeValue(forKey: id) {
                cell = existing
            } else {
                cell = makeCell(for: tab)
                entering.append(cell)
            }
            cell.mirror.tab = tab
            cell.isCurrent = id == tabsModel.selectedTabID
            cell.isHighlighted = id == controller.highlightedTabID
            // Captions only re-host when the cell's position changes (hover
            // highlight churn must not rebuild SwiftUI per cell).
            if cell.captionIndex != index {
                cell.captionIndex = index
                cell.setCaption(appearance.showsCaptions ? appearance.captionProvider?(tab, index) : nil)
            }
            ordered.append(cell)
        }
        if let slideOutDirection, !controller.reduceMotion(), !byID.isEmpty {
            let dx = CGFloat(-slideOutDirection) * 48
            let leaving = Array(byID.values)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                for cell in leaving {
                    cell.alpha = 0
                    cell.transform = CGAffineTransform(translationX: dx, y: 0)
                }
            } completion: { _ in
                for cell in leaving { cell.removeFromSuperview() }
            }
        } else {
            for (_, stale) in byID { stale.removeFromSuperview() }
        }
        cells = ordered
        hero.tab = controller.heroTabID.flatMap { tabsModel.tab(withID: $0) }

        let scoped = controller.isScoped
        header.isHidden = !scoped
        if scoped {
            headerLabel.text = [controller.scopeTitle, "\(controller.tabIDs.count)"]
                .compactMap { $0 }
                .joined(separator: " · ")
            let symbol = tabsModel.isProjectGroupingActive ? "folder" : "square.grid.2x2"
            headerIcon.image = UIImage(systemName: symbol)
        }
        applyAppearance()
        return entering
    }

    private func makeCell(for tab: TabModel) -> TabExposeCellView {
        let cell = TabExposeCellView(tabID: tab.id)
        tray.addSubview(cell)
        return cell
    }

    private func applyAppearance() {
        backdrop.backgroundColor = appearance.backgroundColor
        hero.backgroundColor = appearance.backgroundColor
        headerLabel.textColor = appearance.textColor.withAlphaComponent(0.85)
        headerIcon.tintColor = appearance.textColor.withAlphaComponent(0.7)
        for cell in cells {
            cell.previewBackgroundColor = appearance.backgroundColor
            cell.accentColor = appearance.accentColor
            cell.currentRingColor = appearance.textColor.withAlphaComponent(0.3)
        }
    }

    // MARK: - Layout

    private var isCompact: Bool {
        UIDevice.current.userInterfaceIdiom == .phone || bounds.width < 500
    }

    private func currentHeroRect() -> CGRect {
        guard let hero = controller.heroTabID ?? controller.tabsModel?.selectedTabID,
              let tab = controller.tabsModel?.tab(withID: hero),
              let host = tab.splitTree.first?.enclosingSplitHost,
              host.bounds.width > 0, host.bounds.height > 0 else {
            return bounds
        }
        return host.convert(host.bounds, to: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard controller.isActive else { return }
        heroRect = currentHeroRect()
        let H = max(heroRect.height, 1)

        #if targetEnvironment(macCatalyst)
        let mac = true
        #else
        let mac = false
        #endif
        #if os(visionOS)
        let vision = true
        #else
        let vision = false
        #endif
        let metrics = TabExposeLayout.Metrics.standard(
            compact: isCompact, mac: mac, vision: vision,
            showsCaptions: appearance.showsCaptions, hasHeader: controller.isScoped
        )
        layoutResult = TabExposeLayout.grid(
            in: CGRect(origin: .zero, size: heroRect.size),
            count: cells.count,
            aspect: heroRect.width / H,
            metrics: metrics
        )
        controller.columns = layoutResult.columns

        backdrop.frame = heroRect
        hero.transform = .identity
        hero.frame = heroRect
        tray.transform = .identity
        tray.frame = heroRect
        tray.contentSize = CGSize(width: heroRect.width, height: max(layoutResult.contentHeight, heroRect.height))
        tray.isScrollEnabled = !layoutResult.fits

        header.frame = layoutResult.headerFrame
        let iconSide = max(0, min(16, header.bounds.height))
        headerIcon.frame = CGRect(x: 0, y: (header.bounds.height - iconSide) / 2, width: iconSide, height: iconSide)
        headerLabel.frame = CGRect(x: iconSide + 6, y: 0, width: header.bounds.width - iconSide - 6, height: header.bounds.height)

        let radius: CGFloat = vision ? 16 : (isCompact ? 8 : 10)
        for (index, cell) in cells.enumerated() where index < layoutResult.frames.count {
            // bounds/center, not frame: highlighted cells carry a scale transform.
            let frame = layoutResult.frames[index]
            cell.bounds = CGRect(origin: .zero, size: frame.size)
            cell.center = CGPoint(x: frame.midX, y: frame.midY)
            cell.layoutContent(previewSize: layoutResult.cellSize, cornerRadius: radius)
        }
        lastAppliedProgress = -1
        applyProgress()
    }

    /// Everything visual derives from `controller.progress` (0 hidden … 1 presented).
    private func applyProgress() {
        let p = controller.progress
        guard p != lastAppliedProgress else { return }
        lastAppliedProgress = p
        let H = max(heroRect.height, 1)
        let clamped = min(max(p, 0), 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hero.transform = CGAffineTransform(translationX: 0, y: clamped * H)
        hero.isHidden = clamped >= 1
        tray.transform = CGAffineTransform(translationX: 0, y: -(1 - clamped) * H)
        if p > 1 {
            // Overshoot: the tray breathes instead of tearing away from the edge.
            let breathe = 1 + (p - 1) * 0.3
            tray.transform = tray.transform.scaledBy(x: breathe, y: breathe)
        }
        let chromeAlpha = Self.smoothstep(0.6, 0.9, p)
        let ringAlpha = Self.smoothstep(0.8, 1.0, p)
        header.alpha = chromeAlpha
        for cell in cells {
            cell.captionAlpha = chromeAlpha
            cell.ringAlpha = ringAlpha
        }
        backdrop.isHidden = p <= 0
        CATransaction.commit()
    }

    private static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / max(b - a, 0.0001), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func scrollHighlightedCellIntoView(animated: Bool) {
        guard tray.isScrollEnabled,
              let id = controller.highlightedTabID,
              let cell = cells.first(where: { $0.tabID == id }) else { return }
        tray.scrollRectToVisible(cell.frame.insetBy(dx: 0, dy: -12), animated: animated)
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        controller.tick(now: link.timestamp)
        guard controller.isActive else {
            stopDisplayLink()
            return
        }
        // The terminal area can move without our bounds changing (keyboard).
        if currentHeroRect() != heroRect {
            setNeedsLayout()
            layoutIfNeeded()
        }
        applyProgress()
        if !hero.isHidden { hero.sync() }
        let visible = tray.bounds
        for cell in cells where cell.frame.intersects(visible) {
            cell.mirror.sync()
        }
    }

    private final class DisplayLinkProxy: NSObject {
        weak var owner: TabExposeView?
        init(owner: TabExposeView) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(link) }
        }
    }

    // MARK: - Touch / pointer

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        guard controller.phase == .presented else { return }
        if let cell = cell(at: tap.location(in: tray)) {
            controller.select(cell.tabID)
        } else {
            controller.cancel()
        }
    }

    #if !os(visionOS)
    @objc private func handleHover(_ hover: UIHoverGestureRecognizer) {
        guard controller.phase == .presented else { return }
        switch hover.state {
        case .began, .changed:
            if let cell = cell(at: hover.location(in: tray)) {
                controller.highlightedTabID = cell.tabID
            }
        default:
            break
        }
    }
    #endif

    private func cell(at pointInTray: CGPoint) -> TabExposeCellView? {
        cells.first { $0.frame.contains(pointInTray) }
    }

    // MARK: - Window-level pull gesture

    private func makeEdgePan() -> InteractiveEdgePanRecognizer {
        var config = InteractiveEdgePanRecognizer.Configuration(axis: .vertical, idioms: [.phone, .pad, .mac])
        // One finger from the tab bar strip; two fingers from anywhere above
        // the terminal (and the in-terminal fallback band); trackpad scroll.
        config.touchCounts = [1, 2]
        config.includesTrackpadScroll = true
        config.trackpadGain = configuration.trackpadGain
        // In the band, swipes and scroll pans wait for us (we refuse fast outside it).
        config.beatsSiblingRecognizers = { [weak self] other in
            guard let self, !self.scopePan.owns(other) else { return false }
            return other is UISwipeGestureRecognizer || other is UIPanGestureRecognizer
        }

        let isInBand: (CGPoint, UIWindow, Int) -> Bool = { [weak self] start, window, touches in
            guard let self else { return false }
            let frame = self.convert(self.bounds, to: window)
            guard start.x >= frame.minX, start.x <= frame.maxX else { return false }
            if self.controller.isActive { return start.y <= frame.maxY }
            if touches == 1 {
                // Only the strip itself: the status bar edge belongs to the system.
                let strip = self.configuration.oneFingerBandHeight()
                return strip > 0 && start.y >= frame.minY - strip && start.y < frame.minY
            }
            return start.y < frame.minY + self.configuration.fallbackBandHeight()
        }
        let shouldBegin: (CGPoint, CGPoint, UIWindow, Int) -> Bool = { [weak self] _, translation, _, touches in
            guard let self, self.configuration.gestureEnabled() else { return false }
            // One finger competes with horizontal tab scrolling: demand a clearer vertical intent.
            let ratio: CGFloat = touches == 1 ? 2 : 1.25
            let vertical = abs(translation.y) > abs(translation.x) * ratio
            guard vertical else { return false }
            if self.controller.isActive {
                // Push back up to dismiss; not while already finger-driven,
                // and not when the tray scrolls instead.
                return translation.y < 0 && self.controller.phase != .interactive && !self.tray.isScrollEnabled
            }
            return translation.y > 0 && self.configuration.canBeginReveal()
        }
        let callbacks = InteractiveEdgePanRecognizer.Callbacks(
            isInActivationBand: isInBand,
            shouldBegin: shouldBegin,
            length: { [weak self] in max(self?.heroRect.height ?? 1, 1) },
            onBegin: { [weak self] _ in self?.controller.beginInteractive() },
            onChange: { [weak self] p in self?.controller.updateInteractive(signed: p) },
            onEnd: { [weak self] _, v in self?.controller.endInteractive(velocity: v) },
            onCancel: { [weak self] in self?.controller.cancelInteractive() }
        )
        return InteractiveEdgePanRecognizer(configuration: config, callbacks: callbacks)
    }
}

// MARK: - Horizontal swipe between groups (while presented)

extension TabExposeView {
    /// One-finger (or two) touch swipe and two-finger trackpad swipe over the
    /// presented grid move to the previous / next group. The tray follows the
    /// finger a little for feedback; the cell slide does the rest.
    private func makeScopePan() -> InteractiveEdgePanRecognizer {
        var config = InteractiveEdgePanRecognizer.Configuration(axis: .horizontal, idioms: [.phone, .pad, .mac])
        config.touchCounts = [1, 2]
        config.includesTrackpadScroll = true
        config.trackpadGain = 1.5
        config.beatsSiblingRecognizers = { [weak self] other in
            guard let self, !self.edgePan.owns(other) else { return false }
            return other is UISwipeGestureRecognizer || other is UIPanGestureRecognizer
        }

        let isInBand: (CGPoint, UIWindow, Int) -> Bool = { [weak self] start, window, _ in
            guard let self, self.controller.phase == .presented, self.controller.canNavigateScope else { return false }
            return self.convert(self.bounds, to: window).contains(start)
        }
        let shouldBegin: (CGPoint, CGPoint, UIWindow, Int) -> Bool = { _, translation, _, _ in
            abs(translation.x) > abs(translation.y) * 1.5
        }
        let callbacks = InteractiveEdgePanRecognizer.Callbacks(
            isInActivationBand: isInBand,
            shouldBegin: shouldBegin,
            length: { [weak self] in max(self?.bounds.width ?? 1, 1) },
            onBegin: { _ in },
            onChange: { [weak self] p in self?.nudgeTray(progress: p) },
            onEnd: { [weak self] p, v in self?.endScopeSwipe(progress: p, velocity: v) },
            onCancel: { [weak self] in self?.settleTray() }
        )
        return InteractiveEdgePanRecognizer(configuration: config, callbacks: callbacks)
    }

    private func nudgeTray(progress: CGFloat) {
        guard controller.phase == .presented else { return }
        let clamped = min(max(progress, -1), 1)
        tray.transform = CGAffineTransform(translationX: clamped * bounds.width * 0.2, y: 0)
    }

    private func endScopeSwipe(progress: CGFloat, velocity: CGFloat) {
        // Swipe left (negative) = next group; content then slides in from the right.
        if progress < -0.12 || velocity < -500 {
            controller.navigateScope(by: 1)
        } else if progress > 0.12 || velocity > 500 {
            controller.navigateScope(by: -1)
        }
        settleTray()
    }

    private func settleTray() {
        guard controller.phase == .presented else { return }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.tray.transform = .identity
        }
    }
}

// MARK: - Cell

@MainActor
final class TabExposeCellView: UIView {
    let tabID: UUID
    let mirror = TabPreviewMirrorView()
    /// Navigation index the current caption was built for; -1 = none yet.
    var captionIndex = -1

    private let preview = UIView()
    private let currentRing = UIView()
    private let highlightRing = UIView()
    private var captionHost: UIHostingController<AnyView>?

    var previewBackgroundColor: UIColor = .black {
        didSet {
            preview.backgroundColor = previewBackgroundColor
            mirror.backgroundColor = previewBackgroundColor
        }
    }
    var accentColor: UIColor = .systemBlue {
        didSet { highlightRing.layer.borderColor = accentColor.cgColor }
    }
    var currentRingColor: UIColor = UIColor.white.withAlphaComponent(0.3) {
        didSet { currentRing.layer.borderColor = currentRingColor.cgColor }
    }
    var isCurrent = false {
        didSet { updateRings() }
    }
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateRings()
            let scale: CGFloat = isHighlighted ? 1.02 : 1
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = CGAffineTransform(scaleX: scale, y: scale)
            }
        }
    }
    var captionAlpha: CGFloat = 1 {
        didSet { captionHost?.view.alpha = captionAlpha }
    }
    var ringAlpha: CGFloat = 1 {
        didSet { updateRings() }
    }

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        preview.clipsToBounds = true
        preview.layer.cornerCurve = .continuous
        preview.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        preview.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        preview.isUserInteractionEnabled = false
        preview.addSubview(mirror)
        addSubview(currentRing)
        addSubview(highlightRing)
        addSubview(preview)
        for ring in [currentRing, highlightRing] {
            ring.isUserInteractionEnabled = false
            ring.layer.cornerCurve = .continuous
            ring.layer.borderColor = UIColor.clear.cgColor
        }
        currentRing.layer.borderWidth = 1.5
        highlightRing.layer.borderWidth = 2.5
        updateRings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCaption(_ view: AnyView?) {
        guard let view else {
            captionHost?.view.removeFromSuperview()
            captionHost = nil
            return
        }
        if let captionHost {
            captionHost.rootView = view
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.alpha = captionAlpha
            addSubview(host.view)
            captionHost = host
        }
    }

    func layoutContent(previewSize: CGSize, cornerRadius: CGFloat) {
        preview.frame = CGRect(origin: .zero, size: previewSize)
        preview.layer.cornerRadius = cornerRadius
        mirror.frame = preview.bounds
        let ringFrame = preview.frame.insetBy(dx: -3, dy: -3)
        for ring in [currentRing, highlightRing] {
            ring.frame = ringFrame
            ring.layer.cornerRadius = cornerRadius + 3
        }
        captionHost?.view.frame = CGRect(
            x: 0, y: previewSize.height,
            width: previewSize.width, height: max(0, bounds.height - previewSize.height)
        )
    }

    private func updateRings() {
        currentRing.alpha = isCurrent ? ringAlpha : 0
        highlightRing.alpha = isHighlighted ? ringAlpha : 0
    }
}

// MARK: - SwiftUI host

struct TabExposeHost: UIViewRepresentable {
    let controller: TabExposeController
    let configuration: TabExposeView.Configuration
    let appearance: TabExposeView.Appearance

    func makeUIView(context: Context) -> TabExposeView {
        let view = TabExposeView(controller: controller)
        view.configuration = configuration
        view.appearance = appearance
        return view
    }

    func updateUIView(_ uiView: TabExposeView, context: Context) {
        uiView.configuration = configuration
        uiView.appearance = appearance
    }
}
