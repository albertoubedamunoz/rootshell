import Foundation

/// A frozen, display-ordered mapping. Numbers are picker labels, not mutable
/// tmux pane indices. Fixed-width labels avoid ambiguity for 10+ panes.
struct TmuxPaneSelection {
    enum Action: Equatable { case zoom, swap }
    enum Result: Equatable {
        case pending
        case selected(Int)
        case cancelled
    }

    let paneIDs: [Int]
    let labels: [String]
    private(set) var prefix = ""
    private(set) var result: Result = .pending

    init?(paneIDs: [Int], excludingPaneID: Int? = nil) {
        guard paneIDs.count > 1, Set(paneIDs).count == paneIDs.count,
              paneIDs.allSatisfy({ $0 >= 0 }) else { return nil }
        if let excludingPaneID, !paneIDs.contains(excludingPaneID) { return nil }
        let candidates = paneIDs.filter { $0 != excludingPaneID }
        self.paneIDs = candidates
        let width = String(candidates.count).count
        labels = (1...candidates.count).map {
            let number = String($0)
            return String(repeating: "0", count: width - number.count) + number
        }
    }

    mutating func consume(_ text: String, modified: Bool = false) -> Result {
        guard result == .pending else { return result }
        guard !modified, text.utf8.count == 1,
              let byte = text.utf8.first, (48...57).contains(byte) else {
            result = .cancelled
            return result
        }
        prefix += text
        if let index = labels.firstIndex(of: prefix) {
            result = .selected(paneIDs[index])
        } else if !labels.contains(where: { $0.hasPrefix(prefix) }) {
            result = .cancelled
        }
        return result
    }

    enum Failure: Error { case invalidTarget, invalidReply, layoutChanged }

    /// One native command, preserving the active pane and any existing zoom.
    /// Window-qualified IDs must not follow a pane moved into another window.
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
