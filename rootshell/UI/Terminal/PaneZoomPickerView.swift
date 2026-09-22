import UIKit

/// Takes keyboard focus while choosing. It never forwards input to a terminal.
/// The host supplies full-tree rectangles even when the server is currently zoomed.
final class PaneZoomPickerView: UIView, UIKeyInput {
    private var selection: PaneZoomSelection<UUID>
    private let buttons: [UIButton]
    private let shortcuts: [KeyTrigger]
    private let instruction = UILabel()
    private var heldKeys = Set<UIKeyboardHIDUsage>()
    private var pendingResult: PaneZoomSelection<UUID>.Result = .pending
    private var lastInput: (text: String, modified: Bool, time: TimeInterval)?
    private var finishScheduled = false
    var onFinish: ((UUID?) -> Void)?

    init(selection: PaneZoomSelection<UUID>, titles: [String], preview: Bool, shortcuts: [KeyTrigger]) {
        self.selection = selection
        self.shortcuts = shortcuts
        buttons = selection.labels.enumerated().map { index, label in
            let button = UIButton(type: .system)
            button.tag = index
            var config = UIButton.Configuration.filled()
            config.title = label
            config.subtitle = titles[index]
            config.baseBackgroundColor = .secondarySystemBackground.withAlphaComponent(preview ? 0.95 : 0.6)
            config.baseForegroundColor = .label
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .monospacedDigitSystemFont(ofSize: 32, weight: .bold)
                return attributes
            }
            button.configuration = config
            button.accessibilityLabel = String(localized: "Zoom pane \(label): \(titles[index])")
            return button
        }
        super.init(frame: .zero)
        backgroundColor = preview ? .systemBackground : .black.withAlphaComponent(0.25)
        accessibilityViewIsModal = true
        for button in buttons {
            button.addTarget(self, action: #selector(choose(_:)), for: .touchUpInside)
            addSubview(button)
        }
        instruction.text = String(localized: "Type a pane number to zoom · Any other key cancels")
        instruction.font = .preferredFont(forTextStyle: .caption1)
        instruction.textColor = .label
        instruction.backgroundColor = .systemBackground
        instruction.textAlignment = .center
        instruction.numberOfLines = 0
        addSubview(instruction)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            let callback = onFinish
            onFinish = nil
            callback?(nil)
        }
        return resigned
    }
    // Keep UIKit's responder chain intact so becomeFirstResponder can find
    // the window. Input is contained by our key commands and presses methods;
    // severing `next` makes UIKit refuse keyboard focus on iPad.
    override var inputView: UIView? { UIView(frame: .zero) }
    var hasText: Bool { false }

    func arrange(in frames: [CGRect]) {
        for (button, frame) in zip(buttons, frames) {
            button.frame = frame.insetBy(dx: 6, dy: 6)
        }
        let height = instruction.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height + 12
        instruction.frame = CGRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height)
    }

    /// Shadow configured app shortcuts (including close/split) while modal.
    /// Raw keys are consumed by pressesBegan; OS-reserved shortcuts still belong
    /// to the OS and the host cancels on scene deactivation.
    override var keyCommands: [UIKeyCommand]? {
        var seen = Set<KeyTrigger>()
        var commands = shortcuts.compactMap { trigger -> UIKeyCommand? in
            guard seen.insert(trigger).inserted else { return nil }
            let command = UIKeyCommand(input: trigger.uiKeyInput,
                                       modifierFlags: trigger.uiModifierFlags,
                                       action: #selector(consumeCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        for input in [UIKeyCommand.inputEscape, "\r", "\t"] {
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(consumeCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func consumeCommand(_ command: UIKeyCommand) {
        consume(command.input ?? "", modified: !command.modifierFlags.isEmpty)
    }

    // Catalyst routes its reserved Command-Period through the menu rail only.
    @objc func menuSystemCancel(_ sender: Any?) { cancel() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            // UIKit can replay modifier state to a newly focused input view.
            // Only a key chord's actual input should select or cancel.
            switch key.keyCode {
            case .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
                 .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock:
                continue
            default: break
            }
            // Repeats of a held digit must not become a second digit in a label.
            guard heldKeys.insert(key.keyCode).inserted else { continue }
            let modifiers = key.modifierFlags.intersection([.command, .control, .alternate, .shift])
            consume(key.characters, modified: !modifiers.isEmpty)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses { if let key = press.key { heldKeys.remove(key.keyCode) } }
        finishIfReady()
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Focus handoff may cancel the opening shortcut's old press sequence.
        // That sequence never began in this picker and must not dismiss it.
        let ownedPressWasCancelled = presses.contains { press in
            press.key.map { heldKeys.contains($0.keyCode) } ?? false
        }
        for press in presses { if let key = press.key { heldKeys.remove(key.keyCode) } }
        if ownedPressWasCancelled { cancel() }
        else { finishIfReady() }
    }

    func insertText(_ text: String) { consume(text, modified: false) }
    func deleteBackward() { cancel() }
    override func paste(_ sender: Any?) { cancel() }
    override func accessibilityPerformEscape() -> Bool { cancel(); return true }

    private func consume(_ text: String, modified: Bool) {
        guard pendingResult == .pending else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // UIKit can deliver one physical key via both keyCommands and presses.
        if let lastInput, lastInput.text == text, lastInput.modified == modified,
           now - lastInput.time < 0.05 { return }
        lastInput = (text, modified, now)
        pendingResult = selection.consume(text, modified: modified)
        for (index, button) in buttons.enumerated() {
            button.alpha = selection.labels[index].hasPrefix(selection.prefix) ? 1 : 0.3
        }
        finishIfReady()
    }

    @objc private func choose(_ button: UIButton) {
        pendingResult = .selected(selection.paneIDs[button.tag])
        finishIfReady()
    }

    private func cancel() {
        pendingResult = .cancelled
        finishIfReady()
    }

    private func finishIfReady() {
        // Keep focus until key-up so the selecting/canceling key's repeats and
        // release cannot spill into the newly focused terminal.
        guard heldKeys.isEmpty, pendingResult != .pending, !finishScheduled else { return }
        finishScheduled = true
        // Let a pressesBegan delivery accompanying a UIKeyCommand register its
        // held key before deciding whether it is safe to return terminal focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishScheduled = false
            guard self.heldKeys.isEmpty else { return }
            let callback = self.onFinish
            self.onFinish = nil
            if case let .selected(id) = self.pendingResult { callback?(id) }
            else { callback?(nil) }
        }
    }
}
