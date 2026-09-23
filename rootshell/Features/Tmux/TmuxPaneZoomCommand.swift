import Foundation

/// tmux commands for committing a numbered pane selection.
enum TmuxPaneZoomCommand {
    enum Failure: Error { case invalidTarget, invalidReply, layoutChanged }

    /// One native command preserves the active pane and existing zoom. Qualify
    /// both targets so neither can be followed into a different window.
    static func swapCommand(windowID: Int, sourcePaneID: Int, targetPaneID: Int) throws -> String {
        guard windowID >= 0, sourcePaneID >= 0, targetPaneID >= 0,
              sourcePaneID != targetPaneID else { throw Failure.invalidTarget }
        return "swap-pane -d -Z -s @\(windowID).%\(sourcePaneID) -t @\(windowID).%\(targetPaneID)"
    }

    /// Preserve existing zoom when switching, then query the server before
    /// deciding whether to zoom. Each send has exactly one control-mode reply:
    /// if-shell / compound commands would shift the gateway's reply FIFO.
    /// The caller revalidates the tab and topology before every send.
    @MainActor
    static func zoom(windowID: Int, paneID: Int,
                     send: (String) async throws -> String) async throws {
        guard windowID >= 0, paneID >= 0 else { throw Failure.invalidTarget }
        let target = "@\(windowID).%\(paneID)"
        _ = try await send("select-pane -Z -t \(target)")
        let zoomed = try await send("display-message -p -t \(target) '#{window_zoomed_flag}'")
        switch zoomed.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0": _ = try await send("resize-pane -Z -t \(target)")
        case "1": break
        default: throw Failure.invalidReply
        }
    }
}
