//
//  SidebarSearchField.swift
//  rootshell
//
//  The vertical tab sidebar's filter field, backed by a real UITextField so
//  keyboard focus and key handling are DETERMINISTIC on both iPad and Mac
//  Catalyst — no timers, no retries, no SwiftUI @FocusState.
//
//  Why not a SwiftUI TextField + @FocusState? Driving @FocusState
//  programmatically to grab first responder is timing-dependent: on iPad it
//  needed a ~300ms delayed Task to land, and on Mac Catalyst it does not
//  reliably install first responder for the panel's embedded hosting
//  controller at all (the keyboard reads as "lost" — typing beeps). Owning the
//  UITextField lets us:
//    * become first responder on real UIKit lifecycle events
//      (`didMoveToWindow` + the SwiftUI update cycle keyed on a request
//      counter), gated only on `window != nil` — never on a clock; and
//    * handle Up/Down/Escape via `pressesBegan` and Return via the delegate,
//      instead of SwiftUI `.onKeyPress` (which only fires while a SwiftUI view
//      owns focus — the fragile part this replaces).
//

import SwiftUI
import UIKit

/// A single-line filter field for the tab sidebar. Renders only the editable
/// field; the magnifying glass / clear-button chrome stays in SwiftUI.
struct SidebarSearchField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat

    /// Whether the panel is on screen. The overlay keeps this view MOUNTED
    /// off-screen after dismissal, so `window != nil` stays true and is NOT a
    /// sufficient gate — a focus request bumped just before a rapid close would
    /// otherwise re-grab the off-screen field and steal the keyboard back from
    /// the terminal. Checked immediately before `becomeFirstResponder()`.
    var canFocus: Bool

    /// Monotonic focus request. Bump it (from a real event — panel open, row
    /// tap, sheet dismiss) to ask the field to take first responder. The grab
    /// is applied on the next `updateUIView` or `didMoveToWindow` that has a
    /// window AND `canFocus` — deterministically, with no timer. A value of 0
    /// means "do not auto-focus" (e.g. no hardware keyboard, so we never pop the
    /// software keyboard).
    var focusRequestID: Int

    /// Whether Up/Down drive list navigation. Pass false when the list is not
    /// keyboard-navigable (e.g. the clipboard HUD outside keyboard mode) so the
    /// arrows keep their default text-field caret behavior.
    var capturesNavigationKeys: Bool = true

    var onMoveUpBegan: () -> Void
    var onMoveUpEnded: () -> Void
    var onMoveDownBegan: () -> Void
    var onMoveDownEnded: () -> Void
    var onEscape: () -> Void
    var onSubmit: () -> Void

    /// Reports the field's first-responder transitions (begin/end editing) so
    /// the sidebar can show the keyboard-cursor highlight ONLY while the sidebar
    /// actually owns the keyboard. The closure is expected to defer its `@State`
    /// write off the current runloop (these callbacks can fire synchronously
    /// from `becomeFirstResponder()` inside `updateUIView`).
    var onFocusChange: (Bool) -> Void

    // Optional command chords, declared as first-responder UIKeyCommands so
    // they win over both ancestor commands and the field's own text-editing
    // behavior. Each command is only registered while its handler is non-nil,
    // so existing call sites are unaffected. Modifier+printable chords must be
    // keyCommands (not `pressesBegan`): on Mac Catalyst those key events never
    // reach `pressesBegan`.
    var onModifiedSubmit: (() -> Void)? = nil   // Cmd+Return
    var onQuickSelect: ((Int) -> Void)? = nil   // Ctrl+1..9 (1-based)
    var onTogglePin: (() -> Void)? = nil        // Ctrl+P
    var onDeleteEntry: (() -> Void)? = nil      // Ctrl+Delete

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> SidebarSearchTextField {
        let field = SidebarSearchTextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.text = text
        // Hug vertically inside the SwiftUI HStack rather than stretching, but
        // stretch horizontally to fill the row (the SwiftUI side asks for
        // maxWidth .infinity).
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        // Re-anchor first responder the instant the field is attached to a
        // window, if a focus has been requested while it was off-window.
        field.onWindowAttached = { [weak field] in
            guard let field else { return }
            context.coordinator.applyFocusIfNeeded(field)
        }
        applyHandlers(to: field)
        return field
    }

    func updateUIView(_ field: SidebarSearchTextField, context: Context) {
        context.coordinator.parent = self
        applyHandlers(to: field)
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
        }
        let font = UIFont.systemFont(ofSize: fontSize)
        if field.font != font {
            field.font = font
        }
        context.coordinator.applyFocusIfNeeded(field)
    }

    private func applyHandlers(to field: SidebarSearchTextField) {
        field.capturesNavigationKeys = capturesNavigationKeys
        field.handlers = SidebarSearchTextField.Handlers(
            onMoveUpBegan: onMoveUpBegan,
            onMoveUpEnded: onMoveUpEnded,
            onMoveDownBegan: onMoveDownBegan,
            onMoveDownEnded: onMoveDownEnded,
            onEscape: onEscape,
            onModifiedSubmit: onModifiedSubmit,
            onQuickSelect: onQuickSelect,
            onTogglePin: onTogglePin,
            onDeleteEntry: onDeleteEntry
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SidebarSearchField
        /// The last focusRequestID we successfully acted on, so a focus is
        /// applied exactly once per bump (idempotent across repeated
        /// `updateUIView`/`didMoveToWindow` calls).
        private var lastAppliedFocusRequestID = 0

        init(_ parent: SidebarSearchField) {
            self.parent = parent
        }

        func applyFocusIfNeeded(_ field: SidebarSearchTextField) {
            let request = parent.focusRequestID
            guard request > 0, request != lastAppliedFocusRequestID else { return }
            // Panel dismissed (or dismissing): the hosting view stays mounted
            // off-screen, so `window != nil` is not enough. Refuse to claim
            // first responder back from the terminal once the panel is hidden.
            // Not recorded as applied, so a later open (which re-presents with a
            // fresh subtree anyway) is unaffected.
            guard parent.canFocus else { return }
            // Not yet in a window: defer to `didMoveToWindow`, which calls back
            // here. We do NOT record the request as applied, so the retry is
            // event-driven, not a poll.
            guard field.window != nil else { return }
            if field.isFirstResponder {
                lastAppliedFocusRequestID = request
                return
            }
            if field.becomeFirstResponder() || field.isFirstResponder {
                lastAppliedFocusRequestID = request
            }
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        // First-responder transitions. `…DidBeginEditing` fires for user taps
        // AND the programmatic `becomeFirstResponder()` in `applyFocusIfNeeded`;
        // `…DidEndEditing` fires when the terminal takes the keyboard back (the
        // docked case). The SwiftUI side defers its state write off this runloop.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChange(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChange(false)
        }
    }
}

