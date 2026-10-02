import Foundation

/// Shared by the app and its standalone test target.
nonisolated enum PaneCloseConfirmationPolicy {
    static func shouldConfirm(isEnabled: Bool, paneCount: Int) -> Bool {
        isEnabled && paneCount > 1
    }

    /// Multiplexer tabs follow their close action, whose "Ask Each Time" is
    /// their confirmation.
    static func closeTabNeedsConfirm(isEnabled: Bool, closesViaMultiplexer: Bool) -> Bool {
        isEnabled && !closesViaMultiplexer
    }

    static func targetExists(pendingID: UUID?, livePaneIDs: [UUID]) -> Bool {
        guard let pendingID else { return false }
        return livePaneIDs.contains(pendingID)
    }
}

/// A tab close awaiting confirmation. `lastPaneID` is set when ⌘W on the
/// tab's only pane started it.
nonisolated struct PendingTabClose: Equatable, Sendable {
    let tabID: UUID
    let lastPaneID: UUID?
}
