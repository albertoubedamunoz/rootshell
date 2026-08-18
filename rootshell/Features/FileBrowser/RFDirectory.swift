#if !targetEnvironment(macCatalyst)

import Foundation

/// Directory model with entries, sorting, filtering, and scroll state.
@MainActor
final class RFDirectory {
    let path: String

    /// All entries (loaded from disk or set for search results).
    var allEntries: [RFEntry] = [] {
        didSet { refilter() }
    }

    /// Current sort order.
    var sortOrder: RFSortOrder = .nameAsc {
        didSet { resort() }
    }

    /// Whether to show hidden files.
    var showHidden: Bool = false {
        didSet { refilter() }
    }

    /// Active live filter text (nil = no filter).
    var filterText: String? = nil {
        didSet { refilter() }
    }

    /// Entries visible after hidden + filter applied.
    private(set) var visibleEntries: [RFEntry] = []

    /// Cursor position (index into visibleEntries).
    var cursor: Int = 0

    /// Scroll offset (index of first visible entry in the viewport).
    var scrollOffset: Int = 0

    /// Scrolloff: lines of context to maintain above/below cursor.
    static let scrolloff = 3

    init(path: String) {
        self.path = path
    }

    /// Load entries from disk and apply sort + filter.
    func load() {
        let raw = RFEntry.loadDirectory(at: path)
        allEntries = RFEntry.sorted(raw, by: sortOrder)
    }

    /// Load entries via a data source (async — required for SFTP).
    func load(using dataSource: RFDataSource) async throws {
        let raw = try await dataSource.loadDirectory(at: path)
        allEntries = RFEntry.sorted(raw, by: sortOrder)
    }

    /// Re-sort all entries and refilter.
    private func resort() {
        allEntries = RFEntry.sorted(allEntries, by: sortOrder)
    }

    /// Recompute visibleEntries from allEntries + showHidden + filterText.
    private func refilter() {
        var entries = allEntries

        if !showHidden {
            entries = entries.filter { !$0.isHidden }
        }

        if let filter = filterText, !filter.isEmpty {
            let lower = filter.lowercased()
            entries = entries.filter { $0.name.lowercased().contains(lower) }
        }

        visibleEntries = entries
        clampCursor()
    }

    /// Update git status for entries matching the status dictionary.
    func applyGitStatus(_ statusMap: [String: RFGitFileStatus]) {
        for i in allEntries.indices {
            let name = allEntries[i].name
            allEntries[i].gitStatus = statusMap[name]
        }
        // Refilter to propagate to visible entries (re-sorts are already applied)
        refilter()
    }

    // MARK: - Cursor Movement

    /// Move cursor by delta. Returns true if cursor actually moved.
    @discardableResult
    func moveCursor(delta: Int, visibleCount: Int) -> Bool {
        let oldCursor = cursor
        cursor = max(0, min(visibleEntries.count - 1, cursor + delta))
        adjustScroll(visibleCount: visibleCount)
        return cursor != oldCursor
    }

    /// Jump cursor to a specific index.
    func jumpTo(index: Int, visibleCount: Int) {
        cursor = max(0, min(visibleEntries.count - 1, index))
        adjustScroll(visibleCount: visibleCount)
    }

    /// Jump to the entry with the given name, if found.
    func jumpToName(_ name: String, visibleCount: Int) {
        if let idx = visibleEntries.firstIndex(where: { $0.name == name }) {
            jumpTo(index: idx, visibleCount: visibleCount)
        }
    }

    /// Scroll by delta without moving cursor (for mouse scroll on inactive columns).
    func scroll(delta: Int, visibleCount: Int) {
        scrollOffset = max(0, min(visibleEntries.count - visibleCount, scrollOffset + delta))
    }

    /// Clamp scrollOffset to a valid viewport start for the given height.
    /// Called at render time (when the real region height is known) so the
    /// model's scroll state matches the rendered first row — keeping mouse
    /// hit-testing, scroll indicators, and the display in sync. clampCursor()
    /// runs on refilter without viewport info, so it can only coarsely bound
    /// scrollOffset; this performs the precise viewport clamp.
    func clampScroll(visibleCount: Int) {
        let maxOffset = max(0, visibleEntries.count - max(0, visibleCount))
        scrollOffset = max(0, min(scrollOffset, maxOffset))
    }

    /// The currently selected entry, if any.
    var hoveredEntry: RFEntry? {
        guard cursor >= 0, cursor < visibleEntries.count else { return nil }
        return visibleEntries[cursor]
    }

    // MARK: - Private

    private func clampCursor() {
        if visibleEntries.isEmpty {
            cursor = 0
            scrollOffset = 0
        } else {
            cursor = max(0, min(visibleEntries.count - 1, cursor))
            // Keep scrollOffset in bounds when the list shrinks (filter/reload).
            // adjustScroll only runs on cursor movement, so without this the
            // next render could build an invalid scrollOffset..<endIndex range.
            scrollOffset = max(0, min(scrollOffset, visibleEntries.count - 1))
        }
    }

    private func adjustScroll(visibleCount: Int) {
        guard visibleCount > 0 else { return }
        let off = Self.scrolloff

        // Ensure cursor is visible with scrolloff context
        if cursor < scrollOffset + off {
            scrollOffset = max(0, cursor - off)
        }
        if cursor >= scrollOffset + visibleCount - off {
            scrollOffset = max(0, cursor - visibleCount + off + 1)
        }

        // Clamp scroll offset
        let maxOffset = max(0, visibleEntries.count - visibleCount)
        scrollOffset = min(scrollOffset, maxOffset)
    }
}

#endif
