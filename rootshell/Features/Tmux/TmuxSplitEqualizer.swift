/// Equalize existing server cells instead of importing a layout string: tmux's
/// layout parser assigns panes by index and ignores the serialized pane IDs.
@MainActor
enum TmuxSplitEqualizer {
    enum Failure: Error {
        case invalidSnapshot
        case layoutChanged
        case didNotConverge
        case unsafeLayout
    }

    private struct Snapshot {
        let layout: String
        let zoomedPaneID: Int?
        let tree: TmuxLayoutNode
        let hasDecorations: Bool

        init(_ reply: String) throws {
            let lines = reply.split(whereSeparator: \.isNewline)
            guard lines.count == 1 else { throw Failure.invalidSnapshot }
            let fields = lines[0].split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty,
                  fields[1] == "0" || fields[1] == "1",
                  fields[2].first == "%", let paneID = Int(fields[2].dropFirst()), paneID >= 0,
                  let tree = TmuxLayoutNode.parseServerLayout(String(fields[0])) else {
                throw Failure.invalidSnapshot
            }
            self.tree = tree
            // Decorations change tmux's leaf minima. Refuse -E until those
            // additional cells can be accounted for, rather than undercounting.
            hasDecorations = fields[3] != "off" || (fields[4] != "off" && !fields[4].isEmpty)
            layout = String(fields[0])
            zoomedPaneID = fields[1] == "1" ? paneID : nil
        }
    }

    /// `send` must validate that the window still has this topology before each
    /// command. Every call contains exactly one command / control-mode reply.
    static func run(windowID: Int, layout: TmuxLayoutNode,
                    send: (String) async throws -> String) async throws {
        let paneIDs = layout.paneIDs
        guard paneIDs.count > 1 else { return }
        guard Set(paneIDs).count == paneIDs.count, paneIDs.allSatisfy({ $0 >= 0 }) else {
            throw Failure.layoutChanged
        }
        let snapshotCommand = "display-message -p -t @\(windowID) '#{window_layout}|#{window_zoomed_flag}|#{pane_id}|#{pane-border-status}|#{pane-scrollbars}'"
        let original = try Snapshot(await send(snapshotCommand))
        func validate(_ snapshot: Snapshot) throws {
            guard snapshot.tree.hasSameTopology(as: layout) else { throw Failure.layoutChanged }
            guard !snapshot.hasDecorations, snapshot.tree.permitsNativeEqualization else {
                throw Failure.unsafeLayout
            }
        }
        // In particular, reject an unsafe zoomed layout before unzooming it.
        try validate(original)

        func restoreZoom() async throws {
            guard let paneID = original.zoomedPaneID else { return }
            let current = try Snapshot(await send(snapshotCommand))
            // Do not toggle off an already zoomed pane (including an intervening
            // zoom from another client). Window-qualified IDs cannot follow a
            // pane that has since moved to another window.
            if current.zoomedPaneID == nil {
                _ = try await send("resize-pane -Z -t @\(windowID).%\(paneID)")
            }
        }

        do {
            var previous = original.layout
            var current = original
            var converged = false
            // layout_spread_out spreads the first unequal ancestor of a pane.
            // Visit every leaf, repeating because a later ancestor resize may
            // disturb a previously equalized descendant. Compare authoritative
            // server layouts, not the asynchronously delivered UI reconcile.
            // Refresh after EVERY command: subsequent -E calls must not use
            // stale dimensions when checking recursive subtree minima.
            // Bound the passes in case another client keeps resizing the window.
            for _ in 0..<(2 * layout.depth + 1) {
                for paneID in paneIDs {
                    try validate(current)
                    _ = try await send("select-layout -E -t @\(windowID).%\(paneID)")
                    current = try Snapshot(await send(snapshotCommand))
                }
                try validate(current)
                if current.layout == previous {
                    converged = true
                    break
                }
                previous = current.layout
            }
            guard converged else { throw Failure.didNotConverge }
        } catch {
            // A failed spread may already have unzoomed the window. Preserve the
            // original error if cleanup also fails or the topology disappeared.
            try? await restoreZoom()
            throw error
        }
        try await restoreZoom()
    }
}
