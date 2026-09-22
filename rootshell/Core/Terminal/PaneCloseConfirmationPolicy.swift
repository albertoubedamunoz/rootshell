import Foundation

/// Shared by the app and its standalone test target.
nonisolated enum PaneCloseConfirmationPolicy {
    static func shouldConfirm(isEnabled: Bool, paneCount: Int) -> Bool {
        isEnabled && paneCount > 1
    }

    static func targetExists(pendingID: UUID?, livePaneIDs: [UUID]) -> Bool {
        guard let pendingID else { return false }
        return livePaneIDs.contains(pendingID)
    }
}
