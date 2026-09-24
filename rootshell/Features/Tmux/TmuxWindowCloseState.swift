import Foundation

/// Pending UI removals. The controller retains the actual tabs and panes until
/// an authoritative prune, so a rejected or lost kill can restore them safely.
struct TmuxWindowCloseState {
    struct Request: Equatable {
        let id = UUID()
        let tabIndex: Int
    }

    private var requests: [Int: Request] = [:]

    func contains(_ windowID: Int) -> Bool { requests[windowID] != nil }

    mutating func begin(windowID: Int, tabIndex: Int) -> Request? {
        guard requests[windowID] == nil else { return nil }
        let request = Request(tabIndex: tabIndex)
        requests[windowID] = request
        return request
    }

    /// A reply/timeout from an earlier close must not undo a later close.
    mutating func restore(windowID: Int, request: Request) -> Int? {
        guard requests[windowID] == request else { return nil }
        requests.removeValue(forKey: windowID)
        return request.tabIndex
    }

    mutating func prune(keeping windowIDs: Set<Int>) {
        requests = requests.filter { windowIDs.contains($0.key) }
    }

    static func matchesGateway(owner: UUID, bindingParent: UUID, tabOwner: UUID?) -> Bool {
        owner == bindingParent && (tabOwner == nil || tabOwner == owner)
    }
}
