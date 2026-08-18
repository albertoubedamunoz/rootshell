#if !targetEnvironment(macCatalyst)

import Foundation

/// Preview state for the current tab.
enum RFPreviewState {
    case none
    case loading
    case text(cells: [[TUICell]], totalLines: Int)
    case directory(entries: [RFEntry])
    case image(path: String)  // Path to image; kitty protocol emitted separately
    case binary(size: Int64)
    case empty
    case error(String)
}

/// Cached preview content for a file.
/// File is read once into memory, all lines parsed into cells.
/// Scrolling is pure array slicing — zero I/O.
nonisolated struct RFPreviewCache {
    let path: String              // Absolute path of the cached file
    let allCells: [[TUICell]]     // All parsed lines
    let totalLines: Int           // Total line count in the file

    /// Max bytes to read from a file for preview.
    static let maxBytes = 256 * 1024  // 256KB — enough for ~5000 lines
}

/// Per-tab state for the rf file browser.
/// Each tab is fully independent: own directory, history, selection, bookmarks.
@MainActor
final class RFTab {
    let id: Int
    var name: String?  // Custom name; nil = auto from cwd

    /// Long-running activity shown in the status bar for this tab.
    var activityMessage: String?

    /// Whether the parent directory listing is still being refreshed.
    var isParentLoading = false

    /// Notifies the UI when async state changes complete.
    var onAsyncStateChange: (() -> Void)?

    /// Current directory being browsed.
    var currentDir: RFDirectory

    /// Parent directory (one level up from currentDir).
    var parentDir: RFDirectory?

    /// Preview state for the currently hovered entry.
    var previewState: RFPreviewState = .none

    /// Preview scroll offset (line offset for text previews).
    var previewSkip: Int = 0

    /// Cached preview content — avoids re-running bat on every scroll.
    var previewCache: RFPreviewCache?

    /// Navigation history.
    var backStack: [String] = []
    var forwardStack: [String] = []

    /// Multi-selected file paths (absolute).
    var selected: Set<String> = []

    /// Search results (nil = not in search mode). When set, the current column
    /// shows these entries instead of the directory listing. Cleared on Escape.
    var searchResults: RFDirectory?

    /// Show hidden files.
    var showHidden: Bool = false {
        didSet {
            currentDir.showHidden = showHidden
            parentDir?.showHidden = showHidden
        }
    }

    /// Sort order.
    var sortOrder: RFSortOrder = .nameAsc {
        didSet {
            currentDir.sortOrder = sortOrder
            parentDir?.sortOrder = sortOrder
        }
    }

    /// Navigation boundary — user cannot navigate above this path.
    /// Defaults to ~/Documents. Set to nil to allow unrestricted navigation.
    var rootPath: String?

    /// Per-tab bookmarks (character key → absolute path).
    var bookmarks: [Character: String] = [:]

    /// Previous directory (for ' ' jump-to-previous).
    var previousPath: String?

    /// Directory cache for fast back-navigation.
    private var dirCache: [String: RFDirectory] = [:]

    /// Background refresh for the parent column, primarily for remote tabs.
    private var parentLoadTask: Task<Void, Never>?

    /// Display name for the tab bar.
    var displayName: String {
        if let name { return name }
        if dataSource.isRemote {
            return dataSource.connectionLabel
        }
        return (currentDir.path as NSString).lastPathComponent
    }

    /// Data source for filesystem operations (local or SFTP).
    let dataSource: RFDataSource

    init(id: Int, path: String, dataSource: RFDataSource) {
        self.id = id
        self.dataSource = dataSource
        self.currentDir = RFDirectory(path: path)
        if dataSource.isRemote {
            // Remote: caller must await loadInitial() after init
        } else {
            self.currentDir.load()
            loadParent()
        }
    }

    deinit {
        parentLoadTask?.cancel()
    }

    /// Async initialization for remote data sources.
    /// Must be called after init when dataSource.isRemote is true.
    func loadInitial() async throws {
        try await currentDir.load(using: dataSource)
        scheduleParentLoad()
    }

    // MARK: - Navigation

    /// Enter a directory (or the currently hovered entry if it's a directory).
    func enter(entry: RFEntry? = nil) async throws {
        let target: RFEntry
        if let entry {
            target = entry
        } else {
            guard let hovered = currentDir.hoveredEntry, hovered.isDirectory else { return }
            target = hovered
        }
        guard target.isDirectory else { return }

        try await navigateTo(path: target.path, pushHistory: true)
    }

    /// Navigate to parent directory.
    func leave() async throws {
        let parentPath = (currentDir.path as NSString).deletingLastPathComponent
        guard parentPath != currentDir.path else { return } // Already at root
        guard isWithinRoot(parentPath) else { return }

        let currentDirName = (currentDir.path as NSString).lastPathComponent
        try await navigateTo(path: parentPath, pushHistory: true)
        // Position cursor on the directory we just left
        currentDir.jumpToName(currentDirName, visibleCount: 1000)
    }

    /// Navigate to a specific path.
    func navigateTo(path: String, pushHistory: Bool) async throws {
        let resolvedPath = (path as NSString).standardizingPath
        guard isWithinRoot(resolvedPath) else { return }

        if pushHistory {
            backStack.append(currentDir.path)
            forwardStack.removeAll()
        }
        previousPath = currentDir.path

        // Cache current directory
        dirCache[currentDir.path] = currentDir

        // Load or reuse cached directory
        if let cached = dirCache[resolvedPath] {
            currentDir = cached
            currentDir.showHidden = showHidden
            currentDir.sortOrder = sortOrder
            try await loadDir(currentDir)
        } else {
            currentDir = RFDirectory(path: resolvedPath)
            currentDir.showHidden = showHidden
            currentDir.sortOrder = sortOrder
            try await loadDir(currentDir)
        }

        scheduleParentLoad()
        previewState = .none
        previewSkip = 0
    }

