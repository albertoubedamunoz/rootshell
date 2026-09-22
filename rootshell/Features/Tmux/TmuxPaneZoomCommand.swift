import Foundation

/// tmux commands for committing a numbered pane selection.
enum TmuxPaneZoomCommand {
    enum Failure: Error { case invalidTarget, invalidReply, layoutChanged }

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
