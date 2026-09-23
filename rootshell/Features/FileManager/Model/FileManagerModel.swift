//
//  FileManagerModel.swift
//  rootshell
//
//  Per-window file manager state: two panes, focus, sheets, and the actions
//  that turn selections into transfer jobs. Owned by MainView and kept alive
//  while the UI is hidden, so reopening lands exactly where the user left.
//

import Foundation

enum FileManagerPresentation: String, CaseIterable, Codable, Sendable {
    case sidebar
    case overlay

    var title: String {
        switch self {
        case .sidebar: String(localized: "Sidebar", comment: "File manager presentation option")
        case .overlay: String(localized: "Overlay", comment: "File manager presentation option")
        }
    }
}

@MainActor
@Observable
final class FileManagerModel {
    enum Sheet: Identifiable {
        case connect(FilePaneModel.Side)
        case goToPath
        case rename(RFEntry)
        case newFolder
        case info(RFEntry)
        case confirmDelete([RFEntry])
        case shortcuts

        var id: String {
            switch self {
            case .connect(let side): "connect-\(side.rawValue)"
            case .goToPath: "goto"
            case .rename(let entry): "rename-\(entry.path)"
            case .newFolder: "newFolder"
            case .info(let entry): "info-\(entry.path)"
            case .confirmDelete: "delete"
            case .shortcuts: "shortcuts"
            }
        }
    }

    let prompts = FileManagerPrompts()
    let left: FilePaneModel
    let right: FilePaneModel

    var activeSide: FilePaneModel.Side = .left {
        didSet { if activeSide != oldValue { queueFocused = false } }
    }
    var queueFocused = false
    var queueCursor: UUID?
    var isQueueExpanded = false
    var sheet: Sheet?
    /// Bumped to move keyboard focus into the active pane's field.
    var focusRequestID = 0
    /// Quick Look request; the view presents it.
    var previewRequest: PreviewRequest?
    var errorMessage: String?

    struct PreviewRequest: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Opens a pane directory in a terminal; wired by MainView.
    @ObservationIgnored var openInTerminal: ((SFTPEndpoint, String) -> Bool)?
    /// The in-flight pane-to-pane drag, read by the drop target.
    @ObservationIgnored var dragPayload: DragPayload?
    /// The terminal pane the manager was last opened from, offered in the location picker.
    private(set) var originPane: SFTPEndpoint.PaneSource?

    @ObservationIgnored private var finishedObserver: Task<Void, Never>?

    init() {
        left = FilePaneModel(side: .left, prompts: prompts)
        right = FilePaneModel(side: .right, prompts: prompts)
        restore()
        finishedObserver = Task { [weak self] in
            for await job in FileTransferCenter.shared.finishedJobs() {
                self?.refreshPanes(affectedBy: job)
            }
        }
    }

    func pane(_ side: FilePaneModel.Side) -> FilePaneModel {
        side == .left ? left : right
    }

    var activePane: FilePaneModel { pane(activeSide) }
    var otherPane: FilePaneModel { pane(activeSide.other) }

