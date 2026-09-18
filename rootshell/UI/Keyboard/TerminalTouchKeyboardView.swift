#if !os(visionOS) && !targetEnvironment(macCatalyst)
import UIKit
import Combine
import SwiftUI

private struct TerminalTouchKeyboardPalette {
    let background: UIColor
    let key: UIColor
    let pressedKey: UIColor
    let pressedInk: UIColor
    let ink: UIColor
    let toolbarInk: UIColor
    let isLight: Bool

    init?(colors: ThemeManager.ThemeInfo.ThemeColors) {
        guard let base = Color(hex: colors.background), let derived = ThemeUIColorDerivation.derive(from: colors) else { return nil }
        let key = derived.sheetRowBackground
        let preferred = Color(hex: colors.foreground) ?? derived.tabText
        func rgb(_ color: Color) -> TerminalTouchKeyboardModel.RGB {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return .init(red: Double(r), green: Double(g), blue: Double(b))
        }
        func readable(on surface: Color) -> Color {
            let ink = rgb(surface).readableInk(preferred: rgb(preferred))
            return Color(red: ink.red, green: ink.green, blue: ink.blue)
        }
        let ink = readable(on: key)
        let pressed = key.blended(toward: ink, amount: 0.1)
        self.background = UIColor(base)
        self.key = UIColor(key)
        self.pressedKey = UIColor(pressed)
        self.ink = UIColor(ink)
        self.pressedInk = UIColor(readable(on: pressed))
        self.toolbarInk = UIColor(readable(on: base))
        self.isLight = base.isLight
    }
}

private enum TerminalTouchKeyboardAppearance {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 34 / 255, green: 34 / 255, blue: 39 / 255, alpha: 1)
            : UIColor(red: 210 / 255, green: 213 / 255, blue: 219 / 255, alpha: 1)
    }
    static let toolbar = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 46 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 235 / 255, blue: 240 / 255, alpha: 1)
    }
}

private struct TerminalTouchKeyboardEffectBackground: View {
    let backgroundColor: UIColor
    @ObservedObject var effect: AnyTerminalEffect
    var effectManager = EffectManager.shared

    var body: some View {
        ZStack {
            Color(uiColor: backgroundColor)
            effect.createEffectView()
                .id(effect.id)
                .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
        }
        .environment(\.terminalEffectAvoidsKeyboard, false)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An in-app keyboard. The terminal remains first responder throughout typing.
@MainActor
protocol TerminalTouchKeyboardHost: AnyObject {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { get }
    var touchKeyboardCanSend: Bool { get }
    var touchKeyboardSuggestionContext: TerminalTouchKeyboardModel.SuggestionContext? { get }
    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { get }
    func touchKeyboardInsert(_ text: String)
    func touchKeyboardSend(_ key: String, modifiers: KeyModifiers)
    func touchKeyboardAccept(_ text: String, context: TerminalTouchKeyboardModel.SuggestionContext)
    func touchKeyboardInvalidateSuggestions()
}

extension TerminalTouchKeyboardHost {
    var touchKeyboardThemeColors: ThemeManager.ThemeInfo.ThemeColors? { nil }
    var touchKeyboardPredictionContext: TerminalTouchKeyboardModel.PredictionSnapshot? { nil }
}

private final class TerminalTouchKeycap: UIView {
    let key: TerminalTouchKeyboardModel.Key
    let plate = UIView()
    let label = UILabel()
    let icon = UIImageView()
    private let lockIndicator = UIView()
    private let toolbarKey: Bool
    var palette: TerminalTouchKeyboardPalette? { didSet { updateColor() } }
    var locked = false { didSet { lockIndicator.isHidden = !locked } }
    var activate: (() -> Void)?
    var pressed = false { didSet { updateColor() } }
    var selected = false { didSet { updateColor() } }

    init(_ key: TerminalTouchKeyboardModel.Key, small: Bool = false) {
        self.key = key
        self.toolbarKey = small
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = [.keyboardKey]
        accessibilityLabel = key.accessibility ?? key.title
        plate.isUserInteractionEnabled = false
        plate.layer.cornerRadius = small ? 12 : 8
        plate.layer.cornerCurve = .continuous
        plate.layer.shadowColor = UIColor.black.cgColor
        plate.layer.shadowOffset = CGSize(width: 0, height: 1)
        plate.layer.shadowRadius = 0.5
        addSubview(plate)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: small ? 13 : (key.title.count == 1 ? 25 : 16), weight: small ? .medium : .regular)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.text = key.title
        plate.addSubview(label)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: small ? 17 : 21, weight: .regular)
        plate.addSubview(icon)
        lockIndicator.layer.cornerRadius = 1.5
        lockIndicator.isHidden = true
        plate.addSubview(lockIndicator)
        setSymbol(key.symbol)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ name: String?) {
        icon.image = name.flatMap { UIImage(systemName: $0) }
        label.isHidden = icon.image != nil
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        plate.frame = bounds.insetBy(dx: 3, dy: 5)
        label.frame = plate.bounds.insetBy(dx: 3, dy: 0)
        lockIndicator.frame = CGRect(x: (plate.bounds.width - 14) / 2, y: plate.bounds.height - 4, width: 14, height: 2.5)
        let iconSize = CGSize(width: min(24, max(0, plate.bounds.width - 8)), height: min(23, max(0, plate.bounds.height - 6)))
        icon.frame = CGRect(x: (plate.bounds.width - iconSize.width) / 2, y: (plate.bounds.height - iconSize.height) / 2,
                            width: iconSize.width, height: iconSize.height)
    }
    func updateColor() {
        let character: Bool = { if case .text = key.action { return true }; return false }()
        let selected = self.selected, pressed = self.pressed, toolbarKey = self.toolbarKey
        // A keyboard can acquire its final appearance after attachment. Do not
        // mix a light-only background with a dynamically changing .label color.
        plate.backgroundColor = UIColor { traits in
            if toolbarKey && !selected {
                return pressed ? UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.12) : .clear
            }
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            if traits.userInterfaceStyle == .dark, !selected {
                return UIColor(red: colors.background, green: colors.background, blue: colors.background + 4 / 255, alpha: 1)
            }
            return UIColor(white: colors.background, alpha: 1)
        }
        let ink = UIColor { traits in
            let colors = TerminalTouchKeyboardModel.keyColors(dark: traits.userInterfaceStyle == .dark,
                character: character, pressed: pressed, selected: selected)
            return UIColor(white: colors.ink, alpha: 1)
        }
        label.textColor = ink
        icon.tintColor = ink
        lockIndicator.backgroundColor = ink
        if let palette {
            let themedInk = selected ? palette.key : (toolbarKey ? palette.toolbarInk : (pressed ? palette.pressedInk : palette.ink))
            plate.backgroundColor = selected ? palette.ink : (toolbarKey ? (pressed ? palette.toolbarInk.withAlphaComponent(0.12) : .clear) : (pressed ? palette.pressedKey : palette.key))
            label.textColor = themedInk
            icon.tintColor = themedInk
            lockIndicator.backgroundColor = themedInk
        }
        plate.layer.shadowOpacity = toolbarKey || traitCollection.userInterfaceStyle == .dark ? 0 : 0.12
        plate.layer.borderWidth = UIAccessibility.isDarkerSystemColorsEnabled && (!toolbarKey || selected) ? 1 : 0
        plate.layer.borderColor = UIColor.label.cgColor
        accessibilityTraits = selected ? [.keyboardKey, .selected] : [.keyboardKey]
    }
    override func accessibilityActivate() -> Bool { activate?(); return true }
}

/// UIKit cancels the ordinary button tap when this recognizer starts repeating.
private final class TerminalTouchRepeatingButton: UIButton {
    var repeatAction: (() -> Void)?
    private var repeatTask: Task<Void, Never>?
    func enableRepeat(_ action: @escaping () -> Void) {
        repeatAction = action
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.35
        addGestureRecognizer(hold)
    }
    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            repeatAction?()
            repeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(55))
                    guard !Task.isCancelled, let self, self.window != nil else { return }
                    self.repeatAction?()
                }
            }
        } else if gesture.state != .changed || !bounds.contains(gesture.location(in: self)) { cancelRepeat() }
    }
    func cancelRepeat() { repeatTask?.cancel(); repeatTask = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { cancelRepeat() } }
}

/// Wait for a full horizontal stroke before cancelling a key's pending tap.
/// Failing early on vertical movement lets the tools grid scroll normally.
private final class TerminalKeyboardPageSwipe: UIGestureRecognizer {
    private var origin = CGPoint.zero
    var offset = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, event.allTouches?.count == 1, let touch = touches.first else {
            state = .failed; return
        }
        origin = touch.location(in: view)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // A second contact may have been rejected by the delegate (for example
        // over a toolbar control), so recheck the event before recognizing.
        guard event.allTouches?.count == 1, let touch = touches.first else {
            state = .failed; return
        }
        let point = touch.location(in: view)
        let delta = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if let offset = TerminalTouchKeyboardModel.pageSwipe(translation: delta) {
            self.offset = offset
            state = .recognized
        } else if abs(delta.y) > 35 {
            state = .failed
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); offset = 0 }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // This includes UIKit's native floating-keyboard pinch recognizer on
        // an ancestor. A one-finger stroke must never lock out a later pinch.
        if preventedGestureRecognizer is UIPinchGestureRecognizer { return false }
        // UIKit may use a custom recognizer for its floating transition rather
        // than a UIPinchGestureRecognizer subclass. Yield to the hosting views
        // without depending on any private UIKit class name.
        if let host = preventedGestureRecognizer.view, let view,
           host !== view, view.isDescendant(of: host) { return false }
        return super.canPrevent(preventedGestureRecognizer)
    }
}

