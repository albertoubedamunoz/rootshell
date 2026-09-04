import UIKit
import Combine

extension Ghostty.TerminalView {
    func setupWritingAssistance() {
        writingAssistanceMode = SettingsStore.shared.value(Settings.Keyboard.writingAssistance)
        for name in [Notification.Name.settingsDidChange,
                     UITextInputMode.currentInputModeDidChangeNotification,
                     UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidHideNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == .settingsDidChange {
                        let mode = SettingsStore.shared.value(Settings.Keyboard.writingAssistance)
                        if mode != self.writingAssistanceMode {
                            self.writingAssistanceMode = mode
                            self.invalidateWritingAssistance()
                        }
                    } else if name == UIResponder.keyboardDidHideNotification,
                              !KeyboardTracker.shared.isSoftwareKeyboardVisible {
                        self.invalidateWritingAssistance()
                        self.writingAssistanceSource = nil
                    }
                    // Repeated show notifications (including trait reloads)
                    // are not input-source changes. refresh compares identity.
                    self.refreshWritingAssistanceTraits()
                }
            }
            writingAssistanceObservers.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
        }
        keyboardAccessoryController.onActiveKeyboardModifiersChanged = { [weak self] _ in
            self?.invalidateWritingAssistance()
        }
        refreshWritingAssistanceTraits()
    }

    /// UIKit exposes expected input sources, not authenticated keyboard identity.
    /// Accept only known system input-mode classes; unknown subclasses fail closed.
    /// Do not inspect private properties or assume any non-extension is Apple.
    var eligibleWritingAssistanceSource: String? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard KeyboardTracker.shared.isSoftwareKeyboardVisible,
              let mode = textInputMode, let language = mode.primaryLanguage,
              language != "dictation", language != "emoji",
              markedTextString == nil, !koreanCompositionModel.hasActiveComposition,
              !isLikelySystemDictationActive,
              activeKeyboardModifiers.isEmpty, virtualModTapModifier == nil,
              heldHardwareModifiers == .none else { return nil }
        if let binding = tmuxPaneBinding {
            guard let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: binding.parentUUID),
                  gateway.session?.isRunning == true else { return nil }
        } else if session?.isRunning != true {
            return nil
        }
        let modeClass = NSStringFromClass(type(of: mode))
        guard modeClass == "UIKeyboardInputMode" || modeClass == "UITextInputMode" else { return nil }
        if let context = UITextInputContext.current(),
           context.isHardwareKeyboardInputExpected || context.isDictationInputExpected || context.isPencilInputExpected {
            return nil
        }
        if let lastHardwareTextInputTime,
           ProcessInfo.processInfo.systemUptime - lastHardwareTextInputTime < 0.25 { return nil }
        return modeClass + ":" + language
        #endif
    }

    @discardableResult
    func refreshWritingAssistanceTraits() -> Bool {
        let source = eligibleWritingAssistanceSource
        if writingAssistanceSource != source {
            invalidateWritingAssistance()
            writingAssistanceSource = source
        }
        let mode = source == nil ? TerminalWritingAssistanceMode.off : writingAssistanceMode
        let spelling: UITextSpellCheckingType = mode == .off ? .no : .yes
        let correction: UITextAutocorrectionType = mode == .autocorrect ? .yes : .no
        if spellCheckingType != spelling || autocorrectionType != correction {
            spellCheckingType = spelling
            autocorrectionType = correction
            writingAssistanceNeedsTraitReload = true
        }
        requestWritingAssistanceTraitReload()
        return mode != .off && surface != nil && isFirstResponder
    }

    private func requestWritingAssistanceTraitReload() {
        guard writingAssistanceNeedsTraitReload, !writingAssistanceTraitReloadPending,
              markedTextString == nil, !koreanCompositionModel.hasActiveComposition else { return }
        writingAssistanceTraitReloadPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.writingAssistanceTraitReloadPending = false
            guard self.markedTextString == nil, !self.koreanCompositionModel.hasActiveComposition else { return }
            self.writingAssistanceNeedsTraitReload = false
            // Never reload inside an insert/replace/marked-text callback, and
            // never park or replace the first responder to change traits.
            if self.isFirstResponder { self.reloadInputViews() }
        }
    }

    func requestWritingAssistanceRequery() {
        guard !writingAssistanceRequeryPending else { return }
        writingAssistanceRequeryPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.writingAssistanceRequeryPending = false
            self.notifyInputDelegateOfExternalChange { }
        }
    }

    func invalidateWritingAssistance(resetDocument: Bool = false) {
        correctionContext.apply(resetDocument ? .reset : .invalidate)
        if resetDocument {
            writingAssistanceSelection = nil
            lastDictationActivityAt = nil
            pendingDictationPlaceholderTokens.removeAll()
        }
        requestWritingAssistanceRequery()
    }

    func mutateInputDocument(_ mutation: TerminalCorrectionContext.Mutation) {
        let generation = correctionContext.generation
        correctionContext.apply(mutation)
        if generation != correctionContext.generation { requestWritingAssistanceRequery() }
    }

    /// Corrections target the application's logical input, not its painted
    /// screen. Redraws and terminal status reports must not revoke that input.
    /// User navigation and session/source changes still revoke the local suffix.
    func applyWritingAssistanceReplacement(_ range: NSRange, text: String, generation: UInt64) {
        guard refreshWritingAssistanceTraits(),
              let replacement = correctionContext.replacement(in: range, with: text, generation: generation) else {
            invalidateWritingAssistance()
            return
        }
        // Commit exactly once at input convergence. Keep the corrected suffix
        // eligible for subsequent corrections and ordinary deletion.
        sendUserInput(replacement.payload, documentMutation: .correction(replacement))
        requestWritingAssistanceRequery()
    }
}
