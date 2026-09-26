#if !os(visionOS) && !targetEnvironment(macCatalyst) && canImport(FluidAudio) && !CHINA_BUILD
import Observation
import UIKit

/// The Dictation page of the terminal keyboard: live transcript, a mic that
/// toggles on tap and talks while held, and Insert / Insert ⏎ for previews.
final class TerminalDictationPaneView: UIView {
    weak var target: DictationTarget?
    /// The Agent shortcuts preset suggests prompt formatting even before detection.
    var agentHint = false
    var onFeedback: (() -> Void)?
    private var style = TerminalTouchKeyboardModel.Style.flat
    private var palette: TerminalTouchKeyboardPalette?

    private let controller = DictationController.shared
    private let store = DictationModelStore.shared
    private let status = UILabel()
    private let optionsButton = UIButton(type: .system)
    private let transcript = UITextView()
    private let placeholder = UILabel()
    private let mic = DictationMicButton()
    private let downloadCard = UIStackView()
    private let downloadLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var downloadButton: TerminalTouchDrawerButton?
    private var leftButtons: [TerminalTouchDrawerButton] = []
    private var rightButtons: [TerminalTouchDrawerButton] = []
    private var buttonSignature = ""
    private var ink: UIColor = .label
    private var pushToTalk = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.adjustsFontForContentSizeCategory = false
        addSubview(status)

        optionsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        optionsButton.showsMenuAsPrimaryAction = true
        optionsButton.accessibilityLabel = String(localized: "Dictation Options")
        addSubview(optionsButton)

        transcript.isEditable = false
        transcript.isSelectable = false
        transcript.backgroundColor = .clear
        transcript.textContainerInset = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        transcript.showsVerticalScrollIndicator = true
        transcript.layer.cornerRadius = 10
        transcript.layer.cornerCurve = .continuous
        transcript.isAccessibilityElement = true
        transcript.accessibilityTraits = [.staticText, .updatesFrequently]
        addSubview(transcript)
        placeholder.numberOfLines = 0
        placeholder.textAlignment = .center
        placeholder.font = .systemFont(ofSize: 14)
        addSubview(placeholder)