    /// Go back in history.
    func goBack() async throws {
        guard let prev = backStack.popLast() else { return }
        guard isWithinRoot(prev) else { backStack.append(prev); return }
        forwardStack.append(currentDir.path)
        previousPath = currentDir.path
        dirCache[currentDir.path] = currentDir

        if let cached = dirCache[prev] {
            currentDir = cached
            try await loadDir(currentDir)
        } else {
            currentDir = RFDirectory(path: prev)
            currentDir.showHidden = showHidden
            currentDir.sortOrder = sortOrder
            try await loadDir(currentDir)
        }

        scheduleParentLoad()
        previewState = .none
        previewSkip = 0
    }

    /// Go forward in history.
    func goForward() async throws {
        guard let next = forwardStack.popLast() else { return }
        guard isWithinRoot(next) else { forwardStack.append(next); return }
        backStack.append(currentDir.path)
        previousPath = currentDir.path
        dirCache[currentDir.path] = currentDir

        if let cached = dirCache[next] {
            currentDir = cached
            try await loadDir(currentDir)
        } else {
            currentDir = RFDirectory(path: next)
            currentDir.showHidden = showHidden
            currentDir.sortOrder = sortOrder
            try await loadDir(currentDir)
        }

        scheduleParentLoad()
        previewState = .none
        previewSkip = 0
    }

    /// Toggle hidden files visibility.
    func toggleHidden() {
        showHidden = !showHidden
    }

    /// Cycle to next sort order.
    func cycleSortOrder() {
        sortOrder = sortOrder.next()
    }

    /// Refresh current directory.
    func refresh() async throws {
        let hoveredName = currentDir.hoveredEntry?.name
        try await loadDir(currentDir)
        if let hoveredName {
            currentDir.jumpToName(hoveredName, visibleCount: 1000)
        }
        scheduleParentLoad()
        previewState = .none
    }

    // MARK: - Selection

    /// Toggle selection on the cursor entry and advance cursor.
    func toggleSelection(visibleCount: Int) {
        guard let entry = currentDir.hoveredEntry else { return }
        if selected.contains(entry.path) {
            selected.remove(entry.path)
        } else {
            selected.insert(entry.path)
        }
        currentDir.moveCursor(delta: 1, visibleCount: visibleCount)
    }

    /// Clear all selections.
    func clearSelection() {
        selected.removeAll()
    }

    /// The paths that should be operated on (selection if non-empty, otherwise cursor entry).
    var operationPaths: [String] {
        if !selected.isEmpty {
            return Array(selected)
        }
        if let entry = currentDir.hoveredEntry {
            return [entry.path]
        }
        return []
    }

    // MARK: - Private

    /// Load a directory using the appropriate method based on data source type.
    private func loadDir(_ dir: RFDirectory) async throws {
        if dataSource.isRemote {
            try await dir.load(using: dataSource)
        } else {
            dir.load()
        }
    }

    /// Sync parent loading (for local init).
    private func loadParent() {
        let parentPath = (currentDir.path as NSString).deletingLastPathComponent
        if parentPath != currentDir.path {
            if let cached = dirCache[parentPath] {
                parentDir = cached
                parentDir?.load()
            } else {
                parentDir = RFDirectory(path: parentPath)
                parentDir?.showHidden = showHidden
                parentDir?.sortOrder = sortOrder
                parentDir?.load()
            }
        } else {
            parentDir = nil
        }
    }

    /// Refresh the parent column without blocking the current directory render.
    private func scheduleParentLoad() {
        parentLoadTask?.cancel()

        let parentPath = (currentDir.path as NSString).deletingLastPathComponent
        guard parentPath != currentDir.path else {
            parentDir = nil
            isParentLoading = false
            onAsyncStateChange?()
            return
        }

        let parentDirectory: RFDirectory
        if let cached = dirCache[parentPath] {
            parentDirectory = cached
        } else {
            parentDirectory = RFDirectory(path: parentPath)
        }
        parentDirectory.showHidden = showHidden
        parentDirectory.sortOrder = sortOrder
        parentDir = parentDirectory

        if !dataSource.isRemote {
            parentDirectory.load()
            dirCache[parentPath] = parentDirectory
            isParentLoading = false
            return
        }

        isParentLoading = true
        let currentPath = currentDir.path
        parentLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.loadDir(parentDirectory)
            } catch is CancellationError {
                return
            } catch {
                if self.currentDir.path == currentPath {
                    self.isParentLoading = false
                    self.onAsyncStateChange?()
                }
                return
            }

            guard !Task.isCancelled, self.currentDir.path == currentPath else { return }
            self.dirCache[parentPath] = parentDirectory
            self.parentDir = parentDirectory
            self.isParentLoading = false
            self.onAsyncStateChange?()
        }
    }

    /// Check if a path is at or below the navigation root.
    private func isWithinRoot(_ path: String) -> Bool {
        guard let root = rootPath else { return true }
        let standardized = (path as NSString).standardizingPath
        return standardized == root || standardized.hasPrefix(root + "/")
    }
}

#endif
