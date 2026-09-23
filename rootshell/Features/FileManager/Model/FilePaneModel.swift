//
//  FilePaneModel.swift
//  rootshell
//
//  One side of the file manager: an endpoint, a directory, its listing,
//  history, filter and selection. Survives the UI being hidden.
//

import Foundation
import os.log

@MainActor
@Observable
final class FilePaneModel: Identifiable {
    enum Side: String, CaseIterable {
        case left
        case right

        var other: Side { self == .left ? .right : .left }
    }

    enum Status: Equatable {
        case idle
        case connecting
        case loading
        case failed(String)
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "FileManagerPane")

    let id: Side
    private let prompts: FileManagerPrompts

    private(set) var endpoint: SFTPEndpoint = .local
    private(set) var path = ""
    private(set) var entries: [RFEntry] = []
    private(set) var visibleEntries: [RFEntry] = []
    private(set) var status: Status = .idle
    var selection = FileListSelection()

    var filterText = "" {
        didSet { if filterText != oldValue { applyFilter() } }
    }

    var sortOrder: RFSortOrder = .nameAsc {
        didSet { if sortOrder != oldValue { applyFilter() } }
    }

    var showHidden: Bool {
        didSet { if showHidden != oldValue { applyFilter() } }
    }

    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var retainedEndpoint: SFTPEndpoint?

    init(side: Side, prompts: FileManagerPrompts) {
        id = side
        self.prompts = prompts
        showHidden = SettingsStore.shared.value(Settings.Transfer.fileManagerShowHidden)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isBusy: Bool { status == .connecting || status == .loading }
    var visiblePaths: [String] { visibleEntries.map(\.path) }

    var cursorEntry: RFEntry? {
        selection.cursor.flatMap { cursor in visibleEntries.first { $0.path == cursor } }
    }

    /// Selected entries, or the cursor row when nothing is selected.
    var actionEntries: [RFEntry] {
        let paths = Set(selection.effectivePaths(in: visiblePaths))
        return visibleEntries.filter { paths.contains($0.path) }
    }

    var locationTitle: String {
        path.isEmpty ? endpoint.displayName : "\(endpoint.displayName):\(path)"
    }

    func fileSystem(purpose: SFTPConnectionPool.Purpose = .browse) async throws -> FileSystemEndpoint {
        try await SFTPConnectionPool.shared.fileSystem(for: endpoint, purpose: purpose, prompts: prompts)
    }

    // MARK: - Navigation

    /// Points the pane at `endpoint`, starting at `path` or its home directory.
    func connect(to endpoint: SFTPEndpoint, path: String? = nil) {
        let pool = SFTPConnectionPool.shared
        if let retainedEndpoint { pool.release(retainedEndpoint) }
        pool.retain(endpoint)
        retainedEndpoint = endpoint

        self.endpoint = endpoint
        backStack = []
        forwardStack = []
        entries = []
        visibleEntries = []
        selection = FileListSelection()
        filterText = ""
        self.path = ""
        load(path, resolvingHome: true)
    }

    func navigate(to newPath: String) {
        guard newPath != path else { return refresh() }
        if !path.isEmpty { backStack.append(path) }
        forwardStack = []
        filterText = ""
        load(newPath, focus: nil)
    }

    func goUp() {
        guard !path.isEmpty, path != "/" else { return }
        let child = path
        navigate(to: FileTransferLogic.parent(of: path))
        pendingCursor = child
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        load(previous, focus: nil)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        load(next, focus: nil)
    }

    func refresh() {
        load(path.isEmpty ? nil : path, focus: selection.cursor, resolvingHome: path.isEmpty)
    }

    /// Enters a directory; returns false for files so the caller can preview them.
    @discardableResult
    func open(_ entry: RFEntry) -> Bool {
        guard entry.isDirectory else { return false }
        navigate(to: entry.path)
        return true
    }

    /// Resolves a typed path (relative, `~`) against the current directory.
    func goTo(_ typed: String) async {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let fs = try await fileSystem()
            let resolved = try await fs.canonicalPath(trimmed, relativeTo: path.isEmpty ? "/" : path)
            let info = try await fs.info(resolved)
            if info.isDirectory {
                navigate(to: resolved)
            } else {
                navigate(to: FileTransferLogic.parent(of: resolved))
                pendingCursor = resolved
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    @ObservationIgnored private var pendingCursor: String?

    private func load(_ requested: String?, focus: String? = nil, resolvingHome: Bool = false) {
        loadTask?.cancel()
        if let focus { pendingCursor = focus }
        let endpoint = endpoint
        status = SFTPConnectionPool.shared.isConnected(endpoint) ? .loading : .connecting
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fs = try await self.fileSystem()
                var target = requested ?? ""
                if resolvingHome, target.isEmpty { target = try await fs.homeDirectory() }
                self.status = .loading
                let listing = try await fs.list(target)
                try Task.checkCancellation()
                guard self.endpoint == endpoint else { return }
                self.path = target
                self.entries = listing
                self.status = .idle
                self.applyFilter()
            } catch is CancellationError {
                return
            } catch {
                guard self.endpoint == endpoint, !Task.isCancelled else { return }
                Self.logger.error("Listing failed: \(error.localizedDescription, privacy: .public)")
                if resolvingHome, let requested, !requested.isEmpty {
                    // A remembered folder that no longer exists: fall back to home.
                    self.load(nil, resolvingHome: true)
                    return
                }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    private func applyFilter() {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        let shown = entries.filter { entry in
            (showHidden || !entry.isHidden || (!query.isEmpty && query.hasPrefix(".")))
                && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query))
        }
        visibleEntries = RFEntry.sorted(shown, by: sortOrder)
        let paths = visiblePaths
        if let pendingCursor, paths.contains(pendingCursor) {
            selection.setCursor(pendingCursor)
            self.pendingCursor = nil
        }
        selection.reconcile(with: paths)
        if selection.cursor == nil { selection.setCursor(paths.first) }
    }

    // MARK: - Restore

    @ObservationIgnored private var pendingRestore: (endpoint: SFTPEndpoint, path: String)?

    var hasPendingRestore: Bool { pendingRestore != nil }

    /// Shows a remembered remote location without connecting yet.
    func restorePending(endpoint: SFTPEndpoint, path: String) {
        pendingRestore = (endpoint, path)
        self.endpoint = endpoint
    }

    func activatePendingRestore() {
        guard let pendingRestore else { return }
        self.pendingRestore = nil
        connect(to: pendingRestore.endpoint, path: pendingRestore.path.isEmpty ? nil : pendingRestore.path)
    }

    /// Releases the pane's hold on its connection.
    func detach() {
        loadTask?.cancel()
        if let retainedEndpoint { SFTPConnectionPool.shared.release(retainedEndpoint) }
        retainedEndpoint = nil
    }
}