        mic.addTarget(self, action: #selector(tapMic), for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdMic(_:)))
        hold.minimumPressDuration = 0.35
        mic.addGestureRecognizer(hold)
        addSubview(mic)

        downloadCard.axis = .vertical
        downloadCard.spacing = 8
        downloadCard.alignment = .fill
        downloadLabel.numberOfLines = 0
        downloadLabel.textAlignment = .center
        downloadLabel.font = .systemFont(ofSize: 13)
        downloadCard.addArrangedSubview(downloadLabel)
        downloadCard.addArrangedSubview(progress)
        addSubview(downloadCard)

        observe()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Keycap-style buttons follow the keyboard style and palette.
    func configure(style: TerminalTouchKeyboardModel.Style, palette: TerminalTouchKeyboardPalette?, ink: UIColor) {
        self.style = style
        self.palette = palette
        self.ink = ink
        buttonSignature = ""
        render()
    }

    private func makeButton(_ title: String, _ symbol: String?, _ action: @escaping () -> Void) -> TerminalTouchDrawerButton {
        let key = TerminalTouchKeyboardModel.Key(title: title, action: .key(title), symbol: symbol, accessibility: title)
        let button = style.makeDrawerButton(key: key, subtitle: nil, toolbar: false, palette: palette)
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in self?.onFeedback?() }, for: .touchDown)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        addSubview(button)
        return button
    }

    func startListening() {
        guard let target, controller.modelReady, !controller.isActive else { return }
        onFeedback?()
        controller.start(target: target, agentHint: agentHint, owner: self)
    }

    /// Leaving the page, hiding the keyboard, or losing the window ends a
    /// session this pane started; any preview stays for later.
    func paneWillHide() {
        controller.stop(ownedBy: self)
    }

    override var isHidden: Bool {
        didSet { if isHidden && !oldValue { paneWillHide() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { paneWillHide() }
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking { [weak self] in
            self?.render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        let model = controller.model
        let ready = controller.modelReady
        let phase = controller.phase
        let mode = controller.commitMode
        let speech = store.state(.speech(model))
        let vad = store.state(.voiceActivity)

        status.textColor = ink.withAlphaComponent(0.7)
        status.text = statusText(phase: phase, model: model, ready: ready)
        optionsButton.tintColor = ink.withAlphaComponent(0.7)
        optionsButton.menu = optionsMenu()

        downloadCard.isHidden = ready
        transcript.isHidden = !ready
        mic.isHidden = !ready
        if !ready { renderDownload(model: model, speech: speech, vad: vad) }

        mic.tintColor = ink
        mic.phase = phase
        mic.level = CGFloat(controller.level)

        let committed = mode == .preview ? controller.previewText : ""
        let partial = controller.partial
        let text = NSMutableAttributedString()
        let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        if !committed.isEmpty {
            text.append(NSAttributedString(string: committed, attributes: [.font: font, .foregroundColor: ink]))
        }
        if !partial.isEmpty {
            let spaced = committed.isEmpty || committed.hasSuffix("\n") ? partial : " " + partial
            text.append(NSAttributedString(string: spaced, attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(0.45)]))
        }
        if transcript.attributedText != text {
            transcript.attributedText = text
            transcript.accessibilityValue = text.string
            let bottom = max(0, transcript.contentSize.height - transcript.bounds.height)
            transcript.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
        transcript.backgroundColor = ink.withAlphaComponent(0.06)
        placeholder.isHidden = !ready || text.length > 0
        placeholder.textColor = ink.withAlphaComponent(0.45)
        placeholder.text = placeholderText(mode: mode, phase: phase)

        renderButtons(mode: mode, ready: ready)
        setNeedsLayout()
    }

    private func renderDownload(model: DictationModel, speech: DictationModelStore.State,
                                vad: DictationModelStore.State) {
        let precision = SettingsStore.shared.get(Settings.Dictation.encoderPrecision)
        downloadLabel.textColor = ink.withAlphaComponent(0.8)
        progress.progressTintColor = ink
        progress.trackTintColor = ink.withAlphaComponent(0.15)
        switch (speech, vad) {
        case (.downloading(let value), _):
            downloadLabel.text = String(localized: "Downloading \(model.displayName)… Audio never leaves this device.")
            progress.isHidden = false
            progress.progress = Float(value)
        case (.failed(let message), _), (_, .failed(let message)):
            downloadLabel.text = String(localized: "Download failed: \(message)")
            progress.isHidden = true
        default:
            downloadLabel.text = String(localized: "On-device dictation uses \(model.displayName) (\(model.downloadMegabytes(precision)) MB). Audio never leaves this device.")
            progress.isHidden = true
        }
        downloadButton?.isHidden = { if case .downloading = speech { return true }; return false }()
    }

    private func renderButtons(mode: DictationCommitMode, ready: Bool) {
        let signature = "\(mode)-\(ready)"
        guard signature != buttonSignature else {
            updateButtonStates(mode: mode)
            return
        }
        buttonSignature = signature
        (leftButtons + rightButtons).forEach { $0.cancelRepeat(); $0.removeFromSuperview() }
        downloadButton?.removeFromSuperview()
        downloadButton = nil
        leftButtons = []
        rightButtons = []
        guard ready else {
            let button = makeButton(String(localized: "Download"), "arrow.down.circle") { [weak self] in
                guard let self else { return }
                self.store.downloadForListening(self.controller.model)
            }
            downloadCard.addArrangedSubview(button)
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
            downloadButton = button
            return
        }
        leftButtons = [
            makeButton(String(localized: "Undo"), "arrow.uturn.backward") { [weak self] in self?.controller.undo() },
        ]
        if mode == .preview {
            leftButtons.append(makeButton(String(localized: "Clear"), "xmark") { [weak self] in self?.controller.clear() })
            rightButtons = [
                makeButton(String(localized: "Insert"), "text.insert") { [weak self] in
                    self?.controller.insert(submit: false, into: self?.target)
                },
                makeButton(String(localized: "Run"), "return") { [weak self] in
                    self?.controller.insert(submit: true, into: self?.target)
                },
            ]
        } else {
            rightButtons = [
                makeButton(String(localized: "Return"), "return") { [weak self] in self?.controller.submit(to: self?.target) },
            ]
        }
        updateButtonStates(mode: mode)
    }

    private func updateButtonStates(mode: DictationCommitMode) {
        let hasPreview = !controller.phrases.isEmpty || !controller.partial.isEmpty
        leftButtons.first?.isEnabled = controller.canUndo
        leftButtons.first?.alpha = controller.canUndo ? 1 : 0.4
        if mode == .preview {
            (leftButtons.dropFirst() + rightButtons).forEach {
                $0.isEnabled = hasPreview
                $0.alpha = hasPreview ? 1 : 0.4
            }
        }
    }

    private func statusText(phase: DictationController.Phase, model: DictationModel, ready: Bool) -> String {
        switch phase {
        case .preparing: return String(localized: "Loading \(model.displayName)…")
        case .listening:
            let style = controller.style.displayName
            if let agent = controller.agentName { return String(localized: "Listening · \(style) for \(agent)") }
            return String(localized: "Listening · \(style)")
        case .finishing: return String(localized: "Finishing…")
        case .failed(let message): return message
        case .idle:
            return ready
                ? String(localized: "\(model.displayName) · On device · \(controller.commitMode.displayName)")
                : String(localized: "Dictation")
        }
    }

    private func placeholderText(mode: DictationCommitMode, phase: DictationController.Phase) -> String {
        if phase == .listening { return String(localized: "Speak now") }
        switch mode {
        case .preview: return String(localized: "Tap the mic and speak. Nothing is sent until you tap Insert or Run.")
        case .live: return String(localized: "Tap the mic and speak. Each phrase is typed when you pause.")
        case .handsFree: return String(localized: "Tap the mic and speak. Each phrase is typed and run when you pause.")
        }
    }

    private func optionsMenu() -> UIMenu {
        let settings = SettingsStore.shared
        let formatting = settings.get(Settings.Dictation.formatting)
        let mode = settings.get(Settings.Dictation.commitMode)
        let formats = DictationFormatting.allCases.map { value in
            UIAction(title: value.displayName, state: value == formatting ? .on : .off) { _ in
                settings.set(Settings.Dictation.formatting, value)
            }
        }
        let modes = DictationCommitMode.allCases.map { value in
            UIAction(title: value.displayName, state: value == mode ? .on : .off) { _ in
                settings.set(Settings.Dictation.commitMode, value)
            }
        }
        return UIMenu(children: [
            UIMenu(title: String(localized: "Formatting"), options: .displayInline, children: formats),
            UIMenu(title: String(localized: "Insert Text"), options: .displayInline, children: modes),
        ])
    }

    // MARK: - Mic

    @objc private func tapMic() {
        guard !pushToTalk, let target else { return }
        onFeedback?()
        if case .failed = controller.phase { controller.dismissError() }
        controller.toggle(target: target, agentHint: agentHint, owner: self)
    }

    @objc private func holdMic(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !controller.isActive else { return }
            pushToTalk = true
            startListening()
        case .ended, .cancelled, .failed:
            guard pushToTalk else { return }
            pushToTalk = false
            onFeedback?()
            controller.stop(ownedBy: self)
        default:
            break
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        status.frame = CGRect(x: 6, y: 2, width: width - 44, height: 20)
        optionsButton.frame = CGRect(x: width - 36, y: 0, width: 36, height: 24)

        let rowHeight = min(52, max(36, height * 0.28))
        let micSize = min(rowHeight + 10, height * 0.4)
        let rowY = height - rowHeight - 2
        mic.frame = CGRect(x: (width - micSize) / 2, y: rowY + (rowHeight - micSize) / 2, width: micSize, height: micSize)
        let side = (width - micSize - 24) / 2
        layoutRow(leftButtons, in: CGRect(x: 0, y: rowY, width: side, height: rowHeight))
        layoutRow(rightButtons, in: CGRect(x: width - side, y: rowY, width: side, height: rowHeight))

        let top: CGFloat = 24
        let transcriptHeight = max(0, min(rowY, mic.frame.minY) - top - 6)
        transcript.frame = CGRect(x: 2, y: top, width: width - 4, height: transcriptHeight)
        placeholder.frame = transcript.frame.insetBy(dx: 12, dy: 4)
        downloadCard.frame = CGRect(x: 12, y: top, width: width - 24, height: height - top - 4)
    }

    private func layoutRow(_ buttons: [TerminalTouchDrawerButton], in rect: CGRect) {
        guard !buttons.isEmpty else { return }
        let spacing: CGFloat = 4
        let buttonWidth = min(96, (rect.width - spacing * CGFloat(buttons.count - 1)) / CGFloat(buttons.count))
        let total = buttonWidth * CGFloat(buttons.count) + spacing * CGFloat(buttons.count - 1)
        // Hug the mic so both hands reach the primary actions.
        var x = rect.minX == 0 ? rect.maxX - total : rect.minX
        for button in buttons {
            button.frame = CGRect(x: x, y: rect.minY + 2, width: buttonWidth, height: rect.height - 4)
            x += buttonWidth + spacing
        }
    }
}

/// A round record control whose ring follows the input level.
private final class DictationMicButton: UIControl {
    var phase: DictationController.Phase = .idle { didSet { if oldValue != phase { update() } } }
    var level: CGFloat = 0 { didSet { updateLevel() } }

    private let disc = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(ring)
        layer.addSublayer(disc)
        ring.fillColor = nil
        ring.lineWidth = 3
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        spinner.hidesWhenStopped = true
        spinner.isUserInteractionEnabled = false
        addSubview(spinner)
        isAccessibilityElement = true
        accessibilityTraits = .button
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func tintColorDidChange() { super.tintColorDidChange(); update() }
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.7 : 1 } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 5
        disc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        ring.frame = bounds
        disc.frame = bounds
        icon.frame = bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        update()
    }

    private func update() {
        let listening = phase == .listening
        let busy = phase == .preparing || phase == .finishing
        disc.fillColor = (listening ? UIColor.systemRed : tintColor.withAlphaComponent(0.14)).cgColor
        ring.strokeColor = (listening ? UIColor.systemRed : tintColor.withAlphaComponent(0.3)).cgColor
        let config = UIImage.SymbolConfiguration(pointSize: max(18, bounds.height * 0.34), weight: .semibold)
        icon.image = UIImage(systemName: listening ? "stop.fill" : "mic.fill", withConfiguration: config)
        icon.tintColor = listening ? .white : tintColor
        icon.isHidden = busy
        spinner.color = tintColor
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        accessibilityLabel = listening ? String(localized: "Stop Dictation") : String(localized: "Start Dictation")
        accessibilityHint = String(localized: "Hold to talk, release to stop.")
        updateLevel()
    }

    private func updateLevel() {
        let scale = phase == .listening ? 1 + min(1, level) * 0.12 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(UIAccessibility.isReduceMotionEnabled)
        CATransaction.setAnimationDuration(0.08)
        ring.transform = CATransform3DMakeScale(scale, scale, 1)
        ring.opacity = phase == .listening ? Float(0.35 + min(1, level) * 0.65) : 1
        CATransaction.commit()
    }
}
#endif