/// UITextField that routes list-navigation keys (Up/Down/Escape) to closures
/// while letting everything else — typing, Return — behave normally.
final class SidebarSearchTextField: UITextField {
    struct Handlers {
        var onMoveUpBegan: () -> Void
        var onMoveUpEnded: () -> Void
        var onMoveDownBegan: () -> Void
        var onMoveDownEnded: () -> Void
        var onEscape: () -> Void
        var onModifiedSubmit: (() -> Void)?
        var onQuickSelect: ((Int) -> Void)?
        var onTogglePin: (() -> Void)?
        var onDeleteEntry: (() -> Void)?
    }

    var handlers: Handlers?
    var onWindowAttached: (() -> Void)?
    var capturesNavigationKeys = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            onWindowAttached?()
        }
    }

    // Escape is a UIKeyCommand, not a `pressesBegan` case, on purpose: the
    // panel installs its own `.keyboardShortcut(.escape)` (dismiss) on an
    // ANCESTOR, and UIKeyCommands resolve up the responder chain BEFORE
    // `pressesBegan`. Declaring it here — on the first responder — makes the
    // field's two-stage escape (clear filter, then dismiss) win that
    // precedence deterministically instead of being shadowed by the ancestor.
    override var keyCommands: [UIKeyCommand]? {
        guard let handlers else { return nil }
        // IME composition (marked text) owns every key: Return confirms the
        // composition, arrows/digits drive the candidate UI, and Escape
        // cancels it. Claiming any of them here would garble CJK input; once
        // the composition ends the commands come back (UIKit re-queries
        // keyCommands per key event).
        guard markedTextRange == nil else { return nil }
        var commands = [
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(handleEscapeCommand)
            )
        ]
        if handlers.onModifiedSubmit != nil {
            commands.append(prioritized(UIKeyCommand(
                input: "\r",
                modifierFlags: .command,
                action: #selector(handleModifiedSubmitCommand)
            )))
        }
        if handlers.onQuickSelect != nil {
            for digit in 1...9 {
                commands.append(prioritized(UIKeyCommand(
                    input: "\(digit)",
                    modifierFlags: .control,
                    action: #selector(handleQuickSelectCommand(_:))
                )))
            }
        }
        if handlers.onTogglePin != nil {
            commands.append(prioritized(UIKeyCommand(
                input: "p",
                modifierFlags: .control,
                action: #selector(handleTogglePinCommand)
            )))
        }
        if handlers.onDeleteEntry != nil {
            commands.append(prioritized(UIKeyCommand(
                input: UIKeyCommand.inputDelete,
                modifierFlags: .control,
                action: #selector(handleDeleteEntryCommand)
            )))
        }
        return commands
    }

    /// Chords must beat system text-editing behavior (Ctrl+P caret-up, etc.).
    private func prioritized(_ command: UIKeyCommand) -> UIKeyCommand {
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func handleEscapeCommand() {
        handlers?.onEscape()
    }

    @objc private func handleModifiedSubmitCommand() {
        handlers?.onModifiedSubmit?()
    }

    @objc private func handleQuickSelectCommand(_ command: UIKeyCommand) {
        guard let digit = command.input.flatMap({ Int($0) }) else { return }
        handlers?.onQuickSelect?(digit)
    }

    @objc private func handleTogglePinCommand() {
        handlers?.onTogglePin?()
    }

    @objc private func handleDeleteEntryCommand() {
        handlers?.onDeleteEntry?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyDown($0) }
        if !unhandled.isEmpty {
            super.pressesBegan(Set(unhandled), with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !handleKeyUp($0) }
        if !unhandled.isEmpty {
            super.pressesEnded(Set(unhandled), with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled press must still release any repeat we started on down.
        let unhandled = presses.filter { !handleKeyUp($0) }
        if !unhandled.isEmpty {
            super.pressesCancelled(Set(unhandled), with: event)
        }
    }

    /// Only plain (unmodified) arrows/escape drive navigation; modified
    /// combinations fall through to the system.
    private func isPlain(_ key: UIKey) -> Bool {
        key.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty
    }

    private func handleKeyDown(_ press: UIPress) -> Bool {
        guard capturesNavigationKeys else { return false }
        // While composing (IME marked text), arrows navigate the candidate UI.
        guard markedTextRange == nil else { return false }
        guard let key = press.key, isPlain(key), let handlers else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            handlers.onMoveUpBegan()
            return true
        case .keyboardDownArrow:
            handlers.onMoveDownBegan()
            return true
        default:
            return false
        }
    }

    private func handleKeyUp(_ press: UIPress) -> Bool {
        guard let key = press.key, let handlers else { return false }
        switch key.keyCode {
        case .keyboardUpArrow:
            handlers.onMoveUpEnded()
            return true
        case .keyboardDownArrow:
            handlers.onMoveDownEnded()
            return true
        default:
            return false
        }
    }
}
