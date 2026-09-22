import Foundation

/// A frozen, display-ordered mapping. Numbers are picker labels, not mutable
/// server pane indices. Fixed-width labels avoid ambiguity for 10+ panes.
struct PaneZoomSelection<PaneID: Hashable> {
    enum Result: Equatable {
        case pending
        case selected(PaneID)
        case cancelled
    }

    let paneIDs: [PaneID]
    let labels: [String]
    private(set) var prefix = ""
    private(set) var result: Result = .pending

    init?(paneIDs: [PaneID]) {
        guard paneIDs.count > 1, Set(paneIDs).count == paneIDs.count else { return nil }
        self.paneIDs = paneIDs
        let width = String(paneIDs.count).count
        labels = (1...paneIDs.count).map {
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
}
