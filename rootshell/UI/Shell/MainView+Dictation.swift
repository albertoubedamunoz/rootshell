#if canImport(FluidAudio) && !CHINA_BUILD
import SwiftUI

// MARK: - Dictation HUD

extension MainView {
    var dictationTarget: DictationTarget? {
        guard terminals.indices.contains(selectedTabIndex) else { return nil }
        return terminals[selectedTabIndex].focusedTerminal
    }

    /// First press opens the HUD and starts listening; later presses stop or
    /// restart listening. The HUD closes from its own button or Escape.
    func toggleDictationHUD(from terminal: Ghostty.TerminalView?) {
        let controller = DictationController.shared
        let terminal = terminal ?? (terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].focusedTerminal : nil)
        let target: DictationTarget? = terminal
        if showDictationHUD, controller.isActive {
            controller.stop()
            return
        }
        // Keybinds arrive here directly; prefer the keyboard's page when it is showing.
        if !showDictationHUD, terminal?.keyboardAccessoryController?.openTouchKeyboardDictation() == true { return }
        showDictationHUD = true
        guard let target, controller.modelReady, !controller.isActive else { return }
        controller.dismissError()
        controller.start(target: target, owner: DictationController.hudOwner)
    }
}
#endif