final class TerminalTouchKeyboardView: UIView, KeyboardButtonDelegate, UIGestureRecognizerDelegate {
    typealias Model = TerminalTouchKeyboardModel
    weak var host: TerminalTouchKeyboardHost? { didSet { updateAppearance() } }
    private var palette: TerminalTouchKeyboardPalette?
    var onAppearanceChanged: (() -> Void)?
    var containerBackgroundColor: UIColor { palette?.background ?? TerminalTouchKeyboardAppearance.background }
    weak var sequenceDelegate: KeyboardButtonDelegate?
    var onModifiersChanged: ((KeyModifiers) -> Void)?
    var onDismiss: (() -> Void)?
    var onPinHidden: (() -> Void)?
    var onSwitchKeyboard: (() -> Void)?
    var onCompose: (() -> Void)?
    var onPaste: (() -> Void)?
    var onTabs: (() -> Void)?
    var onCustomize: (() -> Void)?
    var onToolbarAction: ((String) -> Void)?
    var onHeightChanged: (() -> Void)?
    /// Only the app-contained host supports our explicit placement requests.
    /// Native placement must remain under UIKit's control.
    var usesSystemPlacement = false {
        didSet {
            guard oldValue != usesSystemPlacement else { return }
            placementPinch?.isEnabled = !usesSystemPlacement
            placementDockTap?.isEnabled = !usesSystemPlacement
            pinchPlacement = nil
            cancelInteraction()
            refreshPlacementActions()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            onHeightChanged?()
        }
    }
    private var placementPinch: UIPinchGestureRecognizer?
    private var placementDockTap: UITapGestureRecognizer?
    private var pinchPlacement: Model.Placement?
    var onPlacementRequested: ((Model.Placement) -> Void)? { didSet { refreshPlacementActions() } }
    var onFloatingDrag: ((CGPoint, Bool) -> Void)?
    var onFloatingDragCancelled: (() -> Void)?
    var onFloatingNudge: ((CGPoint) -> Void)?
    private(set) var isFloating = false
    var floatingAvailableHeight: CGFloat = 1000 {
        didSet { if abs(oldValue - floatingAvailableHeight) > 0.5 { setNeedsLayout() } }
    }

