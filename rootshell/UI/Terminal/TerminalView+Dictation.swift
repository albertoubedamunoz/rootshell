#if canImport(FluidAudio) && !CHINA_BUILD
import UIKit

/// Where dictated text goes. The terminal pane that had focus when listening began.
@MainActor
protocol DictationTarget: AnyObject {
    var dictationCanReceive: Bool { get }
    /// Name of a coding agent running in the pane, for automatic prompt formatting.
    var dictationAgentName: String? { get }
    /// Recent visible text, used to boost identifiers the speaker is likely to say.
    var dictationScreenText: String? { get }
    /// Changes whenever any input reaches the terminal, dictated or typed.
    var dictationInputGeneration: UInt64 { get }
    func dictationInsert(_ text: String)
    func dictationSubmit()
    func dictationSend(_ key: DictationKey)
    func dictationDeleteBackward(_ count: Int)
}

extension Ghostty.TerminalView: DictationTarget {
    var dictationCanReceive: Bool {
        window != nil && surface != nil && !aiAgentOverlayActive
    }

    var dictationInputGeneration: UInt64 { userInputGeneration }

    var dictationAgentName: String? {
        AgentAttentionCenter.shared.detectedAgentName(for: self)
    }

    var dictationScreenText: String? {
        guard let surface, let size = surfaceSize, size.rows > 1, size.columns > 1 else { return nil }
        var busy = false
        return Ghostty.Surface.tryReadBottomRows(
            Int(size.rows), gridRows: Int(size.rows), cols: Int(size.columns), surface: surface, busy: &busy)
    }

    func dictationInsert(_ text: String) {
        guard dictationCanReceive, !text.isEmpty else { return }
        if text.contains("\n") {
            // Bracketed paste keeps line breaks inside the prompt instead of submitting it.
            _ = insertPastedText(text, recordHistory: false)
        } else {
            sendComposedText(text)
        }
    }

    func dictationSubmit() {
        dictationPress(.keyboardReturnOrEnter, fallback: "\r")
    }

    func dictationSend(_ key: DictationKey) {
        switch key {
        case .escape: dictationPress(.keyboardEscape, fallback: "\u{1b}")
        case .tab: dictationPress(.keyboardTab, fallback: "\t")
        case .up: dictationPress(.keyboardUpArrow, fallback: "\u{1b}[A")
        case .down: dictationPress(.keyboardDownArrow, fallback: "\u{1b}[B")
        case .backspace: dictationPress(.keyboardDeleteOrBackspace, fallback: "\u{7f}")
        case .control(let letter):
            guard let ascii = letter.lowercased().first?.asciiValue, (97...122).contains(ascii) else { return }
            let usage = UIKeyboardHIDUsage(rawValue: UIKeyboardHIDUsage.keyboardA.rawValue + Int(ascii - 97))
            if let usage, sendKeyViaGhostty(keyCode: usage, action: .press, modifiers: .control) {
                _ = sendKeyViaGhostty(keyCode: usage, action: .release, modifiers: .control)
            } else {
                keyPressed(String(letter), modifiers: .control)
            }
        }
    }

    func dictationDeleteBackward(_ count: Int) {
        for _ in 0..<min(count, 2_000) { dictationSend(.backspace) }
    }

    private func dictationPress(_ usage: UIKeyboardHIDUsage, fallback: String) {
        guard dictationCanReceive else { return }
        NotificationCenter.default.post(name: .ghosttyDidReceiveInput, object: self)
        if sendKeyViaGhostty(keyCode: usage, action: .press, modifiers: []) {
            _ = sendKeyViaGhostty(keyCode: usage, action: .release, modifiers: [])
        } else {
            keyPressed(fallback, modifiers: [])
        }
    }
}
#endif