    /// Moves the keyboard into the active pane's filter field. Only with a hardware
    /// keyboard: without one, focusing would raise the on-screen keyboard and
    /// cover much of the listing, so touch users tap the field when they want it.
    func requestFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return }
        focusRequestID += 1
    }

    // MARK: - Opening

    /// Brings the focused terminal's host into view. A pane already showing that
    /// host keeps its folder (state survives reopening); otherwise the host opens
    /// on the right at the terminal's working directory, local stays on the left.
    func present(from source: SFTPEndpoint.PaneSource?, directory: String?) {
        guard let source else { return }
        originPane = source
        let endpoint: SFTPEndpoint = source.fallbackConfig.underlyingSSHConfig == nil ? .local : .pane(source)
        if let existing = [left, right].first(where: { $0.endpoint.sharesFileSystem(with: endpoint) }) {
            activeSide = existing.id
            return
        }
        let side: FilePaneModel.Side = endpoint.isLocal ? .left : .right
        pane(side).connect(to: endpoint, path: directory)
        activeSide = side
    }


    // MARK: - Commands

    func perform(_ command: FileManagerCommand) {
        let pane = activePane
        switch command {
        case .moveCursor, .extendSelection, .open, .close:
            break
        case .toggleSelection:
            pane.selection.toggleCursor()
        case .selectAll:
            pane.selection.selectAll(pane.visiblePaths)
        case .openInTerminal:
            openActiveInTerminal()
        case .parent:
            pane.goUp()
        case .back:
            pane.goBack()
        case .forward:
            pane.goForward()
        case .switchPane:
            activeSide = activeSide.other
            requestFocus()
        case .goToPath:
            sheet = .goToPath
        case .connect:
            sheet = .connect(activeSide)
        case .refresh:
            pane.refresh()
        case .toggleHidden:
            let show = !pane.showHidden
            left.showHidden = show
            right.showHidden = show
            SettingsStore.shared.set(Settings.Transfer.fileManagerShowHidden, show)
        case .quickLook:
            if let entry = pane.cursorEntry, !entry.isDirectory { preview(entry, in: pane) }
        case .copyToOther:
            transferToOther(move: false)
        case .moveToOther:
            transferToOther(move: true)
        case .rename:
            if let entry = pane.cursorEntry { sheet = .rename(entry) }
        case .newFolder:
            sheet = .newFolder
        case .delete:
            if queueFocused {
                FileTransferCenter.shared.cancelAll()
            } else {
                let entries = pane.actionEntries
                if !entries.isEmpty { sheet = .confirmDelete(entries) }
            }
        case .info:
            if let entry = pane.cursorEntry { sheet = .info(entry) }
        case .focusQueue:
            queueFocused.toggle()
            if queueFocused {
                isQueueExpanded = true
                queueCursor = queueCursor ?? FileTransferCenter.shared.jobs.last?.id
            }
        case .cancelJob:
            let center = FileTransferCenter.shared
            if let id = queueCursor, let job = center.jobs.first(where: { $0.id == id }) {
                job.state.isFinished ? center.remove(job) : center.cancel(job)
            }
        case .cancelAllJobs:
            FileTransferCenter.shared.cancelAll()
        case .showShortcuts:
            sheet = .shortcuts
        }
    }

    /// Enter on the cursor row: a folder opens, a file previews.
    func openCursor() {
        let pane = activePane
        guard let entry = pane.cursorEntry else { return }
        if !pane.open(entry) { preview(entry, in: pane) }
    }

    func moveQueueCursor(by delta: Int) {
        let ids = FileTransferCenter.shared.jobs.map(\.id)
        guard !ids.isEmpty else { return }
        let current = queueCursor.flatMap(ids.firstIndex(of:)) ?? (delta > 0 ? -1 : ids.count)
        queueCursor = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    // MARK: - File operations

    func transferToOther(move: Bool, entries: [RFEntry]? = nil, from side: FilePaneModel.Side? = nil) {
        let source = pane(side ?? activeSide)
        let destination = pane((side ?? activeSide).other)
        let items = entries ?? source.actionEntries
        guard !items.isEmpty, !destination.path.isEmpty else { return }
        enqueue(TransferJob(
            operation: move ? .move : .copy,
            source: source.endpoint,
            sourcePaths: items.map(\.path),
            destination: destination.endpoint,
            destinationDirectory: destination.path
        ))
        source.selection.clear()
    }

    /// Drops onto a pane: items from the other pane, or local files dragged in.
    func receive(paths: [String], from endpoint: SFTPEndpoint, into side: FilePaneModel.Side, directory: String? = nil, move: Bool = false) {
        let destination = pane(side)
        guard let directory = directory ?? (destination.path.isEmpty ? nil : destination.path) else { return }
        enqueue(TransferJob(
            operation: move ? .move : .copy,
            source: endpoint,
            sourcePaths: paths,
            destination: destination.endpoint,
            destinationDirectory: directory
        ))
    }

    func delete(_ entries: [RFEntry]) {
        let pane = activePane
        enqueue(TransferJob(operation: .delete, source: pane.endpoint, sourcePaths: entries.map(\.path)))
        pane.selection.clear()
    }

    func setPermissions(_ mode: UInt32, for entries: [RFEntry]) {
        enqueue(TransferJob(operation: .setPermissions(mode), source: activePane.endpoint, sourcePaths: entries.map(\.path)))
    }

    func rename(_ entry: RFEntry, to newName: String) async {
        let pane = activePane
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name, !trimmed.contains("/") else { return }
        let target = FileTransferLogic.join(FileTransferLogic.parent(of: entry.path), trimmed)
        await run(in: pane, focus: target) { fs in
            if await fs.exists(target) {
                throw FileManagerActionError.alreadyExists(trimmed)
            }
            try await fs.rename(entry.path, to: target)
        }
    }

    func createFolder(named name: String) async {
        let pane = activePane
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !pane.path.isEmpty else { return }
        let target = FileTransferLogic.join(pane.path, trimmed)
        await run(in: pane, focus: target) { try await $0.makeDirectory(target) }
    }

    /// Runs a quick metadata operation inline, then refreshes with the cursor on `focus`.
    private func run(in pane: FilePaneModel, focus: String?, _ body: (FileSystemEndpoint) async throws -> Void) async {
        do {
            try await body(try await pane.fileSystem())
            pane.refresh()
            if let focus { pane.selection.setCursor(focus) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enqueue(_ job: TransferJob) {
        FileTransferCenter.shared.enqueue(job, prompts: prompts)
    }

    // MARK: - Preview and terminal

    func preview(_ entry: RFEntry, in pane: FilePaneModel) {
        Task {
            do {
                let url = try await FileManagerPreviewCache.localURL(for: entry, fs: try await pane.fileSystem())
                previewRequest = PreviewRequest(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var canOpenActiveInTerminal: Bool {
        openInTerminal != nil && !activePane.path.isEmpty
    }

    func openActiveInTerminal() {
        let pane = activePane
        var directory = pane.path
        if let entry = pane.cursorEntry, entry.isDirectory, pane.selection.count <= 1 { directory = entry.path }
        guard !directory.isEmpty else { return }
        if openInTerminal?(pane.endpoint, directory) == false {
            errorMessage = String(localized: "This location can't be opened in a terminal.", comment: "File manager error")
        }
    }

    // MARK: - Refresh after jobs

    private func refreshPanes(affectedBy job: TransferJob) {
        for pane in [left, right] where !pane.path.isEmpty {
            let touchesSource = pane.endpoint.sharesFileSystem(with: job.source)
                && job.sourcePaths.contains { FileTransferLogic.parent(of: $0) == pane.path || $0 == pane.path }
            let touchesDestination = job.destination.map(pane.endpoint.sharesFileSystem) == true
                && job.destinationDirectory == pane.path
            if touchesSource || touchesDestination { pane.refresh() }
        }
    }

    // MARK: - Persistence

    private struct SavedState: Codable {
        var left: SavedPane?
        var right: SavedPane?
        var activeSide: String

        struct SavedPane: Codable {
            var endpoint: String
            var path: String
        }
    }

    func save() {
        func saved(_ pane: FilePaneModel) -> SavedState.SavedPane? {
            guard let key = pane.endpoint.persistentKey else { return nil }
            return SavedState.SavedPane(endpoint: key, path: pane.path)
        }
        let state = SavedState(left: saved(left), right: saved(right), activeSide: activeSide.rawValue)
        guard let data = try? JSONEncoder().encode(state) else { return }
        SettingsStore.shared.set(Settings.Transfer.fileManagerPaneState, String(decoding: data, as: UTF8.self))
    }

    private func restore() {
        guard let json = SettingsStore.shared.value(Settings.Transfer.fileManagerPaneState),
              let state = try? JSONDecoder().decode(SavedState.self, from: Data(json.utf8))
        else {
            left.connect(to: .local)
            return
        }
        for (pane, saved) in [(left, state.left), (right, state.right)] {
            guard let saved, let endpoint = SFTPEndpoint(persistentKey: saved.endpoint) else { continue }
            // Remote panes reconnect lazily on first show, so restoring never prompts.
            if endpoint.isLocal {
                pane.connect(to: endpoint, path: saved.path.isEmpty ? nil : saved.path)
            } else {
                pane.restorePending(endpoint: endpoint, path: saved.path)
            }
        }
        if left.path.isEmpty, !left.hasPendingRestore { left.connect(to: .local) }
        activeSide = FilePaneModel.Side(rawValue: state.activeSide) ?? .left
    }

    /// Connects panes whose remote endpoint was restored but not yet opened.
    func activatePendingRestores() {
        left.activatePendingRestore()
        right.activatePendingRestore()
    }

    func tearDown() {
        save()
        finishedObserver?.cancel()
        left.detach()
        right.detach()
    }
}

enum FileManagerActionError: LocalizedError {
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            String(localized: "“\(name)” already exists.", comment: "File manager error; argument is a file name")
        }
    }
}