    private var modifierState = Model.Modifiers()
    private var page = Model.Page.letters
    private var preset = Model.Preset.shell
    private var toolPage = Model.ToolPage.typing
    private var drawerOpen: Bool { toolPage != .typing }
    private var toolbarDrawerKeys: [[Model.Key]] = []
    private var configuredDrawerToggle: Model.Key?
    private var toolbarDrawerState = Model.ToolbarDrawerState.closed
    private var toolbarDrawerOpenByDefault = KeyboardToolbarManager.shared.drawerOpenByDefault
    private var toolbarDrawerRows: [UIScrollView] = []
    private var toolbarDrawerIndices: [Int] = []
    private var toolbarDrawerButtons: [[TerminalTouchRepeatingButton]] = []
    private var toolbarDrawerModifiers: [TerminalTouchRepeatingButton: Model.Modifier] = [:]
    private var toolbarDrawerHeight: CGFloat { CGFloat(toolbarDrawerRows.count) * 44 }
    private var toolbarHeight: CGFloat { 48 + toolbarDrawerHeight }
    private var configuredMain: [Model.Key] = []
    private var configuredDrawers: [[Model.Key]] = []
    private var rows: [[TerminalTouchKeycap]] = []
    private var controls: [TerminalTouchKeycap] = []
    private let background = UIView()
    private let floatingGlass = UIVisualEffectView()
    private let controlGlass = UIVisualEffectView()
    private var effectContentView: (UIView & UIContentView)?
    private var effectPlacement = Model.BackgroundEffectPlacement.off
    private var effectsSuspended = UIApplication.shared.applicationState != .active
    private let drawer = UIScrollView()
    private let pageIndicator = UIVisualEffectView()
    private let pageIndicatorTitle = UILabel()
    private let pageIndicatorDots = Model.ToolPage.allCases.map { _ in UIView() }
    private var pageIndicatorHideTask: Task<Void, Never>?
    private let presets = UISegmentedControl(items: Model.Preset.allCases.map(\.rawValue))
    private let writingAssistanceButton = UIButton(type: .system)
    private let grabber = UIButton(type: .system)
    private var drawerButtons: [TerminalTouchRepeatingButton] = []
    private var drawerColumns = 6
    private let suggestions = UIStackView()
    private let preview = UILabel()
    private let accents = UIStackView()
    private var accentChoices: [String] = []
    private var accentIndex = 0
    private let checker = UITextChecker()
    private var suggestionTask: Task<Void, Never>?
    private var sequenceTask: Task<Void, Never>?
    private var lastSuggestionContext: Model.SuggestionContext?
    private var observations = Set<AnyCancellable>()
    private var heightConstraint: NSLayoutConstraint!
    private var previousWidth: CGFloat = 0
    private var suggestionsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
    private var predictionEnabled = SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction)
    private var predictionTask: Task<Void, Never>?
    private var pendingPrediction: Model.PredictionSnapshot?
    private var predictionCache = Model.PredictionCache()
    private let predictionLanguage = UITextChecker.availableLanguages.first { $0.hasPrefix("en") }
    private var typingGeometry = Model.TypingGeometry(targets: [], bounds: .zero)
    private var nextContactOrder: UInt64 = 0
    private var hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
    private var compactHeightEnabled = SettingsStore.shared.value(Settings.Keyboard.touchCompactHeight)
    private var glyphsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
    #if !os(visionOS)
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    #endif

    private final class Contact {
        let initial: TerminalTouchKeycap
        var current: TerminalTouchKeycap?
        let origin: CGPoint
        var anchor: CGPoint
        var task: Task<Void, Never>?
        var consumed = false
        var trackpad = false
        var accent = false
        var direction: String?
        let order: UInt64
        var selection: Model.TouchSelection?
        init(key: TerminalTouchKeycap, point: CGPoint, order: UInt64, selection: Model.TouchSelection?) {
            initial = key; current = key; origin = point; anchor = point
            self.order = order; self.selection = selection
        }
    }
    private var contacts: [ObjectIdentifier: Contact] = [:]
    private var canSend: Bool { window != nil && host?.touchKeyboardCanSend == true }
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var rowHeight: CGFloat {
        if isFloating {
            return min(44, max(28, (floatingAvailableHeight - toolbarHeight - 44 - (suggestionsEnabled ? 36 : 0)) / 4))
        }
        return compact ? 40 : (traitCollection.userInterfaceIdiom == .pad ? 60 : 54)
    }
    private var deviceBottomInset: CGFloat {
        // An embedded settings preview must not inherit padding from the window's
        // bottom edge unless the keyboard actually reaches that edge.
        guard let window, convert(bounds, to: window).maxY >= window.bounds.maxY - 1 else {
            return safeAreaInsets.bottom
        }
        return max(safeAreaInsets.bottom, window.safeAreaInsets.bottom)
    }
    private var bottomInset: CGFloat { isFloating ? 44 : (compactHeightEnabled ? 6 : max(6, deviceBottomInset)) }
    private var desiredHeight: CGFloat { toolbarHeight + rowHeight * 4 + bottomInset + (suggestionsEnabled ? 36 : 0) }

    init() {
        // Supply one surface ourselves; UIKit's keyboard style adds another
        // material behind it, which washes out the native dark palette.
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 304))
        translatesAutoresizingMaskIntoConstraints = false
        isMultipleTouchEnabled = true
        floatingGlass.isUserInteractionEnabled = false
        floatingGlass.layer.cornerRadius = 24
        floatingGlass.layer.cornerCurve = .continuous
        floatingGlass.clipsToBounds = true
        floatingGlass.isHidden = true
        background.isUserInteractionEnabled = false
        background.layer.cornerRadius = 24
        background.layer.cornerCurve = .continuous
        background.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(background)
        addSubview(floatingGlass)
        controlGlass.isUserInteractionEnabled = false
        controlGlass.layer.cornerRadius = 22
        controlGlass.layer.cornerCurve = .continuous
        controlGlass.clipsToBounds = true
        addSubview(controlGlass)
        heightConstraint = heightAnchor.constraint(equalToConstant: desiredHeight)
        heightConstraint.priority = .init(999)
        heightConstraint.isActive = true
        let pageSwipe = TerminalKeyboardPageSwipe(target: self, action: #selector(swipePage(_:)))
        pageSwipe.delegate = self
        pageSwipe.cancelsTouchesInView = true
        pageSwipe.delaysTouchesBegan = false
        addGestureRecognizer(pageSwipe)
        drawer.panGestureRecognizer.require(toFail: pageSwipe)
        presets.selectedSegmentIndex = Model.Preset.allCases.firstIndex(of: preset) ?? 0
        presets.addTarget(self, action: #selector(changePreset), for: .valueChanged)
        presets.accessibilityLabel = String(localized: "Keyboard preset")
        addSubview(presets)
        drawer.showsVerticalScrollIndicator = true
        drawer.alwaysBounceVertical = false
        addSubview(drawer)
        pageIndicator.layer.cornerRadius = 16
        pageIndicator.layer.cornerCurve = .continuous
        pageIndicator.clipsToBounds = true
        pageIndicator.isUserInteractionEnabled = false
        pageIndicator.accessibilityElementsHidden = true
        pageIndicator.alpha = 0
        pageIndicatorTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        pageIndicatorTitle.textAlignment = .center
        pageIndicatorTitle.textColor = .white
        pageIndicator.contentView.addSubview(pageIndicatorTitle)
        pageIndicatorDots.forEach { pageIndicator.contentView.addSubview($0) }
        addSubview(pageIndicator)
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        addSubview(suggestions)
        preview.textAlignment = .center
        preview.font = .systemFont(ofSize: 32)
        preview.layer.cornerRadius = 10
        preview.clipsToBounds = true
        preview.isUserInteractionEnabled = false
        preview.isHidden = true
        addSubview(preview)
        accents.axis = .horizontal
        accents.distribution = .fillEqually
        accents.layer.cornerRadius = 12
        accents.clipsToBounds = true
        accents.isUserInteractionEnabled = false
        accents.isHidden = true
        addSubview(accents)
        writingAssistanceButton.showsMenuAsPrimaryAction = true
        writingAssistanceButton.accessibilityLabel = String(localized: "Writing Assistance")
        addSubview(writingAssistanceButton)
        grabber.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        grabber.accessibilityLabel = String(localized: "Move keyboard")
        grabber.accessibilityHint = String(localized: "Drag to move. Double-tap to dock.")
        addSubview(grabber)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragFloatingKeyboard(_:)))
        drag.maximumNumberOfTouches = 1
        grabber.addGestureRecognizer(drag)
        let dock = UITapGestureRecognizer(target: self, action: #selector(dockKeyboard))
        dock.numberOfTapsRequired = 2
        dock.isEnabled = !usesSystemPlacement
        dock.require(toFail: drag)
        placementDockTap = dock
        grabber.addGestureRecognizer(dock)
        if traitCollection.userInterfaceIdiom == .pad {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchKeyboard(_:)))
            pinch.cancelsTouchesInView = true
            pinch.delegate = self
            pinch.isEnabled = !usesSystemPlacement
            placementPinch = pinch
            addGestureRecognizer(pinch)
        }
        loadToolbarConfiguration()
        if KeyboardToolbarManager.shared.drawerOpenByDefault {
            toolbarDrawerState = .closed.toggled(rowCount: configuredDrawers.count,
                cycle: KeyboardToolbarManager.shared.drawerToggleMode == .cycle)
        }
        rebuildKeys()
        rebuildDrawer()
        ThemeManager.shared.themeDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        ThemeOverrideManager.shared.overridesDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateAppearance(); self?.rebuildDrawer()
        }.store(in: &observations)
        EffectManager.shared.effectDidChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateBackgroundEffect()
        }.store(in: &observations)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                     UIAccessibility.darkerSystemColorsStatusDidChangeNotification, Notification.Name.settingsDidChange,
                     KeyboardToolbarManager.layoutDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == UIApplication.willResignActiveNotification {
                        self.cancelInteraction()
                        self.effectsSuspended = true
                        self.updateBackgroundEffect()
                        return
                    }
                    if name == UIApplication.didBecomeActiveNotification { self.effectsSuspended = false }
                    self.refreshSettings()
                }
            }
            observations.insert(AnyCancellable { NotificationCenter.default.removeObserver(token) })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) {
            (self: TerminalTouchKeyboardView, _: UITraitCollection) in
            self.cancelInteraction()
            self.updateAppearance()
            self.setNeedsLayout()
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: desiredHeight) }

    func setFloating(_ floating: Bool) {
        guard isFloating != floating else { return }
        cancelInteraction()
        isFloating = floating
        layer.shadowColor = UIColor.black.cgColor
        layer.cornerRadius = floating ? 24 : 0
        layer.cornerCurve = .continuous
        layer.shadowOpacity = floating ? 0.25 : 0
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        refreshPlacementActions()
        updateAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    /// The UIInputView root owns height, including zero-height hardware mode.
    /// A second height constraint on the content competes with that collapse.
    func useContainerSizing() {
        heightConstraint.isActive = false
    }

    private func refreshPlacementActions() {
        let keyboardSwitch = rows.flatMap { $0 }.first { $0.key.action == .switchKeyboard }
        grabber.accessibilityHint = usesSystemPlacement
            ? String(localized: "Drag to move.")
            : String(localized: "Drag to move. Double-tap to dock.")
        guard traitCollection.userInterfaceIdiom == .pad, onPlacementRequested != nil else {
            keyboardSwitch?.accessibilityCustomActions = nil
            grabber.accessibilityCustomActions = nil
            return
        }
        keyboardSwitch?.accessibilityCustomActions = usesSystemPlacement ? nil : [UIAccessibilityCustomAction(name: isFloating ? String(localized: "Dock Keyboard") : String(localized: "Float Keyboard")) { [weak self] _ in
            guard let self else { return false }
            self.cancelInteraction()
            self.onPlacementRequested?(self.isFloating ? .docked : .floating)
            return true
        }]
        grabber.accessibilityCustomActions = [
            (String(localized: "Move left"), CGPoint(x: -44, y: 0)),
            (String(localized: "Move right"), CGPoint(x: 44, y: 0)),
            (String(localized: "Move up"), CGPoint(x: 0, y: -44)),
            (String(localized: "Move down"), CGPoint(x: 0, y: 44))
        ].map { name, offset in UIAccessibilityCustomAction(name: name) { [weak self] _ in
            self?.onFloatingNudge?(offset); return true
        } }
    }

    @objc private func pinchKeyboard(_ gesture: UIPinchGestureRecognizer) {
        guard !usesSystemPlacement, onPlacementRequested != nil else { return }
        if gesture.state == .began {
            cancelInteraction()
            pinchPlacement = isFloating ? .floating : .docked
        }
        defer {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                pinchPlacement = nil
            }
        }
        // Reparenting or reloading an input root while recognition is still in
        // progress can cancel/reenter UIKit's own input transition. Finish the
        // gesture first, then move containers on the next main-queue turn.
        guard gesture.state == .ended, let initialPlacement = pinchPlacement else { return }
        let destination = Model.placementAfterPinch(gesture.scale, from: initialPlacement)
        guard destination != initialPlacement else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.usesSystemPlacement, self.window != nil,
                  self.isFloating == (initialPlacement == .floating) else { return }
            self.onPlacementRequested?(destination)
        }
    }

    @objc private func dockKeyboard() {
        guard !usesSystemPlacement else { return }
        onPlacementRequested?(.docked)
    }

    @objc private func dragFloatingKeyboard(_ gesture: UIPanGestureRecognizer) {
        guard isFloating else { return }
        // A system hosting item may be scaled by UIKit and moves during the
        // pan. Measure in its stationary window so one finger-point is one
        // window-point; the app overlay already supplies a stationary parent.
        let translation = gesture.translation(in: usesSystemPlacement ? window : superview)
        switch gesture.state {
        case .began, .changed: onFloatingDrag?(translation, false)
        case .ended: onFloatingDrag?(translation, true)
        case .cancelled, .failed: onFloatingDragCancelled?()
        default: break
        }
    }

    private func refreshSettings() {
        let prediction = SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction)
        if predictionEnabled != prediction {
            cancelInteraction()
            predictionEnabled = prediction
            predictionCache.removeAll()
        }
        updatePrediction()
        let enabled = SettingsStore.shared.value(Settings.Keyboard.touchSuggestions)
        if suggestionsEnabled != enabled {
            suggestionsEnabled = enabled
            lastSuggestionContext = nil
            host?.touchKeyboardInvalidateSuggestions()
            updateSuggestions()
        }
        hapticsEnabled = SettingsStore.shared.value(Settings.Keyboard.touchHaptics)
        let compactHeight = SettingsStore.shared.value(Settings.Keyboard.touchCompactHeight)
        let glyphs = SettingsStore.shared.value(Settings.Keyboard.touchGlyphs)
        if compactHeightEnabled != compactHeight || glyphsEnabled != glyphs { cancelInteraction() }
        compactHeightEnabled = compactHeight
        glyphsEnabled = glyphs
        loadToolbarConfiguration()
        rebuildKeys()
        updateAppearance()
        rebuildDrawer()
        setNeedsLayout()
    }

    private func updateAppearance() {
        palette = SettingsStore.shared.value(Settings.Keyboard.touchThemeAware)
            ? (host?.touchKeyboardThemeColors ?? ThemeManager.shared.currentThemeInfo?.colors).flatMap(TerminalTouchKeyboardPalette.init) : nil
        let style: UIUserInterfaceStyle = palette.map { $0.isLight ? .light : .dark } ?? .unspecified
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        let toolbar = palette?.background ?? TerminalTouchKeyboardAppearance.toolbar
        let floatingStyle = SettingsStore.shared.value(Settings.Keyboard.touchFloatingGlassStyle)
        let usesFloatingGlass = isFloating && floatingStyle != .solid && !UIAccessibility.isReduceTransparencyEnabled
        floatingGlass.isHidden = !usesFloatingGlass
        background.isHidden = usesFloatingGlass
        background.backgroundColor = palette?.background ?? TerminalTouchKeyboardAppearance.background
        // Paint the gaps around the glass toolbar too. A clear input root lets
        // UIKit's independently styled keyboard backdrop show through here.
        backgroundColor = usesFloatingGlass ? .clear : containerBackgroundColor
        if usesFloatingGlass {
            let tintOpacity = Model.floatingGlassTintOpacity(SettingsStore.shared.value(Settings.Keyboard.touchFloatingGlassTintOpacity))
            let tint = containerBackgroundColor.withAlphaComponent(CGFloat(tintOpacity))
            // One material for the whole detached card lets terminal content
            // show through the gaps without blurring the key labels themselves.
            if #available(iOS 26.0, *) {
                let glass = UIGlassEffect(style: floatingStyle == .clear ? .clear : .regular)
                glass.tintColor = tint
                floatingGlass.effect = glass
                floatingGlass.contentView.backgroundColor = .clear
            } else {
                floatingGlass.effect = UIBlurEffect(style: floatingStyle == .clear ? .systemUltraThinMaterial : .systemThinMaterial)
                floatingGlass.contentView.backgroundColor = tint
            }
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar.withAlphaComponent(0.14)
        } else if isFloating {
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar
        } else if #available(iOS 26.0, *), !UIAccessibility.isReduceTransparencyEnabled {
            let glass = UIGlassEffect(style: .clear)
            glass.tintColor = toolbar.withAlphaComponent(0.8)
            controlGlass.effect = glass
            controlGlass.contentView.backgroundColor = .clear
        } else if UIAccessibility.isReduceTransparencyEnabled {
            controlGlass.effect = nil
            controlGlass.contentView.backgroundColor = toolbar
        } else {
            controlGlass.effect = UIBlurEffect(style: .systemThinMaterial)
            controlGlass.contentView.backgroundColor = toolbar.withAlphaComponent(0.75)
        }
        controlGlass.backgroundColor = .clear
        if !usesFloatingGlass { floatingGlass.effect = nil }
        pageIndicator.effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIBlurEffect(style: .systemUltraThinMaterialDark)
        pageIndicator.contentView.backgroundColor = UIColor.black.withAlphaComponent(UIAccessibility.isReduceTransparencyEnabled ? 0.9 : 0.3)
        grabber.tintColor = palette?.toolbarInk ?? .label
        preview.backgroundColor = palette?.key ?? .secondarySystemBackground
        preview.textColor = palette?.ink ?? .label
        accents.backgroundColor = palette?.key ?? .secondarySystemBackground
        (controls + rows.flatMap { $0 }).forEach { $0.palette = palette }
        refreshWritingAssistance()
        rebuildToolbarDrawers()
        updateModifierAppearance()
        updateBackgroundEffect()
        onAppearanceChanged?()
    }

    private func updateBackgroundEffect() {
        effectPlacement = SettingsStore.shared.value(Settings.Shaders.keyboardBackgroundEffect)
        guard window != nil, !isHidden, !effectsSuspended,
              effectPlacement != .off, let effect = EffectManager.shared.keyboardEffect else {
            removeBackgroundEffect()
            return
        }

        // Keep glass above the effect, with the existing tint and material.
        // A detached glass keyboard must retain its transparent backdrop.
        let color: UIColor = !floatingGlass.isHidden ? .clear : (effectPlacement == .toolbar
            ? (palette?.background ?? TerminalTouchKeyboardAppearance.toolbar) : containerBackgroundColor)
        let configuration = UIHostingConfiguration {
            TerminalTouchKeyboardEffectBackground(backgroundColor: color, effect: effect)
        }
        .margins(.all, 0)
        .minSize(width: 0, height: 0)
        if let effectContentView {
            effectContentView.configuration = configuration
        } else {
            // UIKit reparents the input hierarchy while presenting the keyboard.
            // Its responder chain can still lead to MainView at that point, so
            // manually parenting a UIHostingController there causes a
            // UIViewControllerHierarchyInconsistency. A content configuration
            // embeds SwiftUI without a controller parent for us to manage.
            let view = configuration.makeContentView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            view.clipsToBounds = true
            view.layer.cornerCurve = .continuous
            effectContentView = view
            insertSubview(view, aboveSubview: background)
        }
        layoutBackgroundEffect()
    }

    private func layoutBackgroundEffect() {
        guard let view = effectContentView else { return }
        view.frame = effectPlacement == .toolbar ? controlGlass.frame : bounds
        view.layer.cornerRadius = effectPlacement == .toolbar ? 22 : (isFloating ? 24 : 0)
    }

    private func removeBackgroundEffect() {
        effectContentView?.removeFromSuperview()
        effectContentView = nil
    }

    private func makeCap(_ key: Model.Key, small: Bool = false) -> TerminalTouchKeycap {
        let cap = TerminalTouchKeycap(key, small: small)
        cap.palette = palette
        cap.activate = { [weak self, weak cap] in
            guard let self, let cap, self.canSend else { return }
            if case .modifier(let mod) = key.action {
                self.modifierState.begin(mod)
                self.modifierState.end(mod, at: ProcessInfo.processInfo.systemUptime)
                self.publishModifiers()
            } else if key.action == .joystick {
                self.showPage(.navigation)
            } else { self.perform(cap.key) }
        }
        if case .text(let text) = key.action, let variants = Model.accents[text] {
            cap.accessibilityCustomActions = variants.map { variant in
                UIAccessibilityCustomAction(name: String(variant)) { [weak self] _ in
                    guard let self, self.canSend else { return false }
                    self.perform(Model.Key(title: String(variant), action: .text(String(variant))))
                    return true
                }
            }
        }
        addSubview(cap)
        return cap
    }

    private func loadToolbarConfiguration() {
        let manager = KeyboardToolbarManager.shared
        func key(for slot: KeySlot) -> Model.Key? {
            switch slot {
            case .custom(let id):
                guard let custom = manager.customKey(for: id) else { return nil }
                return Model.Key(title: custom.label, action: .custom(id), symbol: custom.iconName, accessibility: custom.label)
            case .builtIn(let id):
                guard !manager.config.hiddenKeys.contains(id) else { return nil }
                let action: Model.Action
                let title: String
                switch id {
                case .esc: action = .key("\u{1b}"); title = "Esc"
                case .ctrl: action = .modifier(.control); title = "Ctrl"
                case .alt: action = .modifier(.alt); title = "Alt"
                case .shift: action = .modifier(.shift); title = "Shift"
                case .cmd: action = .modifier(.command); title = "Cmd"
                case .tab: action = .key("\t"); title = "Tab"
                case .arrowDrawerToggle: action = .joystick; title = id.displayName
                case .drawerToggle: action = .drawer; title = "…"
                case .dismiss: action = .dismiss; title = id.displayName
                case .tabSwitcher: action = .tabs; title = id.displayName
                case .compose: action = .compose; title = id.displayName
                case .paste: action = .paste; title = id.displayName
                default:
                    title = id.category == .symbol ? id.keyValue : id.displayName
                    action = id.category == .symbol ? .text(id.keyValue)
                        : (id.category == .navigation ? .key(id.keyValue) : .toolbar(id.keyValue))
                }
                return Model.Key(title: title, action: action, symbol: id.iconName, accessibility: id.displayName)
            }
        }
        configuredDrawerToggle = key(for: .builtIn(.drawerToggle))
        configuredMain = manager.config.mainRow.compactMap(key)
        configuredDrawers = manager.config.drawerRows.map { $0.compactMap(key) }
        if manager.drawerOpenByDefault && !toolbarDrawerOpenByDefault && toolbarDrawerState == .closed {
            toolbarDrawerState = .closed.toggled(rowCount: configuredDrawers.count, cycle: manager.drawerToggleMode == .cycle)
        }
        toolbarDrawerOpenByDefault = manager.drawerOpenByDefault
    }

    private func rebuildKeys() { rebuildKeysForWidth(max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right)) }

    private func rebuildKeysForWidth(_ width: CGFloat) {
        (controls + rows.flatMap { $0 }).forEach { $0.removeFromSuperview() }
        let toolbar = Model.toolbarKeys(main: configuredMain, drawers: configuredDrawers, width: width, drawerToggle: configuredDrawerToggle)
        controls = toolbar.main.map { makeCap($0, small: true) }
        toolbarDrawerKeys = toolbar.drawers
        rebuildToolbarDrawers()
        if let cap = controls.first(where: { $0.key.action == .toolbar(KeyID.writingAssistance.keyValue) }) {
            cap.isAccessibilityElement = false
        }
        bringSubviewToFront(writingAssistanceButton)
        rows = Model.rows(page: page).map { $0.map { makeCap($0) } }
        bringSubviewToFront(preview)
        bringSubviewToFront(accents)
        updateModifierAppearance()
        refreshPlacementActions()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        floatingGlass.frame = bounds
        if previousWidth != bounds.width {
            if previousWidth != 0 { cancelInteraction() }
            previousWidth = bounds.width
            rebuildKeys()
            rebuildDrawer()
        }
        let leading = isFloating ? 0 : max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0)
        let trailing = isFloating ? 0 : max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0)
        let width = max(0, bounds.width - leading - trailing)
        background.frame = isFloating ? bounds : CGRect(x: 0, y: toolbarHeight, width: bounds.width, height: max(0, bounds.height - toolbarHeight))
        background.layer.maskedCorners = isFloating ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        if isFloating { layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 24).cgPath }
        grabber.isHidden = !isFloating
        grabber.frame = CGRect(x: (bounds.width - 88) / 2, y: bounds.height - 44, width: 88, height: 44)
        controlGlass.frame = CGRect(x: leading + 2, y: 2, width: max(0, width - 4), height: toolbarHeight - 4)
        layoutBackgroundEffect()
        let toolbar = Model.toolbarKeys(main: configuredMain, drawers: configuredDrawers, width: width, drawerToggle: configuredDrawerToggle)
        if controls.map(\.key) != toolbar.main || toolbarDrawerKeys != toolbar.drawers {
            cancelInteraction()
            rebuildKeysForWidth(width)
            rebuildDrawer()
            setNeedsLayout()
        }
        for (cap, rect) in zip(controls, Model.frames(keys: controls.map(\.key), width: width, y: toolbarDrawerHeight, height: 48, inset: 5)) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
        if let cap = controls.first(where: { $0.key.action == .toolbar(KeyID.writingAssistance.keyValue) }) {
            writingAssistanceButton.frame = cap.frame
            writingAssistanceButton.isHidden = false
        } else { writingAssistanceButton.isHidden = true }
        for (index, row) in toolbarDrawerRows.enumerated() {
            layoutToolbarDrawer(row, buttons: toolbarDrawerButtons[index], position: index,
                                leading: leading, width: width)
        }
        var y = toolbarHeight
        let contentHeight = rowHeight * 4 + (suggestionsEnabled ? 36 : 0)
        // This HUD floats over the keys; it never contributes to keyboard height.
        pageIndicator.frame = CGRect(x: leading + (width - 160) / 2, y: toolbarHeight + (contentHeight - 64) / 2, width: 160, height: 64)
        pageIndicatorTitle.frame = CGRect(x: 8, y: 10, width: 144, height: 22)
        let dotSpacing: CGFloat = 14
        for (index, dot) in pageIndicatorDots.enumerated() {
            let size: CGFloat = index == toolPage.rawValue ? 8 : 6
            dot.frame = CGRect(x: 80 + (CGFloat(index) - CGFloat(pageIndicatorDots.count - 1) / 2) * dotSpacing - size / 2,
                               y: 45 - size / 2, width: size, height: size)
            dot.layer.cornerRadius = size / 2
            dot.backgroundColor = UIColor.white.withAlphaComponent(index == toolPage.rawValue ? 1 : 0.4)
        }
        drawer.isHidden = !drawerOpen
        presets.isHidden = toolPage != .shortcuts
        if drawerOpen {
            if toolPage == .shortcuts {
                presets.frame = CGRect(x: leading + 8, y: y + 3, width: max(0, width - 16), height: 30)
            }
            let presetHeight: CGFloat = toolPage == .shortcuts ? 38 : 0
            drawer.frame = CGRect(x: leading + 5, y: y + presetHeight, width: max(0, width - 10), height: max(0, contentHeight - presetHeight))
            let cellWidth = drawer.bounds.width / CGFloat(drawerColumns)
            let rowCount = (drawerButtons.count + drawerColumns - 1) / drawerColumns
            let preferredCellHeight: CGFloat = compact ? 40 : 46
            // Fit every navigation key, including F12, without scrolling.
            let cellHeight = toolPage == .navigation
                ? min(preferredCellHeight, drawer.bounds.height / CGFloat(max(1, rowCount)))
                : preferredCellHeight
            for (i, button) in drawerButtons.enumerated() {
                button.frame = CGRect(x: CGFloat(i % drawerColumns) * cellWidth + 2, y: CGFloat(i / drawerColumns) * cellHeight + 2,
                                      width: max(0, cellWidth - 4), height: max(0, cellHeight - 4))
            }
            drawer.contentSize = CGSize(width: drawer.bounds.width, height: CGFloat(rowCount) * cellHeight)
        }
        suggestions.isHidden = !suggestionsEnabled || drawerOpen
        if suggestionsEnabled {
            suggestions.frame = CGRect(x: leading + 8, y: y, width: width - 16, height: 36)
            y += 36
        }
        rows.flatMap { $0 }.forEach { $0.isHidden = drawerOpen }
        let typingTop = y
        for (index, row) in rows.enumerated() {
            var inset: CGFloat = index == 1 && page == .letters ? width / 20 + 2 : 2
            if index == 3, compactHeightEnabled, traitCollection.userInterfaceIdiom == .phone {
                // Keep the entire bottom row at its normal height while fitting
                // its end keys inside the rounded screen corners.
                inset = max(2, min(width / 10, deviceBottomInset - min(leading, trailing)))
            }
            for (cap, rect) in zip(row, Model.frames(keys: row.map(\.key), width: width, y: y, height: rowHeight, inset: inset)) { cap.frame = rect.offsetBy(dx: leading, dy: 0) }
            y += rowHeight
        }
        let targets = rows.flatMap { $0 }.map { Model.HitTarget(key: $0.key, frame: $0.frame) }
        let typingBounds = CGRect(x: leading, y: typingTop, width: width, height: y - typingTop)
        if typingGeometry.bounds != typingBounds || typingGeometry.targets.map(\.frame) != targets.map(\.frame)
            || typingGeometry.targets.map(\.key) != targets.map(\.key) {
            if !contacts.isEmpty { cancelInteraction() }
            typingGeometry = Model.TypingGeometry(targets: targets, bounds: typingBounds)
        }
        if abs(heightConstraint.constant - desiredHeight) > 0.5 {
            heightConstraint.constant = desiredHeight
            invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak self] in self?.onHeightChanged?() }
        }
    }
    override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            cancelInteraction()
            removeBackgroundEffect()
        } else {
            refreshSettings()
            updateSuggestions()
        }
    }

    override var isHidden: Bool {
        didSet { if oldValue != isHidden { updateBackgroundEffect() } }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        if !writingAssistanceButton.isHidden, writingAssistanceButton.frame.contains(point) {
            return writingAssistanceButton.hitTest(convert(point, to: writingAssistanceButton), with: event)
        }
        if cap(at: point) != nil { return self }
        return super.hitTest(point, with: event)
    }
    private func cap(at point: CGPoint) -> TerminalTouchKeycap? {
        if let control = controls.first(where: { $0.frame.contains(point) }) { return control }
        guard !drawerOpen, let index = typingGeometry.hit(at: point) else { return nil }
        return rows.flatMap { $0 }[index]
    }
    private func feedback() {
        #if !os(visionOS)
        if hapticsEnabled { haptic.impactOccurred(intensity: 0.45) }
        #endif
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        hidePageIndicator()
        guard canSend else { return }
        sequenceTask?.cancel()
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            let point = touch.location(in: self)
            guard var key = cap(at: point) else { continue }
            // Tablet touches remain cancellable until release so a pinch can take over.
            if traitCollection.userInterfaceIdiom != .pad {
                commitPrecedingContacts(before: nextContactOrder &+ 1)
            }
            var selection: Model.TouchSelection?
            if key.key.isText {
                let snapshot = host?.touchKeyboardPredictionContext
                let allowsPrediction = modifierState.rawValue & ~Model.Modifier.shift.rawValue == 0
                    && !modifierState.locked.contains(.shift)
                let prior = predictionEnabled && allowsPrediction
                    ? snapshot.flatMap { predictionPrior(for: $0) } : nil
                if let index = typingGeometry.predictedHit(at: point, prior: prior) {
                    key = rows.flatMap { $0 }[index]
                    selection = Model.TouchSelection(point: point, selected: index, modifiers: modifierState.rawValue, prior: prior)
                }
            }
            let id = ObjectIdentifier(touch)
            nextContactOrder &+= 1
            let contact = Contact(key: key, point: point, order: nextContactOrder, selection: selection)
            contacts[id] = contact
            key.pressed = true
            feedback()
            if case .modifier(let mod) = key.key.action {
                modifierState.begin(mod)
                publishModifiers()
            } else {
                showPreview(key)
                contact.task = Task { @MainActor [weak self, weak contact, key] in
                    try? await Task.sleep(for: .milliseconds(420))
                    guard !Task.isCancelled, let self, let contact, self.contacts[id] === contact, self.canSend,
                          !contact.consumed, contact.current === contact.initial else { return }
                    switch key.key.action {
                    case .key("\u{7f}"):
                        contact.consumed = true
                        while !Task.isCancelled, self.contacts[id] === contact, self.canSend {
                            self.perform(key.key)
                            try? await Task.sleep(for: .milliseconds(45))
                        }
                    case .text(" "):
                        contact.trackpad = true
                        contact.consumed = true
                        self.preview.isHidden = true
                        key.label.text = "↔  cursor  ↕"
                        self.feedback()
                    case .text(let text):
                        if let variants = Model.accents[text] { self.showAccents(variants, contact: contact) }
                    case .dismiss:
                        contact.consumed = true
                        self.cancelInteraction()
                        self.onPinHidden?()
                    default: break
                    }
                }
            }
        }
        refreshContactFeedback()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let contact = contacts[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            if contact.selection != nil && contact.consumed && !contact.accent && !contact.trackpad { continue }
            if contact.accent {
                accentIndex = min(accentChoices.count - 1, max(0, Int((point.x - accents.frame.minX) / (accents.bounds.width / CGFloat(accentChoices.count)))))
                updateAccentSelection()
                continue
            }
            if contact.trackpad {
                let dx = point.x - contact.anchor.x, dy = point.y - contact.anchor.y
                if abs(dx) >= 12 || abs(dy) >= 18 {
                    let horizontal = abs(dx) >= abs(dy)
                    keyPressed(horizontal ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A"), modifiers: [])
                    contact.anchor = point
                }
                continue
            }
            if contact.initial.key.action == .joystick {
                let dx = point.x - contact.origin.x, dy = point.y - contact.origin.y
                let direction: String? = hypot(dx, dy) < 18 ? nil :
                    (abs(dx) > abs(dy) ? (dx > 0 ? "\u{1b}[C" : "\u{1b}[D") : (dy > 0 ? "\u{1b}[B" : "\u{1b}[A"))
                if direction != contact.direction {
                    contact.task?.cancel()
                    contact.direction = direction
                    if let direction {
                        contact.consumed = true
                        keyPressed(direction, modifiers: [])
                        contact.task = Task { @MainActor [weak self, weak contact] in
                            try? await Task.sleep(for: .milliseconds(320))
                            while !Task.isCancelled, let self, let contact, contact.direction == direction, self.canSend {
                                self.keyPressed(direction, modifiers: [])
                                try? await Task.sleep(for: .milliseconds(55))
                            }
                        }
                    }
                }
                continue
            }
            if case .modifier = contact.initial.key.action { continue }
            if contact.selection != nil {
                move(contact, to: point)
                continue
            }
            let next = cap(at: point)
            // Sliding adjusts the typed key, never activates a nearby action or modifier.
            let compatible: TerminalTouchKeycap? = {
                if next === contact.initial { return next }
                if case .text = contact.initial.key.action, let next, case .text = next.key.action { return next }
                return nil
            }()
            if compatible !== contact.current {
                contact.task?.cancel()
                contact.current?.pressed = false
                contact.current = compatible
                compatible?.pressed = true
                if let compatible { showPreview(compatible) } else { preview.isHidden = true }
            }
        }
        refreshContactFeedback()
    }

    private func move(_ contact: Contact, to point: CGPoint) {
        guard contact.selection?.move(to: point, in: typingGeometry,
                                      dockedPad: traitCollection.userInterfaceIdiom == .pad && !isFloating) == true else { return }
        contact.task?.cancel()
        contact.current = contact.selection?.selected.map { rows.flatMap { $0 }[$0] }
    }

    private func commit(_ contact: Contact, at point: CGPoint? = nil) {
        guard !contact.consumed else { return }
        let index: Int?
        if let point = point ?? contact.selection?.latestPoint {
            index = contact.selection?.finish(at: point, in: typingGeometry,
                dockedPad: traitCollection.userInterfaceIdiom == .pad && !isFloating)
        } else {
            index = contact.selection?.takeSelection()
        }
        contact.consumed = true
        contact.task?.cancel()
        guard let index else { return }
        perform(typingGeometry.targets[index].key, modifiers: KeyModifiers(rawValue: contact.selection!.modifiers))
    }

    private func commitPrecedingContacts(before order: UInt64) {
        for contact in contacts.values.sorted(by: { $0.order < $1.order })
            where contact.order < order && !contact.consumed && !contact.trackpad
                && !contact.accent && contact.selection != nil {
            commit(contact)
        }
    }

    private func refreshContactFeedback() {
        let active = contacts.values.sorted { $0.order < $1.order }
        var pressed = Set<ObjectIdentifier>()
        for contact in active where contact.selection == nil || !contact.consumed || contact.trackpad || contact.accent {
            if let cap = contact.current { pressed.insert(ObjectIdentifier(cap)) }
            if contact.trackpad { contact.initial.label.text = "↔  cursor  ↕" }
        }
        for cap in controls + rows.flatMap({ $0 }) {
            let value = pressed.contains(ObjectIdentifier(cap))
            if cap.pressed != value { cap.pressed = value }
        }
        preview.isHidden = true
        if !active.contains(where: { $0.accent || $0.trackpad }),
           let contact = active.last(where: { !$0.consumed && $0.current != nil }), let cap = contact.current {
            showPreview(cap, modifiers: contact.selection?.modifiers)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }
    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        // Resolve letters before released modifiers when UIKit batches the chord.
        let ordered = touches.sorted {
            let a = contacts[ObjectIdentifier($0)]?.initial.key.action
            let b = contacts[ObjectIdentifier($1)]?.initial.key.action
            if case .modifier = a { return false }
            if case .modifier = b { return true }
            return (contacts[ObjectIdentifier($0)]?.order ?? 0) < (contacts[ObjectIdentifier($1)]?.order ?? 0)
        }
        for touch in ordered {
            if !cancelled, canSend, let contact = contacts[ObjectIdentifier(touch)] {
                commitPrecedingContacts(before: contact.order)
            }
            guard let contact = contacts.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            contact.task?.cancel()
            contact.current?.pressed = false
            contact.initial.pressed = false
            if case .modifier(let mod) = contact.initial.key.action {
                modifierState.end(mod, at: touch.timestamp, cancelled: cancelled || !contact.initial.frame.contains(touch.location(in: self)))
                publishModifiers()
            } else if !cancelled, canSend {
                if contact.accent, accents.frame.insetBy(dx: -20, dy: -70).contains(touch.location(in: self)) {
                    perform(Model.Key(title: accentChoices[accentIndex], action: .text(accentChoices[accentIndex])),
                            modifiers: contact.selection.map { KeyModifiers(rawValue: $0.modifiers) })
                } else if !contact.consumed, contact.selection != nil {
                    commit(contact, at: touch.location(in: self))
                } else if !contact.consumed, let current = contact.current, current.frame.contains(touch.location(in: self)) {
                    perform(current.key)
                }
            }
        }
        accents.isHidden = !contacts.values.contains { $0.accent }
        updateModifierAppearance()
        refreshContactFeedback()
    }

    func cancelInteraction(preservingModifiers: Bool = false, preservingSuggestions: Bool = false) {
        hidePageIndicator()
        contacts.values.forEach { $0.task?.cancel(); $0.initial.pressed = false; $0.current?.pressed = false }
        contacts.removeAll()
        (drawerButtons + toolbarDrawerButtons.flatMap { $0 }).forEach { $0.cancelRepeat() }
        sequenceTask?.cancel(); sequenceTask = nil
        if !preservingSuggestions {
            suggestionTask?.cancel(); suggestionTask = nil
            lastSuggestionContext = nil
            suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        predictionTask?.cancel(); predictionTask = nil; pendingPrediction = nil
        if preservingModifiers { modifierState.cancelHeld() } else { modifierState.reset() }
        publishModifiers()
        preview.isHidden = true
        accents.isHidden = true
    }

    private func publishModifiers() {
        onModifiersChanged?(KeyModifiers(rawValue: modifierState.rawValue))
        updateModifierAppearance()
    }
    private func updateModifierAppearance() {
        for (button, modifier) in toolbarDrawerModifiers {
            button.isSelected = modifierState.isActive(modifier)
            button.configuration?.baseBackgroundColor = button.isSelected ? (palette?.toolbarInk ?? .label).withAlphaComponent(0.2) : .clear
            button.accessibilityValue = modifierState.locked.contains(modifier) ? "Locked" : (button.isSelected ? "On" : "Off")
        }
        for cap in controls + rows.flatMap({ $0 }) {
            if cap.key.action == .drawer { cap.selected = toolbarDrawerState != .closed }
            switch cap.key.action {
            case .key("\u{1b}"): cap.setSymbol(glyphsEnabled ? "escape" : nil)
            case .key("\t"): cap.setSymbol(glyphsEnabled ? "arrow.right.to.line" : nil)
            case .modifier(.control): cap.setSymbol(glyphsEnabled ? "control" : nil)
            case .modifier(.alt): cap.setSymbol(glyphsEnabled ? "option" : nil)
            case .modifier(.command): cap.setSymbol(glyphsEnabled ? "command" : nil)
            default: break
            }
            if case .modifier(let mod) = cap.key.action {
                cap.selected = modifierState.isActive(mod)
                cap.locked = modifierState.locked.contains(mod)
                cap.accessibilityValue = modifierState.locked.contains(mod) ? "Locked" : (cap.selected ? "On" : "Off")
                if mod == .shift {
                    cap.setSymbol(glyphsEnabled ? (modifierState.locked.contains(mod) ? "capslock.fill" : (cap.selected ? "shift.fill" : "shift")) : nil)
                }
            } else if case .text(let text) = cap.key.action {
                cap.updateColor()
                cap.label.text = text == " " ? "space" : (modifierState.isActive(.shift) ? text.uppercased() : text)
            }
        }
    }

    private func perform(_ key: Model.Key, modifiers: KeyModifiers? = nil) {
        guard canSend else { return }
        switch key.action {
        case .text(let text):
            let mods = modifiers ?? KeyModifiers(rawValue: modifierState.rawValue)
            if mods.subtracting(.shift).isEmpty {
                // Shift changes letters without invoking terminal shortcut encoding.
                host?.touchKeyboardInsert(mods.contains(.shift) ? text.uppercased() : text)
            } else { host?.touchKeyboardSend(text, modifiers: mods) }
            modifierState.consume(mods.rawValue); publishModifiers(); updateSuggestions(); updatePrediction()
        case .key(let value): keyPressed(value, modifiers: [])
        case .page:
            cancelInteraction()
            if key.title == "#+=" { page = .symbols }
            else if key.title == "123" { page = .numbers }
            else { page = .letters }
            rebuildKeys()
        case .switchKeyboard: cancelInteraction(); onSwitchKeyboard?()
        case .drawer:
            toggleToolbarDrawer()
        case .dismiss: cancelInteraction(); onDismiss?()
        case .compose: cancelInteraction(); onCompose?()
        case .paste: cancelInteraction(); onPaste?()
        case .tabs: cancelInteraction(); onTabs?()
        case .toolbar(let action):
            guard action != KeyID.writingAssistance.keyValue else { return }
            cancelInteraction(); onToolbarAction?(action)
        case .custom(let id):
            guard let custom = KeyboardToolbarManager.shared.customKey(for: id) else { return }
            if let character = custom.plainCharacter {
                perform(Model.Key(title: String(character), action: .text(String(character))))
            } else { sendCustomSequence(custom.sequence) }
        case .joystick: showPage(.navigation)
        case .modifier: break
        }
    }

    func keyPressed(_ key: String, modifiers: KeyModifiers) {
        guard canSend else { return }
        host?.touchKeyboardSend(key, modifiers: modifiers.union(KeyModifiers(rawValue: modifierState.rawValue)))
        modifierState.consume(); publishModifiers(); updateSuggestions()
        updatePrediction()
    }
    func sendRawData(_ data: Data) { guard canSend else { return }; sequenceDelegate?.sendRawData(data) }

    private func showPreview(_ cap: TerminalTouchKeycap, modifiers: Int? = nil) {
        // Show above-finger feedback in both full-size and detached layouts.
        let showsPreview = traitCollection.userInterfaceIdiom == .phone
            || traitCollection.userInterfaceIdiom == .pad
        guard showsPreview, case .text(let text) = cap.key.action, text != " ", !UIAccessibility.isVoiceOverRunning else { return }
        let shifted = (modifiers ?? modifierState.rawValue) & Model.Modifier.shift.rawValue != 0
        preview.text = shifted ? text.uppercased() : text
        preview.frame = CGRect(x: min(max(2, cap.frame.midX - 26), bounds.width - 54), y: max(0, cap.frame.minY - 49), width: 52, height: 55)
        preview.isHidden = false
        bringSubviewToFront(preview)
    }
    private func showAccents(_ variants: String, contact: Contact) {
        contact.accent = true; contact.consumed = true
        preview.isHidden = true
        let shifted = (contact.selection?.modifiers ?? modifierState.rawValue) & Model.Modifier.shift.rawValue != 0
        accentChoices = variants.map { shifted ? String($0).uppercased() : String($0) }
        accents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for value in accentChoices {
            let label = UILabel(); label.text = value; label.textAlignment = .center; label.font = .systemFont(ofSize: 24)
            accents.addArrangedSubview(label)
        }
        let width = min(bounds.width - 8, CGFloat(accentChoices.count) * 38)
        accents.frame = CGRect(x: min(max(4, contact.initial.frame.midX - width / 2), bounds.width - width - 4),
                              y: max(0, contact.initial.frame.minY - 49), width: width, height: 48)
        accentIndex = min(accentChoices.count - 1, max(0, Int((contact.origin.x - accents.frame.minX) / (width / CGFloat(accentChoices.count)))))
        updateAccentSelection()
        accents.isHidden = false
        bringSubviewToFront(accents)
        feedback()
    }
    private func updateAccentSelection() {
        for (index, view) in accents.arrangedSubviews.enumerated() {
            view.backgroundColor = index == accentIndex ? .tertiarySystemFill : .clear
        }
    }

    private func showPage(_ page: Model.ToolPage) {
        guard page != toolPage else { return }
        cancelInteraction(preservingModifiers: true)
        toolPage = page
        rebuildDrawer()
        updateSuggestions()
        showPageIndicator()
        UIAccessibility.post(notification: .pageScrolled, argument: page.title)
    }

    private func showPageIndicator() {
        pageIndicatorHideTask?.cancel()
        pageIndicatorTitle.text = toolPage.title
        bringSubviewToFront(pageIndicator)
        setNeedsLayout()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.pageIndicator.alpha = 1
        }
        // Match the hidden-tab-bar indicator's 1.5-second display and fade.
        pageIndicatorHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.pageIndicator.alpha = 0
            }
        }
    }

    private func hidePageIndicator() {
        pageIndicatorHideTask?.cancel()
        pageIndicatorHideTask = nil
        pageIndicator.layer.removeAllAnimations()
        pageIndicator.alpha = 0
    }

    @objc private func swipePage(_ gesture: TerminalKeyboardPageSwipe) {
        showPage(toolPage.moved(by: gesture.offset))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is TerminalKeyboardPageSwipe else { return true }
        let point = touch.location(in: self)
        // Toolbar joysticks, presets, and the floating handle
        // keep their own gestures. Only the key surface changes pages.
        guard point.y >= toolbarHeight, point.y < bounds.height - bottomInset,
              touch.view !== presets, touch.view?.isDescendant(of: presets) != true else { return false }
        return !contacts.values.contains { $0.trackpad || $0.accent || $0.consumed }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let other: UIGestureRecognizer
        if gestureRecognizer === placementPinch {
            other = otherGestureRecognizer
        } else if otherGestureRecognizer === placementPinch {
            other = gestureRecognizer
        } else {
            return false
        }
        // Adding a second finger while scrolling a tools page must still allow
        // the app-contained keyboard's placement pinch.
        if other === drawer.panGestureRecognizer || other is TerminalKeyboardPageSwipe { return true }
        return false
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is TerminalKeyboardPageSwipe else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        // A held Space or accent selection owns the contact even if its drag
        // later travels far enough to look like a page swipe.
        return !contacts.values.contains { $0.trackpad || $0.accent || $0.consumed }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .left || direction == .right else { return super.accessibilityScroll(direction) }
        showPage(toolPage.moved(by: direction == .left ? 1 : -1))
        return true
    }
    @objc private func changePreset() {
        guard Model.Preset.allCases.indices.contains(presets.selectedSegmentIndex) else { return }
        preset = Model.Preset.allCases[presets.selectedSegmentIndex]
        rebuildDrawer()
    }
    @discardableResult
    private func drawerButton(_ title: String, subtitle: String? = nil, repeats: Bool = false,
                              in container: UIView? = nil, action: @escaping () -> Void) -> TerminalTouchRepeatingButton {
        let button = TerminalTouchRepeatingButton(type: .system)
        var config = palette == nil ? UIButton.Configuration.tinted() : UIButton.Configuration.filled()
        config.title = title
        config.subtitle = subtitle
        config.baseForegroundColor = palette?.ink ?? .label
        config.baseBackgroundColor = palette?.key ?? .secondaryLabel
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .systemFont(ofSize: subtitle == nil && title.count <= 4 ? 17 : 12, weight: .medium); return output
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { input in
            var output = input; output.font = .monospacedSystemFont(ofSize: 12, weight: .regular); return output
        }
        button.configuration = config
        button.titleLabel?.numberOfLines = 2
        button.accessibilityLabel = [title, subtitle].compactMap { $0 }.joined(separator: ", ")
        button.addAction(UIAction { [weak self] _ in guard self?.canSend == true else { return }; action() }, for: .touchUpInside)
        if repeats { button.enableRepeat { [weak self] in guard self?.canSend == true else { return }; action() } }
        (container ?? drawer).addSubview(button)
        if container == nil { drawerButtons.append(button) }
        return button
    }
    private func refreshWritingAssistance() {
        let enabled = [
            (SettingsStore.shared.value(Settings.Keyboard.touchLetterPrediction), String(localized: "Letter Prediction")),
            (SettingsStore.shared.value(Settings.Keyboard.touchSuggestions), String(localized: "Suggestions")),
            (SettingsStore.shared.value(Settings.Keyboard.doubleSpaceForPeriod), String(localized: "Double-Space Period Shortcut"))
        ].filter { $0.0 }.map { $0.1 }
        writingAssistanceButton.accessibilityValue = enabled.isEmpty ? String(localized: "Off") : enabled.joined(separator: ", ")
        writingAssistanceButton.menu = writingAssistanceMenu()
    }

    private func writingAssistanceMenu() -> UIMenu {
        func toggle(_ setting: SettingKey<Bool>, title: String, icon: String) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: icon),
                     state: SettingsStore.shared.value(setting) ? .on : .off) { _ in
                let store = SettingsStore.shared
                store.set(setting, !store.value(setting))
            }
        }
        return UIMenu(children: [
            toggle(Settings.Keyboard.touchLetterPrediction, title: String(localized: "Letter Prediction"), icon: "textformat.abc"),
            toggle(Settings.Keyboard.touchSuggestions, title: String(localized: "Suggestions"), icon: "text.bubble"),
            toggle(Settings.Keyboard.doubleSpaceForPeriod, title: String(localized: "Double-Space Period Shortcut"), icon: "character.cursor.ibeam")
        ])
    }

    private func rebuildDrawer() {
        refreshWritingAssistance()
        drawerButtons.forEach { $0.cancelRepeat(); $0.removeFromSuperview() }; drawerButtons.removeAll()
        drawer.contentOffset = .zero
        drawerColumns = toolPage == .symbols ? 8 : 4
        switch toolPage {
        case .typing: break
        case .symbols:
            for char in "`~^_\\|[]{}<>/=-\"';:()@$%&*+?!#" {
                let text = String(char)
                drawerButton(text) { [weak self] in self?.perform(Model.Key(title: text, action: .text(text))) }
            }
        case .navigation:
            let keys = [("←", "\u{1b}[D"), ("↓", "\u{1b}[B"), ("↑", "\u{1b}[A"), ("→", "\u{1b}[C"),
                        ("Home", "\u{1b}[H"), ("End", "\u{1b}[F"), ("PgUp", "\u{1b}[5~"), ("PgDn", "\u{1b}[6~"), ("Delete", "\u{1b}[3~")]
            for (title, key) in keys { drawerButton(title, repeats: true) { [weak self] in self?.keyPressed(key, modifiers: []) } }
            for index in 1...12 { drawerButton("F\(index)") { [weak self] in self?.keyPressed("F\(index)", modifiers: []) } }
        case .shortcuts:
            for shortcut in preset.shortcuts {
                drawerButton(shortcut.title, subtitle: shortcut.chord) { [weak self] in
                    self?.keyPressed(shortcut.key, modifiers: KeyModifiers(rawValue: shortcut.modifiers))
                }
            }
            if preset == .agent {
                drawerButton("Compose") { [weak self] in self?.perform(Model.Key(title: "Compose", action: .compose)) }
                drawerButton("Paste") { [weak self] in self?.perform(Model.Key(title: "Paste", action: .paste)) }
            }
            for command in preset.slashCommands {
                drawerButton(command) { [weak self] in
                    guard let self else { return }
                    // Commands stay literal even with Shift or Control latched.
                    self.modifierState.consume()
                    self.perform(Model.Key(title: command, action: .text(command)), modifiers: [])
                }
            }
        }
        updateModifierAppearance()
        setNeedsLayout()
    }

    private func layoutToolbarDrawer(_ row: UIScrollView, buttons: [TerminalTouchRepeatingButton],
                                     position: Int, leading: CGFloat, width: CGFloat) {
        row.frame = CGRect(x: leading + 5, y: CGFloat(position) * 44, width: max(0, width - 10), height: 44)
        var x: CGFloat = 0
        for button in buttons {
            let titleWidth = ((button.configuration?.title ?? "") as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width
            let buttonWidth = max(40, min(120, titleWidth + 20))
            button.frame = CGRect(x: x, y: 2, width: buttonWidth, height: 40)
            x += buttonWidth + 2
        }
        row.contentSize = CGSize(width: x, height: 44)
    }

    private func toggleToolbarDrawer() {
        cancelInteraction(preservingModifiers: true, preservingSuggestions: true)
        // Keep system-detached resizing local to the card's container; the native
        // keyboard window also owns unrelated presentation/positioning views.
        let systemDetached = isFloating && usesSystemPlacement
        let layoutRoot: UIView = systemDetached ? (superview ?? self) : (window ?? superview ?? self)
        layoutRoot.layoutIfNeeded()
        layoutIfNeeded()
        let oldRows = toolbarDrawerRows
        let oldHeight = toolbarDrawerHeight
        toolbarDrawerState = toolbarDrawerState.toggled(rowCount: toolbarDrawerKeys.count,
            cycle: KeyboardToolbarManager.shared.drawerToggleMode == .cycle)
        let outgoing = rebuildToolbarDrawers(preservingRows: true)
        let incoming = toolbarDrawerRows.filter { !oldRows.contains($0) }
        let animated = window != nil && !UIAccessibility.isReduceMotionEnabled

        // Lay out new keys before fading them in. Existing rows retain their
        // frames and horizontal scroll offsets until the animation starts.
        let leading = isFloating ? 0 : max(safeAreaInsets.left, window?.safeAreaInsets.left ?? 0)
        let trailing = isFloating ? 0 : max(safeAreaInsets.right, window?.safeAreaInsets.right ?? 0)
        for (index, row) in toolbarDrawerRows.enumerated() where incoming.contains(row) {
            layoutToolbarDrawer(row, buttons: toolbarDrawerButtons[index], position: index,
                                leading: leading, width: max(0, bounds.width - leading - trailing))
            row.alpha = animated ? 0 : 1
        }
        for row in outgoing {
            row.isUserInteractionEnabled = false
            row.accessibilityElementsHidden = true
        }
        updateModifierAppearance()
        let heightDelta = toolbarDrawerHeight - oldHeight
        let changes = {
            // Publish synchronously so UIKit's self-sizing input root and the
            // content move in the same animation, without reloadInputViews().
            self.heightConstraint.constant = self.desiredHeight
            self.invalidateIntrinsicContentSize()
            if heightDelta != 0 { self.onHeightChanged?() }
            self.setNeedsLayout()
            layoutRoot.layoutIfNeeded()
            self.layoutIfNeeded()
            incoming.forEach { $0.alpha = 1 }
            outgoing.forEach {
                $0.alpha = 0
                $0.transform = CGAffineTransform(translationX: 0, y: heightDelta)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0,
                           options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: changes) { _ in
                outgoing.forEach { $0.removeFromSuperview() }
            }
        } else {
            UIView.performWithoutAnimation(changes)
            outgoing.forEach { $0.removeFromSuperview() }
        }
    }

    /// Reuse rows during a toggle; configuration and appearance changes rebuild
    /// them. The caller keeps outgoing rows alive only for their exit animation.
    @discardableResult
    private func rebuildToolbarDrawers(preservingRows: Bool = false) -> [UIScrollView] {
        toolbarDrawerButtons.flatMap { $0 }.forEach { $0.cancelRepeat() }
        let previousRows = Dictionary(uniqueKeysWithValues: zip(toolbarDrawerIndices, zip(toolbarDrawerRows, toolbarDrawerButtons)))
        toolbarDrawerState = toolbarDrawerState.clamped(rowCount: toolbarDrawerKeys.count)
        let indices = toolbarDrawerState.visibleRows(rowCount: toolbarDrawerKeys.count)
        let outgoing = toolbarDrawerIndices.compactMap { index -> UIScrollView? in
            preservingRows && indices.contains(index) ? nil : previousRows[index]?.0
        }
        if !preservingRows { outgoing.forEach { $0.removeFromSuperview() } }
        toolbarDrawerRows.removeAll()
        toolbarDrawerButtons.removeAll()
        toolbarDrawerIndices = indices
        toolbarDrawerModifiers = toolbarDrawerModifiers.filter { button, _ in
            preservingRows && indices.contains { index in previousRows[index]?.1.contains(button) == true }
        }
        for index in indices {
            if preservingRows, let (row, buttons) = previousRows[index] {
                toolbarDrawerRows.append(row)
                toolbarDrawerButtons.append(buttons)
                continue
            }
            let row = UIScrollView()
            row.showsHorizontalScrollIndicator = false
            row.alwaysBounceHorizontal = false
            addSubview(row)
            toolbarDrawerRows.append(row)
            var buttons: [TerminalTouchRepeatingButton] = []
            for key in toolbarDrawerKeys[index] {
                let repeats: Bool = { if case .key = key.action { return true }; return false }()
                let button = drawerButton(key.title, repeats: repeats, in: row) { [weak self] in
                    guard let self else { return }
                    if case .modifier(let modifier) = key.action {
                        self.modifierState.begin(modifier)
                        self.modifierState.end(modifier, at: ProcessInfo.processInfo.systemUptime)
                        self.publishModifiers()
                    } else { self.perform(key) }
                }
                var config = button.configuration!
                config.baseBackgroundColor = .clear
                config.baseForegroundColor = palette?.toolbarInk ?? .label
                let usesGlyph: Bool = {
                    switch key.action {
                    case .modifier, .key("\u{1b}"), .key("\t"): return glyphsEnabled
                    default: return true
                    }
                }()
                if let symbol = key.symbol, usesGlyph,
                   let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)) {
                    config.title = nil
                    config.image = image
                }
                button.configuration = config
                button.accessibilityLabel = key.accessibility ?? key.title
                if case .modifier(let modifier) = key.action { toolbarDrawerModifiers[button] = modifier }
                if key.action == .toolbar(KeyID.writingAssistance.keyValue) {
                    button.showsMenuAsPrimaryAction = true
                    button.menu = writingAssistanceMenu()
                }
                buttons.append(button)
            }
            toolbarDrawerButtons.append(buttons)
        }
        setNeedsLayout()
        return outgoing
    }

    private func sendCustomSequence(_ steps: [SequenceStep]) {
        modifierState.consume()
        cancelInteraction(preservingModifiers: true)
        host?.touchKeyboardInvalidateSuggestions()
        sequenceTask = Task { @MainActor [weak self] in
            for step in steps {
                guard !Task.isCancelled, let self, self.canSend else { return }
                let data = step.terminalData()
                self.sequenceDelegate?.sendRawData(data)
                if data.last == 0x1b { try? await Task.sleep(for: .milliseconds(50)) }
            }
        }
    }

    func updateSuggestions() {
        guard suggestionsEnabled, canSend, let context = host?.touchKeyboardSuggestionContext else {
            suggestionTask?.cancel(); lastSuggestionContext = nil
            suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard lastSuggestionContext != context else { return }
        lastSuggestionContext = context
        suggestionTask?.cancel()
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.canSend, self.host?.touchKeyboardSuggestionContext == context else { return }
            let language = UITextChecker.availableLanguages.first { $0.hasPrefix("en") } ?? "en_US"
            let wordRange = NSRange(location: 0, length: context.word.utf16.count)
            let completions = self.checker.completions(forPartialWordRange: wordRange, in: context.word, language: language) ?? []
            let guesses = self.checker.guesses(forWordRange: wordRange, in: context.word, language: language) ?? []
            var seen: Set<String> = [context.word]
            let candidates = (guesses + completions).filter {
                $0.count <= 32 && $0.allSatisfy { $0.isLetter } && seen.insert($0).inserted
            }.prefix(3)
            for candidate in candidates {
                let button = UIButton(type: .system)
                button.setTitle(candidate, for: .normal)
                button.tintColor = .label
                button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
                button.accessibilityLabel = "Replace \(context.word) with \(candidate)"
                button.addAction(UIAction { [weak self] _ in
                    guard let self, self.canSend else { return }
                    self.host?.touchKeyboardAccept(candidate, context: context)
                    self.updateSuggestions()
                }, for: .touchUpInside)
                self.suggestions.addArrangedSubview(button)
            }
        }
    }

    func updatePrediction() {
        guard predictionEnabled, canSend, predictionLanguage != nil,
              let snapshot = host?.touchKeyboardPredictionContext else {
            predictionTask?.cancel(); predictionTask = nil; pendingPrediction = nil
            return
        }
        guard predictionCache[snapshot.prefix] == nil, pendingPrediction != snapshot else { return }
        predictionTask?.cancel()
        pendingPrediction = snapshot
        // Warm between events; a rollover can commit the preceding letter and
        // need its new prefix before this task has had a chance to run.
        predictionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.predictionEnabled, self.canSend,
                  self.host?.touchKeyboardPredictionContext == snapshot else { return }
            _ = self.predictionPrior(for: snapshot)
            self.pendingPrediction = nil
            self.predictionTask = nil
        }
    }

    private func predictionPrior(for snapshot: Model.PredictionSnapshot) -> Model.LetterPrior? {
        guard let language = predictionLanguage else { return nil }
        let checker = checker
        return predictionCache.prior(for: snapshot.prefix) {
            let range = NSRange(location: 0, length: snapshot.prefix.utf16.count)
            let completions = checker.completions(forPartialWordRange: range, in: snapshot.prefix, language: language) ?? []
            let isWord = checker.rangeOfMisspelledWord(in: snapshot.prefix, range: range, startingAt: 0,
                                                      wrap: false, language: language).location == NSNotFound
            return Model.LetterPrior(prefix: snapshot.prefix, completions: completions, isCompleteWord: isWord)
        }
    }
}

#endif
