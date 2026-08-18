#if !targetEnvironment(macCatalyst)

import Foundation
import Combine
import CryptoKit
import OSLog
import UIKit

/// Input mode tracking for the rf file browser.
enum RFInputMode: Equatable {
    case normal
    case filter
    case search
    case rename(original: String)
    case createFile
    case createDirectory
    case cdPath
    case sftpConnect      // SFTP connection prompt (profile or user@host)
    case sftpHostKey      // Waiting for yes/no/once response to host key prompt
    case sftpPassword     // Waiting for password input (no echo)
    case sftpConnecting   // Connection in progress (blocks input)
    case bookmarkSet      // Waiting for bookmark key after 'm'
    case bookmarkJump     // Waiting for bookmark key after '''
    case deleteConfirm
    case pasteOverwriteConfirm
    case visualSelect     // Adding to selection with cursor movement
    case visualUnselect   // Removing from selection with cursor movement
    case crocSendConfirm  // Confirm croc send of selected files
    case copyChord        // Waiting for second key: c=path, d=dir, f=filename, n=name w/o ext
    case uploadFailedPrompt // After upload failure: (r)etry / (c)opy path / (d)ismiss

    static func == (lhs: RFInputMode, rhs: RFInputMode) -> Bool {
        switch (lhs, rhs) {
        case (.normal, .normal), (.filter, .filter), (.search, .search),
             (.createFile, .createFile), (.createDirectory, .createDirectory),
             (.cdPath, .cdPath), (.sftpConnect, .sftpConnect),
             (.sftpHostKey, .sftpHostKey), (.sftpPassword, .sftpPassword),
             (.sftpConnecting, .sftpConnecting),
             (.bookmarkSet, .bookmarkSet),
             (.bookmarkJump, .bookmarkJump), (.deleteConfirm, .deleteConfirm),
             (.pasteOverwriteConfirm, .pasteOverwriteConfirm),
             (.visualSelect, .visualSelect), (.visualUnselect, .visualUnselect),
             (.crocSendConfirm, .crocSendConfirm),
             (.copyChord, .copyChord), (.uploadFailedPrompt, .uploadFailedPrompt):
            return true
        case (.rename(let a), .rename(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Yank clipboard shared across tabs.
/// Tracks the source data source to enable cross-source paste (local→SFTP, SFTP→local).
struct RFYankClipboard {
    var paths: [String]
    var isCut: Bool
    weak var source: RFLocalDataSource?  // nil for SFTP sources (use sourceRemote)
    var sourceRemote: RFSFTPDataSource?  // strong ref to keep SFTP alive for paste
    var sourceDataSource: (any RFDataSource)? { (source as (any RFDataSource)?) ?? sourceRemote }
}

/// Tracks a remote file downloaded for editing, so we can detect changes and re-upload.
struct PendingRemoteEdit {
    let tempPath: String        // Local temp file the editor operates on
    let remotePath: String      // Original remote path to upload back to
    let dataSource: RFSFTPDataSource  // Connection to upload through
    let preEditHash: Data       // SHA256 of file content before editor opened
}

/// Tracks a failed upload so the user can retry or recover their edits.
struct FailedRemoteUpload {
    let recoveryPath: String          // Durable path in Documents/.rf-recovery/
    let remotePath: String            // Where upload was headed
    let host: String                  // user@host for display
    let dataSource: RFSFTPDataSource  // For retry attempt
    let errorMessage: String          // What went wrong
}

/// Main orchestrator for the rf file browser.
/// Manages tabs, input routing, display rendering, and preview coordination.
@MainActor
final class RFCommand {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf")

    // Callbacks
    var onOutput: (@Sendable (Data) -> Void)?
    var onComplete: ((String?) -> Void)?  // optional final directory for CWD change
    var onOpenEditor: ((String, String) -> Void)?  // (filePath, editorCommand)
    var onDropToShell: ((String) -> Void)?  // (currentDirectory)
    var onCrocSend: (([String]) -> Void)?  // (file paths to send via croc)
    /// Forward a keyboard-interactive (RFC 4256) SFTP challenge to the owning
    /// local shell, which surfaces the shared prompt sheet. nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    // Terminal dimensions
    private var cols: UInt16
    private var rows: UInt16

    // State
    private(set) var tabs: [RFTab] = []
    private(set) var activeTabIndex: Int = 0
    var inputMode: RFInputMode = .normal
    var inputBuffer: String = ""
    var inputCursorPos: Int = 0
    var yankClipboard: RFYankClipboard?
    private var config: RFConfig = RFConfig()

    // Display
    private var display: RFDisplay!
    private var theme: RFTheme!
    private var inputParser: RFInputParser!

    // A pending ESC or string sequence is only distinguishable from a keypress
    // once input goes quiet, so it waits out a human pause. An open grapheme
    // cluster uses a far shorter window: it only has to outlast a pipe-read
    // split, and it delays every isolated keystroke.
    private static let sequenceFlushDelay: TimeInterval = 0.03
    private static let clusterFlushDelay: TimeInterval = 0.005
    private var inputFlushTimer: Timer?

    private var themeSubscription: AnyCancellable?
    private var themeOverrideSubscription: AnyCancellable?

    // SFTP profile picker state
    private var sftpProfileList: [ConnectionProfile] = []
    private var sftpFilteredProfiles: [ConnectionProfile] = []
    private var sftpPickerCursor: Int = 0
    private var sftpPickerScroll: Int = 0

    // SFTP host key / password prompt state
    private var sftpHostKeyContinuation: CheckedContinuation<HostKeyValidationResult, Never>?
    private var sftpHostKeyMessage: String = ""
    private var sftpHostKeyIsChanged: Bool = false
    private var sftpPasswordBuffer: String = ""
    private var sftpPendingProfile: ConnectionProfile?
    private var sftpConnectError: String?

    // Pending remote edit state (download → edit → upload)
    private var pendingRemoteEdit: PendingRemoteEdit?

    // Failed upload recovery state
    private var failedUpload: FailedRemoteUpload?

    // Transient status bar message (auto-clears after one render cycle)
    private var statusMessage: String?

    // Mouse state
    private var isDragging = false
    private var dragSeparatorIndex: Int = -1
    private var hoverCol: Int = -1
    private var hoverRow: Int = -1
    private var lastClickTime: Date = .distantPast
    private var lastClickRow: Int = -1
    private var lastClickCol: Int = -1

    // Preview
    private var previewTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var expectedImagePath: String?
    private var isOnScreen = false

    // Visual select anchor
    private var visualAnchor: Int = 0

    // Spinner animation (Braille frames matching InlineSpinnerAnimator)
    private static let spinnerFrames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var spinnerFrameIndex: Int = 0
    private var spinnerTimer: Timer?

    /// The active tab.
    var activeTab: RFTab {
        tabs[activeTabIndex]
    }

    /// The active directory for the current column — search results if in search mode,
    /// otherwise the tab's current directory.
    var activeDir: RFDirectory {
        activeTab.searchResults ?? activeTab.currentDir
    }

    /// Default data source for new tabs created within rf.
    private let defaultDataSource: RFDataSource
    private let themeTabId: UUID?
    private let themeWindowId: String?

    init(initialPath: String, cols: UInt16, rows: UInt16,
         dataSource: RFDataSource? = nil,
         themeTabId: UUID? = nil,
         themeWindowId: String? = nil,
         onOutput: (@Sendable (Data) -> Void)?,
         onComplete: ((String?) -> Void)?,
         onOpenEditor: ((String, String) -> Void)?,
         onDropToShell: ((String) -> Void)?,
         onCrocSend: (([String]) -> Void)? = nil) {
        self.cols = cols
        self.rows = rows
        self.defaultDataSource = dataSource ?? RFLocalDataSource()
        self.themeTabId = themeTabId
        self.themeWindowId = themeWindowId
        self.onOutput = onOutput
        self.onComplete = onComplete
        self.onOpenEditor = onOpenEditor
        self.onDropToShell = onDropToShell
        self.onCrocSend = onCrocSend

        self.theme = RFTheme.fromTheme(themeName: resolvedThemeName())
        self.inputParser = RFInputParser()
        self.config = RFConfig.load()

        let outputCb = onOutput
        self.display = RFDisplay(
            cols: Int(cols), rows: Int(rows),
            theme: theme,
            output: { data in outputCb?(data) }
        )

        // Create initial tab
        let tab = RFTab(id: 0, path: initialPath, dataSource: self.defaultDataSource)
        tab.showHidden = config.showHidden
        tab.sortOrder = config.sortBy
        tab.rootPath = config.rootPath
        configureTabCallbacks(tab)
        tabs.append(tab)
    }

    // MARK: - Lifecycle

    func start() {
        startThemeObservers()
        // Resuming from the editor or a shell suspend comes back through here.
        // Anything the parser was still holding belongs to the previous
        // on-screen session.
        inputParser.reset()
        isOnScreen = true
        display.enterScreen()
        display.layout.showTabBar = tabs.count > 1
        fullRender()
        schedulePreview()
        fetchGitStatus()
        Self.pruneOldRecoveryFiles()
    }

    func cancel() {
        shutdownAllTasks()
        stopThemeObservers()
        isOnScreen = false
        display.exitScreen()
    }

    private func startThemeObservers() {
        guard themeSubscription == nil, themeOverrideSubscription == nil else { return }

        themeSubscription = ThemeManager.shared.themeDidChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTheme()
                }
            }

        themeOverrideSubscription = ThemeOverrideManager.shared.overridesDidChange
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self, self.themeOverrideChangeApplies(change) else { return }
                    self.refreshTheme()
                }
            }
    }

    private func stopThemeObservers() {
        themeSubscription?.cancel()
        themeSubscription = nil
        themeOverrideSubscription?.cancel()
        themeOverrideSubscription = nil
    }

    private func resolvedThemeName() -> String {
        ThemeOverrideManager.shared.resolveTheme(tabId: themeTabId, windowId: themeWindowId).themeName
    }

    private func themeOverrideChangeApplies(_ change: ThemeOverrideManager.ThemeOverrideChange) -> Bool {
        switch change.scope {
        case .tab:
            return themeTabId?.uuidString == change.id
        case .window:
            return themeWindowId == change.id
        }
    }

    private func refreshTheme() {
        theme = RFTheme.fromTheme(themeName: resolvedThemeName())
        display.updateTheme(theme)

        for tab in tabs {
            tab.previewCache = nil
        }

        guard isOnScreen else { return }
        fullRender()
        schedulePreview()
    }

    deinit {
        themeSubscription?.cancel()
        themeOverrideSubscription?.cancel()
        spinnerTimer?.invalidate()
        inputFlushTimer?.invalidate()
    }

    /// Perform an async navigation operation.
    /// Cancels any in-flight navigation, re-renders on completion, and handles errors.
    private func performNavigation(_ operation: @escaping () async throws -> Void) {
        navigationTask?.cancel()
        let tab = activeTab
        if tab.dataSource.isRemote {
            tab.activityMessage = "Loading directory..."
            renderStatusBar()
        }

        navigationTask = Task { [weak self, weak tab] in
            do {
                try await operation()
                guard let self, let tab, !Task.isCancelled else { return }
                tab.activityMessage = nil
                self.fullRender()
                self.schedulePreview()
                self.fetchGitStatus()
            } catch is CancellationError {
                // Cancelled — ignored
            } catch {
                guard let self, let tab, !Task.isCancelled else { return }
                tab.activityMessage = nil
                self.statusMessage = error.localizedDescription
                Self.logger.error("Navigation failed: \(error.localizedDescription)")
                self.fullRender()
            }
        }
    }

    private func configureTabCallbacks(_ tab: RFTab) {
        tab.onAsyncStateChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            guard self.tabs.contains(where: { $0.id == tab.id }) else { return }
            guard self.activeTab.id == tab.id else { return }
            self.fullRender()
        }
    }

    func resize(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
        // Delete any kitty image overlay before resize — it persists at old position/size
        deleteKittyImage()
        display.resize(cols: Int(cols), rows: Int(rows))
        display.layout.showTabBar = tabs.count > 1
        fullRender()
        schedulePreview()
    }

    // MARK: - Input

    func sendInput(_ data: Data) {
        inputFlushTimer?.invalidate()
        inputFlushTimer = nil

        // Stop at the first event that takes rf off screen. A coalesced "eqx"
        // emits `e`, which opens the editor; `q` would then quit and `x` would
        // act on whatever came next. Everything after the transition, parsed or
        // still pending, belongs to a session that is no longer on screen.
        for event in inputParser.parse(data) {
            handleEvent(event)
            guard isOnScreen else {
                inputParser.reset()
                return
            }
        }

        // A lone ESC and an open grapheme cluster both only resolve once we
        // know no more bytes are coming. Chunks are pipe reads, not keystroke
        // boundaries, so a cluster split across two reads needs a window too:
        // a much shorter one, since that gap is a read boundary rather than a
        // human pause.
        let delay: TimeInterval
        if inputParser.hasPendingSequence {
            delay = Self.sequenceFlushDelay
        } else if inputParser.hasPendingCluster {
            delay = Self.clusterFlushDelay
        } else {
            return
        }
        // The flush runs synchronously in the timer callback. Hopping through a
        // Task would let a later sendInput install a replacement timer in the
        // gap, after which this stale hop would flush the newer state and clear
        // the replacement's reference. The timer is scheduled from this
        // MainActor method, so it fires on the main run loop.
        inputFlushTimer = Timer.scheduledTimer(
            withTimeInterval: delay, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inputFlushTimer = nil
                guard self.isOnScreen else { self.inputParser.reset(); return }
                // Same rule as sendInput: a resolved Alt+P is Escape plus P,
                // and Escape quits from normal mode, so P must not follow it
                // into a session that has left the screen.
                for event in self.inputParser.flush() {
                    self.handleEvent(event)
                    guard self.isOnScreen else { self.inputParser.reset(); return }
                }
            }
        }
    }

    /// Insert a decoded scalar at the cursor. The scalar can merge with a
    /// neighbouring grapheme cluster (combining marks, ZWJ emoji, regional
    /// indicators), so the cursor is recomputed rather than incremented.
    private func insertAtCursor(_ c: Character) {
        let clamped = min(max(inputCursorPos, 0), inputBuffer.count)
        let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: clamped)
        let head = String(inputBuffer[..<idx]) + String(c)
        let tail = String(inputBuffer[idx...])
        inputBuffer = head + tail
        inputCursorPos = min(head.count, inputBuffer.count)
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: RFInputEvent) {
        switch inputMode {
        case .normal:
            handleNormalEvent(event)
        case .filter:
            handleInputLineEvent(event, prompt: "filter", onConfirm: confirmFilter, onCancel: cancelFilter)
        case .search:
            handleInputLineEvent(event, prompt: "search", onConfirm: confirmSearch, onCancel: cancelSearch)
        case .rename:
            handleInputLineEvent(event, prompt: "rename", onConfirm: confirmRename, onCancel: cancelInput)
        case .createFile:
            handleInputLineEvent(event, prompt: "new file", onConfirm: confirmCreateFile, onCancel: cancelInput)
        case .createDirectory:
            handleInputLineEvent(event, prompt: "new dir", onConfirm: confirmCreateDir, onCancel: cancelInput)
        case .cdPath:
            handleCdPathEvent(event)
        case .sftpConnect:
            handleSftpConnectEvent(event)
        case .sftpHostKey:
            handleSftpHostKeyEvent(event)
        case .sftpPassword:
            handleSftpPasswordEvent(event)
        case .sftpConnecting:
            // Block all input while connecting; only allow Ctrl-C to cancel
            if case .ctrlC = event {
                cancelInput()
            }
        case .bookmarkSet:
            handleBookmarkSetEvent(event)
        case .bookmarkJump:
            handleBookmarkJumpEvent(event)
        case .deleteConfirm:
            handleDeleteConfirmEvent(event)
        case .crocSendConfirm:
            handleCrocSendConfirmEvent(event)
        case .pasteOverwriteConfirm:
            handlePasteOverwriteConfirmEvent(event)
        case .visualSelect, .visualUnselect:
            handleVisualEvent(event)
        case .copyChord:
            handleCopyChordEvent(event)
        case .uploadFailedPrompt:
            handleUploadFailedEvent(event)
        }
    }

    // MARK: - Normal Mode

    private func handleNormalEvent(_ event: RFInputEvent) {
        let tab = activeTab
        let dir = activeDir  // search results if active, otherwise currentDir
        let vc = Int(display.layout.currentRegion.height)

        switch event {
        // Navigation
        case .character("j"), .arrowDown(shift: false):
            if dir.moveCursor(delta: 1, visibleCount: vc) {
                renderCurrentColumn()
                schedulePreview()
            }

        case .character("k"), .arrowUp(shift: false):
            if dir.moveCursor(delta: -1, visibleCount: vc) {
                renderCurrentColumn()
                schedulePreview()
            }

        case .character("h"), .arrowLeft(shift: false):
            tab.searchResults = nil  // Exit search on navigation
            deleteKittyImage()  // Must delete before leave() clears previewState
            performNavigation { [tab] in try await tab.leave() }

        case .character("l"), .arrowRight(shift: false):
            if let entry = dir.hoveredEntry {
                if entry.isDirectory {
                    tab.searchResults = nil
                    performNavigation { [tab] in try await tab.navigateTo(path: entry.path, pushHistory: true) }
                }
            }

        case .enter:
            if let entry = dir.hoveredEntry {
                if entry.isDirectory {
                    tab.searchResults = nil
                    performNavigation { [tab] in try await tab.navigateTo(path: entry.path, pushHistory: true) }
                } else {
                    // For search results, navigate to the file's parent dir first
                    if tab.searchResults != nil {
                        let parentDir = (entry.path as NSString).deletingLastPathComponent
                        tab.searchResults = nil
                        performNavigation { [tab, vc] in
                            try await tab.navigateTo(path: parentDir, pushHistory: true)
                            tab.currentDir.jumpToName(entry.name, visibleCount: vc)
                        }
                    } else if activeTab.dataSource.isRemote {
                        openRemoteInEditor(entry)
                    } else {
                        openInEditor(entry.path)
                    }
                }
            }

        case .character("e"):
            if let entry = dir.hoveredEntry, !entry.isDirectory {
                if activeTab.dataSource.isRemote {
                    openRemoteInEditor(entry)
                } else {
                    openInEditor(entry.path)
                }
            }

        case .character("g"):
            dir.jumpTo(index: 0, visibleCount: vc)
            renderCurrentColumn()
            schedulePreview()

        case .character("G"):
            dir.jumpTo(index: dir.visibleEntries.count - 1, visibleCount: vc)
            renderCurrentColumn()
            schedulePreview()

        case .pageDown:
            dir.moveCursor(delta: vc, visibleCount: vc)
            renderCurrentColumn()
            schedulePreview()

        case .pageUp:
            dir.moveCursor(delta: -vc, visibleCount: vc)
            renderCurrentColumn()
            schedulePreview()

        // Preview scrolling
        case .arrowDown(shift: true), .character("J"):
            scrollPreview(delta: 1)

        case .arrowUp(shift: true), .character("K"):
            scrollPreview(delta: -1)

        case .ctrlD:
            scrollPreview(delta: display.layout.previewRegion.height / 2)

        case .ctrlU:
            scrollPreview(delta: -(display.layout.previewRegion.height / 2))

        // History
        case .character("-"), .backspace:
            performNavigation { [tab] in try await tab.goBack() }

        case .character("="):
            performNavigation { [tab] in try await tab.goForward() }

        // Toggle hidden
        case .character("."):
            tab.toggleHidden()
            fullRender()

        // Sort
        case .character("s"):
            tab.cycleSortOrder()
            fullRender()

        // Filter
        case .character("/"):
            enterInputMode(.filter)

        // Content search
        case .character("S"):
            if activeTab.dataSource.isRemote { break }  // Search not available for remote
            enterInputMode(.search)

        // cd path
        case .character(":"):
            enterInputMode(.cdPath)

        // Bookmarks
        case .character("m"):
            inputMode = .bookmarkSet
            renderStatusBar()

        case .character("'"):
            inputMode = .bookmarkJump
            renderStatusBar()

        // Selection
        case .character(" "):
            tab.toggleSelection(visibleCount: vc)
            renderCurrentColumn()

        case .character("v"):
            inputMode = .visualSelect
            visualAnchor = tab.currentDir.cursor

        case .character("V"):
            inputMode = .visualUnselect
            visualAnchor = tab.currentDir.cursor

        // File operations
        case .character("y"):
            yankSelected(cut: false)

        case .character("d"):
            yankSelected(cut: true)

        case .character("p"):
            pasteYankWithConflictCheck()

        case .character("P"):
            pasteYank(force: true)

        case .character("u"):
            yankClipboard = nil
            activeTab.clearSelection()
            fullRender()

        case .character("c"):
            inputMode = .copyChord
            renderStatusBar()

        case .character("C"):
            if !activeTab.dataSource.isRemote, !tab.operationPaths.isEmpty {
                inputMode = .crocSendConfirm
                renderStatusBar()
            }

        case .character("D"):
            if !tab.operationPaths.isEmpty {
                inputMode = .deleteConfirm
                renderStatusBar()
            }

        case .character("r"):
            if let entry = tab.currentDir.hoveredEntry {
                inputMode = .rename(original: entry.name)
                inputBuffer = entry.name
                // Position cursor before extension
                let ext = (entry.name as NSString).pathExtension
                if !ext.isEmpty {
                    inputCursorPos = entry.name.count - ext.count - 1
                } else {
                    inputCursorPos = entry.name.count
                }
                renderStatusBar()
            }

        case .character("a"):
            enterInputMode(.createFile)

        case .character("A"):
            enterInputMode(.createDirectory)

        // Tabs
        case .character("t"):
            createTab()

        case .character("w"):
            closeTab()

        // Character ordering compares scalar sequences, so a keycap emoji
        // ("1" + VS16 + U+20E3) falls inside the "1"..."9" bounds while
        // carrying no asciiValue. The parser assembles it into one grapheme,
        // and isASCII rejects it here.
        case .character(let c) where c.isASCII && c >= "1" && c <= "9":
            guard let ascii = c.asciiValue else { break }
            switchTab(to: Int(ascii - 0x31))

        case .tab:
            switchTab(to: (activeTabIndex + 1) % tabs.count)

        case .shiftTab:
            switchTab(to: (activeTabIndex - 1 + tabs.count) % tabs.count)

        // SFTP connect — open new tab to remote host
        case .character("o"):
            enterInputMode(.sftpConnect)

        // Shell
        case .character(";"):
            if activeTab.dataSource.isRemote { break }  // No shell for remote tabs
            suspendToShell()
            return

        // Quit
        case .character("q"):
            quit()
            return

        case .character("Q"):
            quitWithCWD()
            return

        case .escape:
            // Escape clears search results if active, otherwise quits
            if activeTab.searchResults != nil {
                activeTab.searchResults = nil
                display.buffer.invalidate()
                fullRender()
                schedulePreview()
            } else {
                quit()
            }
            return

        case .ctrlC:
            quit()
            return

        // Refresh
        case .ctrlL:
            display.buffer.invalidate()
            performNavigation { [tab] in try await tab.refresh() }

        // Mouse
        case .mousePress(let button, let col, let row):
            handleMousePress(button: button, col: col, row: row)

        case .mouseRelease(_, let col, let row):
            handleMouseRelease(col: col, row: row)

        case .mouseMotion(_, let col, let row):
            handleMouseMotion(col: col, row: row)

        case .mouseScroll(let direction, let col, let row):
            handleMouseScroll(direction: direction, col: col, row: row)

        default:
            break
        }
    }

    // MARK: - Input Line Modes

    private func enterInputMode(_ mode: RFInputMode) {
        inputMode = mode
        inputBuffer = ""
        inputCursorPos = 0

        // Populate profile list when entering SFTP connect mode
        if mode == .sftpConnect {
            sftpProfileList = ConnectionProfileManager.shared.profiles
            if sftpProfileList.isEmpty {
                inputMode = .normal
                fullRender()
                return
            }
            sftpFilteredProfiles = sftpProfileList
            sftpPickerCursor = 0
            sftpPickerScroll = 0
            renderSftpPicker()
            return
        }

        renderStatusBar()
    }

    private func handleInputLineEvent(
        _ event: RFInputEvent,
        prompt: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        switch event {
        case .enter:
            onConfirm()
        case .escape, .ctrlC:
            onCancel()
        case .backspace:
            if inputCursorPos > 0 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos - 1)
                inputBuffer.remove(at: idx)
                inputCursorPos -= 1
            }
            if inputMode == .filter {
                activeTab.currentDir.filterText = inputBuffer.isEmpty ? nil : inputBuffer
                fullRender()
            }
            renderStatusBar()
        case .character(let c):
            insertAtCursor(c)
            if inputMode == .filter {
                activeTab.currentDir.filterText = inputBuffer
                fullRender()
            }
            renderStatusBar()
        case .arrowLeft(shift: false):
            inputCursorPos = max(0, inputCursorPos - 1)
            renderStatusBar()
        case .arrowRight(shift: false):
            inputCursorPos = min(inputBuffer.count, inputCursorPos + 1)
            renderStatusBar()
        case .ctrlU:
            inputBuffer = ""
            inputCursorPos = 0
            if inputMode == .filter {
                activeTab.currentDir.filterText = nil
                fullRender()
            }
            renderStatusBar()
        case .ctrlW:
            // Delete word backward
            deleteWordBackward()
            if inputMode == .filter {
                activeTab.currentDir.filterText = inputBuffer.isEmpty ? nil : inputBuffer
                fullRender()
            }
            renderStatusBar()
        case .ctrlA:
            inputCursorPos = 0
            renderStatusBar()
        case .ctrlE:
            inputCursorPos = inputBuffer.count
            renderStatusBar()
        default:
            break
        }
    }

    private func handleCdPathEvent(_ event: RFInputEvent) {
        switch event {
        case .tab:
            // Path completion (local only — remote would need async listing)
            if !activeTab.dataSource.isRemote {
                completePath()
            }
            renderStatusBar()
        default:
            handleInputLineEvent(event, prompt: "cd", onConfirm: confirmCdPath, onCancel: cancelInput)
        }
    }

    // MARK: - Input Confirmations

    private func confirmFilter() {
        // Keep filter active, return to normal mode
        inputMode = .normal
        fullRender()
    }

    private func cancelFilter() {
        activeTab.currentDir.filterText = nil
        inputMode = .normal
        fullRender()
    }

    private var searchTask: Task<Void, Never>?

    private func confirmSearch() {
        let query = inputBuffer
        inputMode = .normal
        guard !query.isEmpty else {
            fullRender()
            return
        }

        fullRender()

        let dir = activeTab.currentDir.path
        searchTask?.cancel()
        searchTask = Task.detached { [weak self] in
            let results = await RFSearch.search(query: query, directory: dir)
            guard !Task.isCancelled else { return }

            // Build entries from search result paths (off main thread)
            var entries: [RFEntry] = []
            for path in results {
                let name = (path as NSString).lastPathComponent
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                guard exists else { continue }
                entries.append(RFEntry(
                    name: name, path: path,
                    isDirectory: isDir.boolValue, isSymlink: false,
                    isHidden: name.hasPrefix("."), isExecutable: false,
                    size: 0, modifiedDate: nil, gitStatus: nil
                ))
            }

            let foundEntries = entries
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                // Create a virtual directory from search results
                let searchDir = RFDirectory(path: dir)
                searchDir.allEntries = foundEntries
                self.activeTab.searchResults = searchDir
                self.fullRender()
                self.schedulePreview()
            }
        }
    }

    private func cancelSearch() {
        activeTab.searchResults = nil
        inputMode = .normal
        fullRender()
        schedulePreview()
    }

    private func confirmRename() {
        guard case .rename(let original) = inputMode else { return }
        let newName = inputBuffer
        inputMode = .normal
        guard !newName.isEmpty, newName != original else {
            fullRender()
            return
        }

        let ds = activeTab.dataSource
        let dir = activeTab.currentDir.path
        let oldPath = ds.joinPath(dir, original)
        let newPath = ds.joinPath(dir, newName)

        let tab = activeTab
        performNavigation {
            try await ds.rename(from: oldPath, to: newPath)
            try await tab.refresh()
            tab.currentDir.jumpToName(newName, visibleCount: 1000)
        }
    }

    private func confirmCreateFile() {
        let name = inputBuffer
        inputMode = .normal
        guard !name.isEmpty else {
            fullRender()
            return
        }

        let tab = activeTab
        let ds = tab.dataSource
        let path = ds.joinPath(tab.currentDir.path, name)
        performNavigation {
            try await ds.createFile(at: path)
            try await tab.refresh()
            tab.currentDir.jumpToName(name, visibleCount: 1000)
        }
    }

    private func confirmCreateDir() {
        let name = inputBuffer
        inputMode = .normal
        guard !name.isEmpty else {
            fullRender()
            return
        }

        let tab = activeTab
        let ds = tab.dataSource
        let path = ds.joinPath(tab.currentDir.path, name)
        performNavigation {
            try await ds.createDirectory(at: path)
            try await tab.refresh()
            tab.currentDir.jumpToName(name, visibleCount: 1000)
        }
    }

    private func confirmCdPath() {
        var path = inputBuffer
        inputMode = .normal
        guard !path.isEmpty else {
            fullRender()
            return
        }

        let tab = activeTab
        let ds = tab.dataSource

        if ds.isRemote {
            // Remote: resolve path using SFTP semantics, navigate directly
            // (the async navigateTo will fail gracefully if path doesn't exist)
            if !path.hasPrefix("/") {
                path = ds.joinPath(tab.currentDir.path, path)
            }
            performNavigation { try await tab.navigateTo(path: path, pushHistory: true) }
        } else {
            // Local: expand ~ and verify directory exists
            if path.hasPrefix("~") {
                let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
                path = home + path.dropFirst()
            }
            if !path.hasPrefix("/") {
                path = (tab.currentDir.path as NSString).appendingPathComponent(path)
            }
            path = (path as NSString).standardizingPath

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                performNavigation { try await tab.navigateTo(path: path, pushHistory: true) }
            } else {
                fullRender()
            }
        }
    }

    // MARK: - SFTP Connect (Profile Picker)

    /// Handle events in the SFTP profile picker mode.
    /// j/k or arrows navigate, typing filters, Enter selects, Escape cancels.
    private func handleSftpConnectEvent(_ event: RFInputEvent) {
        let vc = Int(display.layout.currentRegion.height)

        switch event {
        case .enter:
            guard !sftpFilteredProfiles.isEmpty,
                  sftpPickerCursor < sftpFilteredProfiles.count else {
                break
            }
            let profile = sftpFilteredProfiles[sftpPickerCursor]
            inputMode = .normal
            connectSFTPProfile(profile)
            return

        case .escape, .ctrlC:
            inputMode = .normal
            fullRender()
            schedulePreview()
            return

        case .character("j"), .arrowDown(shift: false):
            if sftpPickerCursor < sftpFilteredProfiles.count - 1 {
                sftpPickerCursor += 1
                adjustSftpPickerScroll(visibleCount: vc)
            }

        case .character("k"), .arrowUp(shift: false):
            if sftpPickerCursor > 0 {
                sftpPickerCursor -= 1
                adjustSftpPickerScroll(visibleCount: vc)
            }

        case .character("g"):
            sftpPickerCursor = 0
            sftpPickerScroll = 0

        case .character("G"):
            sftpPickerCursor = max(0, sftpFilteredProfiles.count - 1)
            adjustSftpPickerScroll(visibleCount: vc)

        case .pageDown:
            sftpPickerCursor = min(sftpFilteredProfiles.count - 1, sftpPickerCursor + vc)
            adjustSftpPickerScroll(visibleCount: vc)

        case .pageUp:
            sftpPickerCursor = max(0, sftpPickerCursor - vc)
            adjustSftpPickerScroll(visibleCount: vc)

        case .tab:
            // Tab completion: fill input with current selection name
            if !sftpFilteredProfiles.isEmpty, sftpPickerCursor < sftpFilteredProfiles.count {
                inputBuffer = sftpFilteredProfiles[sftpPickerCursor].name
                inputCursorPos = inputBuffer.count
                refilterSftpProfiles()
            }

        case .backspace:
            if inputCursorPos > 0 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos - 1)
                inputBuffer.remove(at: idx)
                inputCursorPos -= 1
                refilterSftpProfiles()
            }

        case .ctrlU:
            inputBuffer = ""
            inputCursorPos = 0
            refilterSftpProfiles()

        case .ctrlW:
            deleteWordBackward()
            refilterSftpProfiles()

        case .character(let c) where !c.isNewline:
            insertAtCursor(c)
            refilterSftpProfiles()

        default:
            break
        }

        renderSftpPicker()
    }

    /// Refilter the profile list based on current input text.
    private func refilterSftpProfiles() {
        let filter = inputBuffer.lowercased()
        if filter.isEmpty {
            sftpFilteredProfiles = sftpProfileList
        } else {
            sftpFilteredProfiles = sftpProfileList.filter {
                $0.name.lowercased().contains(filter) ||
                $0.sshConfig.host.lowercased().contains(filter) ||
                $0.sshConfig.username.lowercased().contains(filter)
            }
        }
        // Reset cursor if out of bounds
        sftpPickerCursor = min(sftpPickerCursor, max(0, sftpFilteredProfiles.count - 1))
        sftpPickerScroll = 0
    }

    /// Adjust scroll offset to keep cursor visible in the picker.
    private func adjustSftpPickerScroll(visibleCount: Int) {
        let scrolloff = 2
        if sftpPickerCursor < sftpPickerScroll + scrolloff {
            sftpPickerScroll = max(0, sftpPickerCursor - scrolloff)
        }
        if sftpPickerCursor >= sftpPickerScroll + visibleCount - scrolloff {
            sftpPickerScroll = max(0, sftpPickerCursor - visibleCount + scrolloff + 1)
        }
    }

    /// Render the SFTP profile picker into the current column + status bar.
    private func renderSftpPicker() {
        // Convert profiles to display entries for the file list renderer
        let entries: [RFDisplayEntry] = sftpFilteredProfiles.map { profile in
            let detail = "\(profile.sshConfig.username)@\(profile.sshConfig.host)"
            return RFDisplayEntry(
                name: profile.name,
                path: profile.id.uuidString,
                icon: "󰣀",
                iconColor: theme.directoryColor,
                color: theme.directoryColor,
                isDirectory: false,
                rightText: detail,
                rightColor: nil
            )
        }

        // Draw header
        display.drawHeader(path: "Select SFTP Profile", filterText: inputBuffer.isEmpty ? nil : inputBuffer)

        // Draw profiles in the current column using the existing file list renderer
        display.drawFileList(
            entries: entries,
            cursorIndex: sftpPickerCursor,
            scrollOffset: sftpPickerScroll,
            region: display.layout.currentRegion,
            isActive: true
        )

        // Clear preview and parent columns
        display.drawCenteredMessage("", region: display.layout.previewRegion)
        display.drawCenteredMessage("", region: display.layout.parentRegion)
        display.drawSeparators()

        display.render()

        // Status bar: show filter input
        let count = sftpFilteredProfiles.count
        let total = sftpProfileList.count
        let prompt = count == total ? "SFTP (\(total))" : "SFTP (\(count)/\(total))"
        display.drawInputLine(prompt: prompt, text: inputBuffer, cursorPos: inputCursorPos)
    }

    /// Connect to a profile via SFTP and open a new rf tab.
    /// Resolves saved passwords, prompts for password if needed, and validates host keys interactively.
    private func connectSFTPProfile(_ profile: ConnectionProfile) {
        let config = profile.sshConfig

        // If auth needs a password we don't have, prompt for it
        switch config.authMethod {
        case .savedPassword:
            // Try to resolve from Keychain first
            if SSHPasswordManager.shared.hasPassword(host: config.host, port: config.port, username: config.username) {
                // Have saved password — resolve and connect
                sftpPendingProfile = profile
                inputMode = .sftpConnecting
                sftpConnectError = nil
                fullRender()
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let resolved = try await config.resolvedConfig()
                        var updatedProfile = profile
                        updatedProfile.sshConfig = resolved
                        self.performSFTPConnect(updatedProfile)
                    } catch {
                        Self.logger.error("Failed to resolve saved password for \(config.host): \(error.localizedDescription)")
                        // Fall back to password prompt
                        self.sftpPendingProfile = profile
                        self.sftpPasswordBuffer = ""
                        self.inputMode = .sftpPassword
                        self.renderStatusBar()
                    }
                }
            } else {
                // No saved password — prompt
                sftpPendingProfile = profile
                sftpPasswordBuffer = ""
                inputMode = .sftpPassword
                fullRender()
            }

        case .password(let pwd) where pwd.isEmpty:
            // Empty password in profile — prompt
            sftpPendingProfile = profile
            sftpPasswordBuffer = ""
            inputMode = .sftpPassword
            fullRender()

        default:
            // Key auth, none auth, or password already inline — connect directly
            sftpPendingProfile = profile
            inputMode = .sftpConnecting
            sftpConnectError = nil
            fullRender()
            performSFTPConnect(profile)
        }
    }

    /// Perform the actual SFTP connection after auth is resolved.
    private func performSFTPConnect(_ profile: ConnectionProfile) {
        let dataSource = RFSFTPDataSource(config: profile.sshConfig)

        // Wire up interactive host key validation — prompt user in the rf TUI
        dataSource.onHostKeyValidation = { [weak self] request in
            guard let self else { return .reject }
            return await self.promptHostKeyValidation(request)
        }

        // Keyboard-interactive (2FA/OTP/PAM) prompts go to the shared sheet via
        // the owning local shell, not an rf TUI prompt.
        dataSource.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self, let handler = self.onKeyboardInteractiveChallenge else { return nil }
            return await handler(challenge)
        }

        let host = profile.sshConfig.host

        Task { [weak self] in
            guard let self else { return }
            do {
                try await dataSource.connect()
                guard !Task.isCancelled else { return }

                let homePath = try await dataSource.resolveHomePath()
                let newId = (self.tabs.map(\.id).max() ?? 0) + 1
                let tab = RFTab(id: newId, path: homePath, dataSource: dataSource)
                self.configureTabCallbacks(tab)
                try await tab.loadInitial()
                tab.showHidden = self.config.showHidden
                tab.sortOrder = self.config.sortBy

                self.sftpPendingProfile = nil
                self.sftpConnectError = nil
                self.tabs.append(tab)
                self.activeTabIndex = self.tabs.count - 1
                self.display.layout.showTabBar = self.tabs.count > 1
                self.inputMode = .normal
                self.fullRender()
                self.schedulePreview()
            } catch {
                dataSource.disconnect()
                Self.logger.error("SFTP connect to \(host) failed: \(error.localizedDescription)")
                self.sftpPendingProfile = nil
                self.sftpConnectError = error.localizedDescription
                self.inputMode = .normal
                self.fullRender()
            }
        }
    }

    /// Prompt user for host key validation via the rf TUI, using a checked continuation.
    private func promptHostKeyValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        return await withCheckedContinuation { continuation in
            sftpHostKeyContinuation = continuation
            sftpHostKeyMessage = request.message
            sftpHostKeyIsChanged = request.isKeyChanged
            inputBuffer = ""
            inputCursorPos = 0
            inputMode = .sftpHostKey
            fullRender()
        }
    }

    // MARK: - SFTP Host Key Prompt

    private func handleSftpHostKeyEvent(_ event: RFInputEvent) {
        switch event {
        case .enter:
            let response = inputBuffer.lowercased().trimmingCharacters(in: .whitespaces)
            let result: HostKeyValidationResult
            switch response {
            case "yes", "y":
                result = .accept
            case "once", "o":
                result = .acceptOnce
            default:
                result = .reject
            }
            inputBuffer = ""
            inputCursorPos = 0
            inputMode = .sftpConnecting
            renderStatusBar()
            let continuation = sftpHostKeyContinuation
            sftpHostKeyContinuation = nil
            sftpHostKeyMessage = ""
            continuation?.resume(returning: result)

        case .escape, .ctrlC:
            inputBuffer = ""
            inputCursorPos = 0
            inputMode = .sftpConnecting
            renderStatusBar()
            let continuation = sftpHostKeyContinuation
            sftpHostKeyContinuation = nil
            sftpHostKeyMessage = ""
            continuation?.resume(returning: .reject)

        case .backspace:
            if inputCursorPos > 0 {
                let idx = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos - 1)
                inputBuffer.remove(at: idx)
                inputCursorPos -= 1
                renderStatusBar()
            }

        case .character(let c):
            insertAtCursor(c)
            renderStatusBar()

        default:
            break
        }
    }

    // MARK: - SFTP Password Prompt

    private func handleSftpPasswordEvent(_ event: RFInputEvent) {
        switch event {
        case .enter:
            guard let profile = sftpPendingProfile else {
                inputMode = .normal
                fullRender()
                return
            }
            let password = sftpPasswordBuffer
            sftpPasswordBuffer = ""

            // Build config with the entered password
            var updatedProfile = profile
            updatedProfile.sshConfig.authMethod = .password(password)

            inputMode = .sftpConnecting
            sftpConnectError = nil
            fullRender()
            performSFTPConnect(updatedProfile)

        case .escape, .ctrlC:
            sftpPasswordBuffer = ""
            sftpPendingProfile = nil
            inputMode = .normal
            fullRender()
            schedulePreview()

        case .backspace:
            if !sftpPasswordBuffer.isEmpty {
                sftpPasswordBuffer.removeLast()
                renderStatusBar()
            }

        case .character(let c):
            if !c.isNewline {
                sftpPasswordBuffer.append(c)
                // No echo — just update the asterisk count
                renderStatusBar()
            }

        default:
            break
        }
    }

    private func cancelInput() {
        inputMode = .normal
        sftpConnectError = nil
        fullRender()
    }

    // MARK: - Bookmark Events

    private func handleBookmarkSetEvent(_ event: RFInputEvent) {
        if case .character(let c) = event, c.isLetter {
            activeTab.bookmarks[c] = activeTab.currentDir.path
        }
        inputMode = .normal
        renderStatusBar()
    }

    private func handleBookmarkJumpEvent(_ event: RFInputEvent) {
        inputMode = .normal
        if case .character(let c) = event {
            if c == "'" {
                if let prev = activeTab.previousPath {
                    performNavigation { [self] in try await self.activeTab.navigateTo(path: prev, pushHistory: true) }
                }
            } else if c.isLetter, let path = activeTab.bookmarks[c] {
                performNavigation { [self] in try await self.activeTab.navigateTo(path: path, pushHistory: true) }
            }
        }
    }

    // MARK: - Copy Chord (cc/cd/cf/cn)

    private func handleCopyChordEvent(_ event: RFInputEvent) {
        inputMode = .normal

        guard let entry = activeDir.hoveredEntry else {
            renderStatusBar()
            return
        }

        let textToCopy: String?
        switch event {
        case .character("c"):
            // cc — copy full path
            textToCopy = entry.path
        case .character("d"):
            // cd — copy directory path
            textToCopy = (entry.path as NSString).deletingLastPathComponent
        case .character("f"):
            // cf — copy filename (with extension)
            textToCopy = entry.name
        case .character("n"):
            // cn — copy filename without extension
            let name = entry.name
            if let dotRange = name.range(of: ".", options: .backwards), dotRange.lowerBound != name.startIndex {
                textToCopy = String(name[..<dotRange.lowerBound])
            } else {
                textToCopy = name
            }
        default:
            textToCopy = nil
        }

        if let text = textToCopy {
            UIPasteboard.general.string = text
        }
        renderStatusBar()
    }

    // MARK: - Delete Confirmation

    private func handleDeleteConfirmEvent(_ event: RFInputEvent) {
        switch event {
        case .character("y"), .character("Y"):
            let tab = activeTab
            let paths = tab.operationPaths
            let ds = tab.dataSource
            inputMode = .normal
            tab.selected.removeAll()
            performNavigation {
                for path in paths {
                    try? await ds.delete(at: path)
                }
                try await tab.refresh()
            }

        default:
            inputMode = .normal
            fullRender()
        }
    }

    // MARK: - Croc Send Confirmation

    private func handleCrocSendConfirmEvent(_ event: RFInputEvent) {
        switch event {
        case .character("y"), .character("Y"):
            let paths = activeTab.operationPaths
            inputMode = .normal
            activeTab.clearSelection()
            suspendForCrocSend(paths: paths)

        default:
            inputMode = .normal
            fullRender()
        }
    }

    private func suspendForCrocSend(paths: [String]) {
        stopSpinner()
        previewTask?.cancel()
        fullHighlightTask?.cancel()
        deleteKittyImage()
        isOnScreen = false
        display.exitScreen()
        onCrocSend?(paths)
    }

    private func handlePasteOverwriteConfirmEvent(_ event: RFInputEvent) {
        switch event {
        case .character("y"), .character("Y"):
            inputMode = .normal
            pasteYank(force: true)

        default:
            inputMode = .normal
            fullRender()
        }
    }

    private func handleUploadFailedEvent(_ event: RFInputEvent) {
        guard let failed = failedUpload else {
            inputMode = .normal
            fullRender()
            return
        }

        switch event {
        case .character("r"), .character("R"):
            // Retry upload from recovery path
            inputMode = .normal
            let recoveryPath = failed.recoveryPath
            let remotePath = failed.remotePath
            let ds = failed.dataSource
            let host = failed.host
            failedUpload = nil
            fullRender()

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await ds.uploadFromLocal(
                        localPath: recoveryPath,
                        remotePath: remotePath
                    ) { _ in }
                    // Success — clean up recovery file
                    try? FileManager.default.removeItem(atPath: recoveryPath)
                    Self.logger.info("Retry upload succeeded for \(remotePath)")
                    self.statusMessage = "Upload succeeded"
                } catch {
                    // Re-enter failed prompt
                    self.failedUpload = FailedRemoteUpload(
                        recoveryPath: recoveryPath,
                        remotePath: remotePath,
                        host: host,
                        dataSource: ds,
                        errorMessage: error.localizedDescription
                    )
                    self.inputMode = .uploadFailedPrompt
                }
                self.fullRender()
            }

        case .character("c"), .character("C"):
            // Copy recovery path to system clipboard
            UIPasteboard.general.string = failed.recoveryPath
            inputMode = .normal
            failedUpload = nil
            statusMessage = "Recovery path copied to clipboard"
            fullRender()

        default:
            // Dismiss — file stays in recovery dir
            let path = failed.recoveryPath
            inputMode = .normal
            failedUpload = nil
            statusMessage = "Edits saved: \(path)"
            fullRender()
        }
    }

    // MARK: - Visual Select

    private func handleVisualEvent(_ event: RFInputEvent) {
        let tab = activeTab
        let vc = Int(display.layout.currentRegion.height)
        let isSelect = (inputMode == .visualSelect)

        switch event {
        case .character("j"), .arrowDown(shift: false):
            tab.currentDir.moveCursor(delta: 1, visibleCount: vc)
            updateVisualSelection(isSelect: isSelect)
            renderCurrentColumn()

        case .character("k"), .arrowUp(shift: false):
            tab.currentDir.moveCursor(delta: -1, visibleCount: vc)
            updateVisualSelection(isSelect: isSelect)
            renderCurrentColumn()

        case .escape, .ctrlC:
            inputMode = .normal
            renderCurrentColumn()

        default:
            break
        }
    }

    private func updateVisualSelection(isSelect: Bool) {
        let tab = activeTab
        let start = min(visualAnchor, tab.currentDir.cursor)
        let end = max(visualAnchor, tab.currentDir.cursor)
        let entries = tab.currentDir.visibleEntries
        for i in start...end where i < entries.count {
            let path = entries[i].path
            if isSelect {
                tab.selected.insert(path)
            } else {
                tab.selected.remove(path)
            }
        }
    }

    // MARK: - File Operations

    private func yankSelected(cut: Bool) {
        let paths = activeTab.operationPaths
        guard !paths.isEmpty else { return }
        let ds = activeTab.dataSource
        yankClipboard = RFYankClipboard(
            paths: paths, isCut: cut,
            source: ds as? RFLocalDataSource,
            sourceRemote: ds as? RFSFTPDataSource
        )
        Self.sharedYankClipboard = yankClipboard
        fullRender()
    }

    /// Shared clipboard across RFCommand instances (for cross-terminal-tab yank/paste).
    private static var sharedYankClipboard: RFYankClipboard?
    private var pasteTask: Task<Void, Never>?

    /// Split a filename into (stem, ext) for copy-suffix insertion.
    /// `ext` includes the leading dot, or is "" when there's no extension.
    /// A leading-dot name (".bashrc") is treated as all-stem, no ext.
    private func splitNameForCopySuffix(_ name: String) -> (stem: String, ext: String) {
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return (String(name[..<dot]), String(name[dot...]))
        }
        return (name, "")
    }

    /// Finder-style unique name in `dir`: "name copy.ext", "name copy 2.ext", …
    private func uniqueCopyName(in dir: String, baseName: String,
                                dataSource: any RFDataSource) async -> String {
        let (stem, ext) = splitNameForCopySuffix(baseName)
        var i = 1
        while i < 10_000 {  // safety cap; effectively unbounded
            let suffix = i == 1 ? " copy" : " copy \(i)"
            let candidate = stem + suffix + ext
            if !(await dataSource.fileExists(at: dataSource.joinPath(dir, candidate))) {
                return candidate
            }
            i += 1
        }
        return stem + " copy " + UUID().uuidString + ext  // last-resort fallback
    }

    private func pasteYankWithConflictCheck() {
        let yank = yankClipboard ?? Self.sharedYankClipboard
        guard let yank else { return }
        let tab = activeTab
        let destDataSource = tab.dataSource
        let destDir = tab.currentDir.path

        Task { [weak self] in
            guard let self else { return }
            var hasConflict = false
            for srcPath in yank.paths {
                let name = (srcPath as NSString).lastPathComponent
                let destPath = destDataSource.joinPath(destDir, name)
                // Pasting onto the source file itself isn't a real conflict — it
                // auto-duplicates (copy) or no-ops (cut), so don't prompt overwrite.
                // Compare by location, not identity: two tabs on the same host (or
                // two local tabs) are distinct objects but the same filesystem.
                let isSelfPaste = (yank.sourceDataSource?.isSameLocation(as: destDataSource) ?? false)
                    && srcPath == destPath
                if isSelfPaste { continue }
                if await destDataSource.fileExists(at: destPath) {
                    hasConflict = true
                    break
                }
            }

            if hasConflict {
                self.inputMode = .pasteOverwriteConfirm
                self.renderStatusBar()
            } else {
                self.pasteYank(force: false)
            }
        }
    }

    private func pasteYank(force: Bool) {
        let yank = yankClipboard ?? Self.sharedYankClipboard
        guard let yank else { return }
        let tab = activeTab
        let destDataSource = tab.dataSource
        let destDir = tab.currentDir.path
        let srcDataSource = yank.sourceDataSource

        if tab.dataSource.isRemote || (srcDataSource?.isRemote ?? false) {
            let noun = yank.paths.count == 1 ? "item" : "items"
            tab.activityMessage = "Pasting \(yank.paths.count) \(noun)..."
            renderStatusBar()
        }

        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            for srcPath in yank.paths {
                guard !Task.isCancelled else { break }
                let name = (srcPath as NSString).lastPathComponent
                let destPath = destDataSource.joinPath(destDir, name)

                do {
                    let sameSource = srcDataSource === destDataSource
                    let srcIsRemote = srcDataSource?.isRemote ?? false
                    let destIsRemote = destDataSource.isRemote

                    // Pasting onto the source file itself: a cut is a no-op, a copy
                    // duplicates under a Finder-style "name copy" name. Never let the
                    // force path remove-then-fail and destroy the original. Compare by
                    // location, not identity — two tabs on the same host (or two local
                    // tabs) are distinct objects pointing at the same filesystem, and a
                    // cut there would otherwise fall into the cross-source branch and
                    // delete the file.
                    let isSelfPaste = (srcDataSource?.isSameLocation(as: destDataSource) ?? false)
                        && srcPath == destPath
                    if isSelfPaste {
                        if yank.isCut {
                            continue
                        }
                        guard let dupName = await self?.uniqueCopyName(in: destDir, baseName: name,
                                                                      dataSource: destDataSource) else { break }
                        let dupDest = destDataSource.joinPath(destDir, dupName)
                        try await destDataSource.copyFile(sourcePath: srcPath, destPath: dupDest, force: false)
                        continue
                    }

                    if sameSource {
                        if yank.isCut {
                            try await destDataSource.moveFile(sourcePath: srcPath, destPath: destPath, force: force)
                        } else {
                            try await destDataSource.copyFile(sourcePath: srcPath, destPath: destPath, force: force)
                        }
                    } else if !srcIsRemote && destIsRemote {
                        if force { try? await destDataSource.delete(at: destPath) }
                        try await destDataSource.uploadFromLocal(localPath: srcPath, remotePath: destPath) { _ in }
                        // Only delete source after successful transfer, and only if not cancelled
                        if yank.isCut, !Task.isCancelled { try? FileManager.default.removeItem(atPath: srcPath) }
                    } else if srcIsRemote && !destIsRemote {
                        if force, FileManager.default.fileExists(atPath: destPath) {
                            try FileManager.default.removeItem(atPath: destPath)
                        }
                        guard let srcDS = srcDataSource else { continue }
                        try await srcDS.downloadToLocal(remotePath: srcPath, localPath: destPath) { _ in }
                        if yank.isCut, !Task.isCancelled { try? await srcDS.delete(at: srcPath) }
                    } else {
                        let tempPath = NSTemporaryDirectory() + UUID().uuidString
                        defer { try? FileManager.default.removeItem(atPath: tempPath) }
                        guard let srcDS = srcDataSource else { continue }
                        try await srcDS.downloadToLocal(remotePath: srcPath, localPath: tempPath) { _ in }
                        if force { try? await destDataSource.delete(at: destPath) }
                        try await destDataSource.uploadFromLocal(localPath: tempPath, remotePath: destPath) { _ in }
                        if yank.isCut, !Task.isCancelled { try? await srcDS.delete(at: srcPath) }
                    }
                } catch {
                    Self.logger.error("Paste failed for \(name): \(error.localizedDescription)")
                }
            }

            guard let self, !Task.isCancelled else { return }
            tab.activityMessage = nil
            if yank.isCut {
                self.yankClipboard = nil
                Self.sharedYankClipboard = nil
            }
            try? await tab.refresh()
            self.fullRender()
        }
    }

    // MARK: - Tabs

    private func createTab() {
        guard tabs.count < 9 else { return }

        if activeTab.dataSource.isRemote {
            // Remote: create an independent SFTP connection for the new tab
            guard let sftpDS = activeTab.dataSource as? RFSFTPDataSource else { return }
            let path = activeTab.currentDir.path
            Task { [weak self] in
                guard let self else { return }
                let newDS = RFSFTPDataSource(config: sftpDS.config)
                newDS.onHostKeyValidation = sftpDS.onHostKeyValidation
                newDS.onKeyboardInteractiveChallenge = sftpDS.onKeyboardInteractiveChallenge
                do {
                    try await newDS.connect()
                let newId = (self.tabs.map(\.id).max() ?? 0) + 1
                let tab = RFTab(id: newId, path: path, dataSource: newDS)
                self.configureTabCallbacks(tab)
                try await tab.loadInitial()
                tab.showHidden = self.config.showHidden
                tab.sortOrder = self.config.sortBy
                    self.tabs.append(tab)
                    self.activeTabIndex = self.tabs.count - 1
                    self.display.layout.showTabBar = self.tabs.count > 1
                    self.fullRender()
                    self.schedulePreview()
                } catch {
                    newDS.disconnect()
                    Self.logger.error("Failed to create remote tab: \(error.localizedDescription)")
                }
            }
        } else {
            let newId = (tabs.map(\.id).max() ?? 0) + 1
            let tab = RFTab(id: newId, path: activeTab.currentDir.path, dataSource: activeTab.dataSource)
            tab.showHidden = config.showHidden
            tab.sortOrder = config.sortBy
            tab.rootPath = config.rootPath
            configureTabCallbacks(tab)
            tabs.append(tab)
            activeTabIndex = tabs.count - 1
            display.layout.showTabBar = tabs.count > 1
            fullRender()
            schedulePreview()
        }
    }

    private func closeTab() {
        guard tabs.count > 1 else { return }
        // Delete kitty image from closing tab before removing it
        deleteKittyImage()
        // Clean up SFTP connections and temp files
        let closingTab = tabs[activeTabIndex]
        closingTab.dataSource.cleanupTempFiles()
        if let sftpDS = closingTab.dataSource as? RFSFTPDataSource {
            sftpDS.disconnect()
        }
        tabs.remove(at: activeTabIndex)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        }
        display.layout.showTabBar = tabs.count > 1
        fullRender()
        schedulePreview()
    }

    private func switchTab(to index: Int) {
        guard index >= 0, index < tabs.count, index != activeTabIndex else { return }
        // Delete kitty image from previous tab before switching
        deleteKittyImage()
        activeTabIndex = index
        fullRender()
        schedulePreview()
    }

    // MARK: - Mouse

    private func handleMousePress(button: RFMouseButton, col: Int, row: Int) {
        let hit = display.layout.hitTest(row: row, col: col)

        switch hit {
        case .separator(let idx):
            isDragging = true
            dragSeparatorIndex = idx
            return

        case .tabBar:
            // Find which tab was clicked
            handleTabBarClick(col: col)
            return

        case .parentColumn:
            if button == .left {
                let relRow = display.layout.parentRegion.relativeRow(row)
                let entryIdx = (activeTab.parentDir?.scrollOffset ?? 0) + relRow
                if let parent = activeTab.parentDir,
                   entryIdx < parent.visibleEntries.count {
                    let entry = parent.visibleEntries[entryIdx]
                    if entry.isDirectory {
                        performNavigation { [self] in try await self.activeTab.navigateTo(path: entry.path, pushHistory: true) }
                    }
                }
            }

        case .currentColumn:
            if button == .left {
                let relRow = display.layout.currentRegion.relativeRow(row)
                let entryIdx = activeTab.currentDir.scrollOffset + relRow
                let vc = Int(display.layout.currentRegion.height)

                // Double-click detection
                let now = Date()
                if now.timeIntervalSince(lastClickTime) < 0.4,
                   lastClickRow == row, lastClickCol == col {
                    // Double-click: enter directory or open file
                    if let entry = activeTab.currentDir.hoveredEntry {
                        if entry.isDirectory {
                            performNavigation { [self] in try await self.activeTab.enter(entry: entry) }
                        } else if activeTab.dataSource.isRemote {
                            openRemoteInEditor(entry)
                        } else {
                            openInEditor(entry.path)
                        }
                    }
                    lastClickTime = .distantPast
                } else {
                    // Single click: select
                    activeTab.currentDir.jumpTo(index: entryIdx, visibleCount: vc)
                    renderCurrentColumn()
                    schedulePreview()
                    lastClickTime = now
                    lastClickRow = row
                    lastClickCol = col
                }
            }

        case .previewColumn:
            // Click in preview of a directory: enter it
            if button == .left, let entry = activeTab.currentDir.hoveredEntry, entry.isDirectory {
                performNavigation { [self] in try await self.activeTab.enter(entry: entry) }
            }

        default:
            break
        }
    }

    private func handleMouseRelease(col: Int, row: Int) {
        isDragging = false
        dragSeparatorIndex = -1
    }

    private func handleMouseMotion(col: Int, row: Int) {
        hoverCol = col
        hoverRow = row

        if isDragging, dragSeparatorIndex >= 0 {
            display.layout.moveSeparator(index: dragSeparatorIndex, toCol: col)
            fullRender()
        }
    }

    private func handleMouseScroll(direction: RFScrollDirection, col: Int, row: Int) {
        let delta = direction == .up ? -1 : 1
        let hit = display.layout.hitTest(row: row, col: col)
        let vc = Int(display.layout.currentRegion.height)

        switch hit {
        case .parentColumn:
            activeTab.parentDir?.scroll(delta: delta, visibleCount: vc)
            renderParentColumn()

        case .currentColumn:
            activeTab.currentDir.moveCursor(delta: delta, visibleCount: vc)
            renderCurrentColumn()
            schedulePreview()

        case .previewColumn:
            scrollPreview(delta: delta)

        default:
            break
        }
    }

    private func handleTabBarClick(col: Int) {
        // Approximate tab positions: each tab is about ~12 chars wide
        // More precise: reconstruct tab label widths
        var x = 0
        for (i, tab) in tabs.enumerated() {
            let label = " \(i + 1):\(tab.displayName) "
            let nextX = x + label.count
            if col >= x, col < nextX {
                switchTab(to: i)
                return
            }
            x = nextX
        }
    }

    // MARK: - Preview

    /// Background task for full-file highlighting (Phase 3).
    private var fullHighlightTask: Task<Void, Never>?

    /// Scroll preview by delta lines. Instant — pure array slicing from cache.
    private func scrollPreview(delta: Int) {
        let tab = activeTab
        guard let cache = tab.previewCache else { return }
        let height = display.layout.previewRegion.height
        let maxSkip = max(0, cache.allCells.count - height)
        tab.previewSkip = max(0, min(tab.previewSkip + delta, maxSkip))
        applyPreviewWindow()
    }

    /// Slice the cached preview cells for the current scroll offset and render.
    private func applyPreviewWindow() {
        let tab = activeTab
        guard let cache = tab.previewCache else { return }
        let height = display.layout.previewRegion.height
        let start = max(0, min(tab.previewSkip, cache.allCells.count - height))
        let end = min(max(0, start) + height, cache.allCells.count)
        let window = Array(cache.allCells[max(0, start)..<end])
        tab.previewState = .text(cells: window, totalLines: cache.totalLines)
        renderPreviewColumn()
    }

    /// Schedule preview loading. Three phases:
    /// 1. Plain text — instant display (~1ms)
    /// 2. Quick highlight — bat --line-range for visible window, fast swap
    /// 3. Full highlight — bat for entire file in background, seamless replace
    func schedulePreview() {
        previewTask?.cancel()
        fullHighlightTask?.cancel()

        // Delete any kitty image overlay before changing preview
        deleteKittyImage()
        expectedImagePath = nil

        guard let entry = activeDir.hoveredEntry else {
            activeTab.previewState = .none
            activeTab.previewCache = nil
            renderPreviewColumn()
            return
        }

        // If we already have cached cells for this file, just window them
        if let cache = activeTab.previewCache, cache.path == entry.path {
            applyPreviewWindow()
            return
        }

        // New file — reset scroll and cache
        activeTab.previewSkip = 0
        activeTab.previewCache = nil

        // Remote data source: use SFTP-based preview with debounce
        if activeTab.dataSource.isRemote {
            scheduleRemotePreview(entry: entry)
            return
        }

        if entry.isDirectory {
            let entries = RFEntry.loadDirectory(at: entry.path)
            let sorted = RFEntry.sorted(entries, by: activeTab.sortOrder)
            let visible = activeTab.showHidden ? sorted : sorted.filter { !$0.isHidden }
            activeTab.previewState = .directory(entries: visible)
            renderPreviewColumn()
            return
        }

        let ext = (entry.name as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "heic", "ico"]

        if imageExts.contains(ext) {
            activeTab.previewState = .image(path: entry.path)
            renderPreviewColumn()
            let imgPath = entry.path
            expectedImagePath = imgPath
            let imgCols = display.layout.previewRegion.width
            let imgRows = display.layout.previewRegion.height
            previewTask = Task.detached { [weak self] in
                let seq = RFPreview.loadImagePreview(path: imgPath, cols: imgCols, rows: imgRows)
                guard !Task.isCancelled, let seq else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    guard self.expectedImagePath == imgPath else { return }
                    // Delete any stale overlay before placing the new one
                    self.deleteKittyImage()
                    let region = self.display.layout.previewRegion
                    let posSeq = "\u{1b}[\(region.row + 1);\(region.col + 1)H"
                    self.onOutput?(Data((posSeq + seq).utf8))
                }
            }
            return
        }

        // JSON file preview — jq pretty-print with color
        let jsonExts: Set<String> = ["json", "geojson", "har"]
        if jsonExts.contains(ext) && entry.size <= RFPreview.maxJqFileSize && !isBinaryFile(at: entry.path) {
            let path = entry.path
            let width = display.layout.previewRegion.width
            let fileSize = entry.size

            activeTab.previewState = .loading
            renderPreviewColumn()

            previewTask = Task.detached { [weak self] in
                // Phase 1: plain text — fast direct file read for instant feedback
                let (plainCells, totalLines) = RFPreview.loadFilePreview(path: path, width: width)
                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    self.activeTab.previewCache = RFPreviewCache(
                        path: path, allCells: plainCells, totalLines: totalLines
                    )
                    self.applyPreviewWindow()
                }

                // Phase 2: jq pretty-print — replaces entire cache
                let jqCells = await RFPreview.loadJqPreview(
                    path: path, width: width
                )
                guard !Task.isCancelled else { return }

                if let jqCells, !jqCells.isEmpty {
                    // jq succeeded — replace cache with pretty-printed output
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        guard self.activeTab.previewCache?.path == path else { return }
                        let skip = self.activeTab.previewSkip
                        self.activeTab.previewCache = RFPreviewCache(
                            path: path, allCells: jqCells, totalLines: jqCells.count
                        )
                        self.activeTab.previewSkip = min(skip, max(0, jqCells.count - self.display.layout.previewRegion.height))
                        self.applyPreviewWindow()
                    }
                } else {
                    // jq failed (malformed JSON) — fall back to bat highlighting
                    guard !Task.isCancelled, fileSize <= RFPreview.maxBatFileSize else { return }
                    let batCells = await RFPreview.loadBatPreviewRange(
                        path: path, width: width,
                        startLine: 1, endLine: totalLines
                    )
                    guard !Task.isCancelled, !batCells.isEmpty else { return }

                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        guard self.activeTab.previewCache?.path == path else { return }
                        let skip = self.activeTab.previewSkip
                        self.activeTab.previewCache = RFPreviewCache(
                            path: path, allCells: batCells, totalLines: batCells.count
                        )
                        self.activeTab.previewSkip = min(skip, max(0, batCells.count - self.display.layout.previewRegion.height))
                        self.applyPreviewWindow()
                    }
                }
            }
            return
        }

        if isBinaryFile(at: entry.path) {
            activeTab.previewState = .binary(size: entry.size)
            renderPreviewColumn()
            return
        }

        // Text file preview — three phases:
        // 1. Plain text direct read (~1ms) — show immediately
        // 2. Quick bat highlight for visible window — fast swap
        // 3. Full bat highlight in background — seamless replace when done
        // Large files (>1MB) skip bat entirely — syntect parses sequentially from
        // file start even with --line-range, making large files too slow.
        let path = entry.path
        let width = display.layout.previewRegion.width
        let height = display.layout.previewRegion.height
        let fileSize = entry.size
        let skipBat = fileSize > RFPreview.maxBatFileSize

        activeTab.previewState = .loading
        renderPreviewColumn()

        previewTask = Task.detached { [weak self] in
            // Phase 1: plain text — fast direct file read
            let (plainCells, totalLines) = RFPreview.loadFilePreview(path: path, width: width)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.activeTab.previewCache = RFPreviewCache(
                    path: path, allCells: plainCells, totalLines: totalLines
                )
                self.applyPreviewWindow()
            }

            // Skip bat for large files — plain text only
            guard !skipBat else { return }

            // Phase 2: quick highlight — just visible window via --line-range
            let quickCells = await RFPreview.loadBatPreviewRange(
                path: path, width: width,
                startLine: 1, endLine: height + 10
            )
            guard !Task.isCancelled, !quickCells.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.activeTab.previewCache?.path == path else { return }
                // Replace just the visible portion in the plain cells array
                var cells = self.activeTab.previewCache!.allCells
                let replaceEnd = min(quickCells.count, cells.count)
                for i in 0..<replaceEnd {
                    cells[i] = quickCells[i]
                }
                self.activeTab.previewCache = RFPreviewCache(
                    path: path, allCells: cells, totalLines: totalLines
                )
                self.applyPreviewWindow()
            }

            // Phase 3: full file highlight in background — seamless replace
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.startFullHighlight(path: path, width: width, totalLines: totalLines)
            }
        }
    }

    /// Start full-file bat highlighting in the background.
    /// When complete, swaps in the full highlighted cache for smooth scrolling.
    /// `localPath` overrides the file bat reads from (used for remote files downloaded to temp).
    /// The cache is always keyed on `path` (the logical path shown to the user).
    private func startFullHighlight(path: String, width: Int, totalLines: Int, localPath: String? = nil) {
        fullHighlightTask?.cancel()
        let batPath = localPath ?? path
        fullHighlightTask = Task.detached { [weak self] in
            let fullCells = await RFPreview.loadBatPreviewRange(
                path: batPath, width: width,
                startLine: 1, endLine: totalLines
            )
            guard !Task.isCancelled, !fullCells.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.activeTab.previewCache?.path == path else { return }
                let skip = self.activeTab.previewSkip
                self.activeTab.previewCache = RFPreviewCache(
                    path: path, allCells: fullCells, totalLines: fullCells.count
                )
                self.activeTab.previewSkip = min(skip, max(0, fullCells.count - self.display.layout.previewRegion.height))
                self.applyPreviewWindow()
            }
        }
    }

    /// Delete any kitty graphics overlay. Always sent unconditionally —
    /// the delete is a no-op if no image exists, and skipping it risks
    /// ghost overlays when state transitions outrace inflight image tasks.
    private func deleteKittyImage() {
        // q=2 suppresses the APC reply, which would otherwise come back on the
        // input stream and be read as keystrokes.
        onOutput?(Data("\u{1b}_Ga=d,d=I,i=31,q=2;\u{1b}\\".utf8))
    }

    private func isBinaryFile(at path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { fh.closeFile() }
        let data = fh.readData(ofLength: 512)
        return data.contains(0)
    }

    /// SHA256 hash of a file's contents for change detection.
    private static func sha256OfFile(atPath path: String) -> Data {
        guard let fh = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    /// Copy an edited temp file to a durable recovery location in Documents.
    /// Returns the recovery path (or the original temp path if copy fails).
    private static func saveToRecovery(tempPath: String, remotePath: String, host: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recoveryDir = docs.appendingPathComponent(".rf-recovery")
        try? FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sanitizedHost = host.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let filename = (remotePath as NSString).lastPathComponent
        let recoveryName = "\(timestamp)_\(sanitizedHost)_\(filename)"
        let recoveryPath = recoveryDir.appendingPathComponent(recoveryName).path

        do {
            try FileManager.default.copyItem(atPath: tempPath, toPath: recoveryPath)
        } catch {
            // If copy fails (disk full?), keep the temp file as last resort
            logger.error("Failed to copy to recovery dir: \(error.localizedDescription)")
            return tempPath
        }

        return recoveryPath
    }

    /// Remove recovery files older than 30 days to prevent unbounded growth.
    private static func pruneOldRecoveryFiles() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recoveryDir = docs.appendingPathComponent(".rf-recovery")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: recoveryDir.path) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for file in files {
            let path = recoveryDir.appendingPathComponent(file).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified < cutoff {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Remote Preview

    /// Maximum file size for remote preview (10 MB for images, 1 MB for text).
    private static let remotePreviewMaxText = 1_048_576
    private static let remotePreviewMaxImage = 10 * 1_048_576
    private static let remotePreviewDebounceNs: UInt64 = 150_000_000  // 150ms

    /// Schedule a preview for a remote file entry.
    /// Includes debounce (150ms) and two-phase text loading.
    private func scheduleRemotePreview(entry: RFEntry) {
        let dataSource = activeTab.dataSource
        let path = entry.path
        let width = display.layout.previewRegion.width

        if entry.isDirectory {
            activeTab.previewState = .loading
            renderPreviewColumn()
            previewTask = Task { [weak self] in
                // Debounce
                try? await Task.sleep(nanoseconds: Self.remotePreviewDebounceNs)
                guard !Task.isCancelled else { return }

                let entries = try? await dataSource.loadDirectory(at: path)
                guard let self, !Task.isCancelled else { return }
                if let entries {
                    let sorted = RFEntry.sorted(entries, by: self.activeTab.sortOrder)
                    let visible = self.activeTab.showHidden ? sorted : sorted.filter { !$0.isHidden }
                    self.activeTab.previewState = .directory(entries: visible)
                } else {
                    self.activeTab.previewState = .error("Failed to list directory")
                }
                self.renderPreviewColumn()
            }
            return
        }

        let ext = (entry.name as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "heic", "ico"]

        // Large file gate
        if entry.size > Self.remotePreviewMaxImage {
            activeTab.previewState = .binary(size: entry.size)
            renderPreviewColumn()
            return
        }

        // Image preview: download to temp then use kitty protocol
        if imageExts.contains(ext) {
            activeTab.previewState = .loading
            renderPreviewColumn()
            let imgCols = display.layout.previewRegion.width
            let imgRows = display.layout.previewRegion.height
            expectedImagePath = path
            previewTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.remotePreviewDebounceNs)
                guard !Task.isCancelled else { return }

                guard let tempPath = try? await dataSource.downloadToTemp(
                    remotePath: path, maxBytes: nil
                ) else {
                    guard let self, !Task.isCancelled else { return }
                    self.activeTab.previewState = .error("Download failed")
                    self.renderPreviewColumn()
                    return
                }
                guard !Task.isCancelled else { return }

                let seq = await Task.detached {
                    RFPreview.loadImagePreview(path: tempPath, cols: imgCols, rows: imgRows)
                }.value
                guard let self, !Task.isCancelled, let seq else { return }
                guard self.expectedImagePath == path else { return }
                self.deleteKittyImage()
                self.activeTab.previewState = .image(path: path)
                self.renderPreviewColumn()
                let region = self.display.layout.previewRegion
                let posSeq = "\u{1b}[\(region.row + 1);\(region.col + 1)H"
                self.onOutput?(Data((posSeq + seq).utf8))
            }
            return
        }

        // Text preview: three-phase
        // 1. Download head → plain text (instant feedback)
        // 2. Download to temp → bat syntax highlight (full color)
        let fileSize = entry.size
        activeTab.previewState = .loading
        renderPreviewColumn()
        previewTask = Task { [weak self] in
            // Debounce
            try? await Task.sleep(nanoseconds: Self.remotePreviewDebounceNs)
            guard !Task.isCancelled else { return }

            // Phase 1: first 64KB for instant plain text display
            let phase1Max = 65_536
            guard let data = try? await dataSource.readFilePreview(at: path, maxBytes: phase1Max) else {
                guard let self, !Task.isCancelled else { return }
                self.activeTab.previewState = .error("Preview failed")
                self.renderPreviewColumn()
                return
            }
            guard let self, !Task.isCancelled else { return }

            // Binary detection
            if data.prefix(512).contains(0) {
                self.activeTab.previewState = .binary(size: entry.size)
                self.renderPreviewColumn()
                return
            }

            let (cells, totalLines) = RFPreview.loadPreviewFromData(data, width: width)
            self.activeTab.previewCache = RFPreviewCache(
                path: path, allCells: cells, totalLines: totalLines
            )
            self.applyPreviewWindow()

            // Phase 2: download to temp file → bat syntax highlighting
            guard fileSize <= RFPreview.maxBatFileSize else { return }
            guard !Task.isCancelled else { return }

            guard let tempPath = try? await dataSource.downloadToTemp(
                remotePath: path, maxBytes: Self.remotePreviewMaxText
            ) else { return }
            guard !Task.isCancelled else { return }
            guard self.activeTab.previewCache?.path == path else { return }

            // Run bat on the temp file — same as local preview
            self.startFullHighlight(path: path, width: width, totalLines: totalLines, localPath: tempPath)
        }
    }

    // MARK: - Git Status

    private var gitTask: Task<Void, Never>?

    /// Fetch git status for the active tab's current directory asynchronously.
    private func fetchGitStatus() {
        // Skip git status for remote data sources
        guard !activeTab.dataSource.isRemote else { return }
        gitTask?.cancel()
        let tabID = activeTab.id
        let dir = activeTab.currentDir.path
        gitTask = Task { [weak self] in
            let statusMap = RFGitStatusQuery.query(directory: dir)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                guard self.activeTab.id == tabID, self.activeTab.currentDir.path == dir else { return }
                self.activeTab.currentDir.applyGitStatus(statusMap)
                self.renderCurrentColumn()
            }
        }
    }

    // MARK: - Editor

    private func openInEditor(_ path: String) {
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "hx"
        stopSpinner()
        previewTask?.cancel()
        fullHighlightTask?.cancel()
        deleteKittyImage()
        isOnScreen = false
        display.exitScreen()
        onOpenEditor?(path, editor)
    }

    /// Download a remote file to temp, then open in the editor.
    /// On resume, `handlePostEditorReturn` detects changes and uploads.
    private func openRemoteInEditor(_ entry: RFEntry) {
        guard let sftpDS = activeTab.dataSource as? RFSFTPDataSource else { return }
        let remotePath = entry.path

        // Show downloading status before suspending rf
        activeTab.activityMessage = "Downloading \(entry.name)..."
        renderStatusBar()

        Task { [weak self] in
            guard let self else { return }
            do {
                let tempPath = try await sftpDS.downloadToTemp(remotePath: remotePath, maxBytes: nil)

                // Hash file content before editing for reliable change detection
                let preHash = Self.sha256OfFile(atPath: tempPath)

                self.pendingRemoteEdit = PendingRemoteEdit(
                    tempPath: tempPath,
                    remotePath: remotePath,
                    dataSource: sftpDS,
                    preEditHash: preHash
                )

                self.activeTab.activityMessage = nil
                self.openInEditor(tempPath)
            } catch {
                Self.logger.error("Download for edit failed: \(error.localizedDescription)")
                self.activeTab.activityMessage = nil
                self.statusMessage = "Download failed: \(error.localizedDescription)"
                self.fullRender()
            }
        }
    }

    /// Called after the editor exits. If a remote edit is pending, checks for
    /// changes and uploads the modified file. Rebuilds preview from the local
    /// copy before cleaning up the temp file.
    @discardableResult
    func handlePostEditorReturn(for tab: RFTab) async -> Bool {
        guard let edit = pendingRemoteEdit else { return true }
        pendingRemoteEdit = nil

        // Check if file content actually changed (SHA256 comparison)
        let postHash = Self.sha256OfFile(atPath: edit.tempPath)

        guard postHash != edit.preEditHash else {
            Self.logger.info("Remote edit: file unchanged, skipping upload")
            try? FileManager.default.removeItem(atPath: edit.tempPath)
            return true
        }

        // File was modified — upload back
        Self.logger.info("Remote edit: file changed, uploading to \(edit.remotePath)")
        tab.activityMessage = "Uploading \((edit.remotePath as NSString).lastPathComponent)..."
        renderStatusBar()
        do {
            try await edit.dataSource.uploadFromLocal(
                localPath: edit.tempPath,
                remotePath: edit.remotePath
            ) { _ in }
        } catch {
            // Save edited file to durable recovery location before temp cleanup can destroy it
            let host = edit.dataSource.connectionLabel
            let recoveryPath = Self.saveToRecovery(
                tempPath: edit.tempPath,
                remotePath: edit.remotePath,
                host: host
            )
            Self.logger.error("Remote edit upload failed, recovery saved at \(recoveryPath): \(error.localizedDescription)")

            failedUpload = FailedRemoteUpload(
                recoveryPath: recoveryPath,
                remotePath: edit.remotePath,
                host: host,
                dataSource: edit.dataSource,
                errorMessage: error.localizedDescription
            )
            inputMode = .uploadFailedPrompt
            fullRender()
            return false
        }

        // Rebuild preview cache from the local temp copy we already have,
        // avoiding a redundant network fetch
        if tab.previewCache?.path == edit.remotePath {
            let width = display.layout.previewRegion.width
            let (cells, totalLines) = RFPreview.loadFilePreview(path: edit.tempPath, width: width)
            tab.previewCache = RFPreviewCache(
                path: edit.remotePath, allCells: cells, totalLines: totalLines
            )
            tab.previewSkip = 0
        }

        // Only clean up temp file after successful upload + preview rebuild
        try? FileManager.default.removeItem(atPath: edit.tempPath)
        return true
    }

    func resumeAfterExternalEditor() {
        let tab = activeTab
        if pendingRemoteEdit != nil {
            tab.activityMessage = "Syncing edited file..."
        }

        start()

        Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            let shouldRefresh = await self.handlePostEditorReturn(for: tab)
            guard !Task.isCancelled else { return }

            if shouldRefresh {
                if tab.dataSource.isRemote {
                    tab.activityMessage = "Refreshing directory..."
                    self.renderStatusBar()
                }
                try? await tab.refresh()
            }

            guard !Task.isCancelled else { return }
            tab.activityMessage = nil
            self.fullRender()
            self.schedulePreview()
            self.fetchGitStatus()
        }
    }

    // MARK: - Quit

    private func quit() {
        shutdownAllTasks()
        isOnScreen = false
        display.exitScreen()
        onComplete?(nil)
    }

    private func quitWithCWD() {
        let dir = activeTab.currentDir.path
        shutdownAllTasks()
        isOnScreen = false
        display.exitScreen()
        onComplete?(dir)
    }

    /// Cancel all in-flight tasks and disconnect remote connections.
    /// Preserves any SFTP source referenced by the shared yank clipboard
    /// so cross-session paste remains functional.
    private func shutdownAllTasks() {
        stopSpinner()
        inputFlushTimer?.invalidate()
        inputFlushTimer = nil
        previewTask?.cancel()
        navigationTask?.cancel()
        fullHighlightTask?.cancel()
        pasteTask?.cancel()
        deleteKittyImage()
        let keepAlive = Self.sharedYankClipboard?.sourceRemote
        for tab in tabs {
            tab.dataSource.cleanupTempFiles()
            if let sftpDS = tab.dataSource as? RFSFTPDataSource, sftpDS !== keepAlive {
                sftpDS.disconnect()
            }
        }
    }

    private func suspendToShell() {
        stopSpinner()
        inputFlushTimer?.invalidate()
        inputFlushTimer = nil
        previewTask?.cancel()
        fullHighlightTask?.cancel()
        deleteKittyImage()
        isOnScreen = false
        display.exitScreen()
        onDropToShell?(activeTab.currentDir.path)
    }

    // MARK: - Rendering Helpers

    private func fullRender() {
        guard isOnScreen else { return }

        let tab = activeTab

        // Tab bar
        if tabs.count > 1 {
            let tabInfo = tabs.map { (id: $0.id, name: $0.displayName) }
            display.drawTabBar(tabs: tabInfo, activeIndex: activeTabIndex)
        }

        // Header — abbreviate home directory as ~
        let displayPath = abbreviateHome(tab.currentDir.path)
        let searchLabel = tab.searchResults != nil ? "[SEARCH] " : nil
        display.drawHeader(path: (searchLabel ?? "") + displayPath, filterText: tab.currentDir.filterText)

        // Parent column
        renderParentColumnInner()

        // Separators
        display.drawSeparators(hoverCol: hoverCol, isDragging: isDragging)

        // Current column
        renderCurrentColumnInner()

        // Preview — show host key details during host key prompt
        if inputMode == .sftpHostKey && !sftpHostKeyMessage.isEmpty {
            renderHostKeyMessage()
        } else {
            renderPreviewColumnInner()
        }

        // Status bar
        renderStatusBarInner()

        display.render()
    }

    /// Render host key fingerprint details in the preview column during validation prompt.
    private func renderHostKeyMessage() {
        let region = display.layout.previewRegion
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.bg))
        display.buffer.fill(row: region.row, col: region.col,
                            width: region.width, height: region.height, cell: bgCell)

        let lines = sftpHostKeyMessage.components(separatedBy: "\n")
        let warningStyle = TUIStyle(fg: theme.errorColor, bg: theme.bg, attrs: .bold)
        let normalStyle = TUIStyle(fg: theme.fg, bg: theme.bg)

        for (i, line) in lines.prefix(region.height).enumerated() {
            let row = region.row + i
            let style = (sftpHostKeyIsChanged && i == 0) ? warningStyle : normalStyle
            display.buffer.writeTruncated(row: row, col: region.col, line, style: style,
                                          maxWidth: region.width)
        }
    }

    private func renderCurrentColumn() {
        guard isOnScreen else { return }
        renderCurrentColumnInner()
        display.drawSeparators(hoverCol: hoverCol, isDragging: isDragging)
        renderStatusBarInner()
        display.render()
    }

    private func renderParentColumn() {
        guard isOnScreen else { return }
        renderParentColumnInner()
        display.render()
    }

    private func renderPreviewColumn() {
        guard isOnScreen else { return }
        renderPreviewColumnInner()
        display.render()
    }

    /// Start the spinner animation timer. Idempotent.
    private func startSpinner() {
        guard spinnerTimer == nil else { return }
        spinnerFrameIndex = 0
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.spinnerFrameIndex = (self.spinnerFrameIndex + 1) % Self.spinnerFrames.count
                self.renderStatusBar()
            }
        }
    }

    /// Stop the spinner animation timer.
    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinnerFrameIndex = 0
    }

    /// The current spinner character, or nil if not animating.
    private var spinnerChar: Character? {
        spinnerTimer != nil ? Self.spinnerFrames[spinnerFrameIndex] : nil
    }

    private func renderStatusBar() {
        guard isOnScreen else { return }
        renderStatusBarInner()
        display.render()
    }

    private func renderParentColumnInner() {
        let tab = activeTab
        if let parent = tab.parentDir {
            if tab.isParentLoading && parent.visibleEntries.isEmpty {
                display.drawCenteredMessage("Loading...", region: display.layout.parentRegion)
                return
            }
            parent.clampScroll(visibleCount: display.layout.parentRegion.height)
            let entries = parent.visibleEntries.map { $0.toDisplayEntry(theme: theme) }
            let currentDirName = (tab.currentDir.path as NSString).lastPathComponent
            display.drawFileList(
                entries: entries,
                cursorIndex: parent.cursor,
                scrollOffset: parent.scrollOffset,
                region: display.layout.parentRegion,
                isActive: false,
                highlightName: currentDirName
            )
        } else if tab.isParentLoading {
            display.drawCenteredMessage("Loading...", region: display.layout.parentRegion)
        } else {
            display.drawCenteredMessage("/", region: display.layout.parentRegion)
        }
    }

    private func renderCurrentColumnInner() {
        let tab = activeTab
        let dir = activeDir
        let yankInfo: (paths: Set<String>, isCut: Bool)? = yankClipboard.map {
            (paths: Set($0.paths), isCut: $0.isCut)
        }
        dir.clampScroll(visibleCount: display.layout.currentRegion.height)
        let entries = dir.visibleEntries.map { $0.toDisplayEntry(theme: theme) }
        display.drawFileList(
            entries: entries,
            cursorIndex: dir.cursor,
            scrollOffset: dir.scrollOffset,
            region: display.layout.currentRegion,
            isActive: true,
            selectedPaths: tab.selected,
            yankInfo: yankInfo
        )
    }

    private func renderPreviewColumnInner() {
        let tab = activeTab
        let region = display.layout.previewRegion

        switch tab.previewState {
        case .none:
            display.drawCenteredMessage("", region: region)
        case .loading:
            display.drawCenteredMessage("Loading...", region: region)
        case .text(let cells, _):
            display.drawPreviewCells(cells: cells, region: region)
        case .directory(let entries):
            let displayEntries = entries.prefix(region.height).map { $0.toDisplayEntry(theme: theme) }
            display.drawFileList(
                entries: Array(displayEntries),
                cursorIndex: -1,
                scrollOffset: 0,
                region: region,
                isActive: false
            )
        case .image:
            display.drawCenteredMessage("[Image Preview]", region: region)
            // TODO: Kitty graphics protocol emission
        case .binary(let size):
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            display.drawCenteredMessage("Binary file (\(sizeStr))", region: region)
        case .empty:
            display.drawCenteredMessage("(empty)", region: region)
        case .error(let msg):
            display.drawCenteredMessage("Error: \(msg)", region: region)
        }
    }

    private func renderStatusBarInner() {
        // Start/stop spinner based on whether a waiting state is active
        let needsSpinner = (inputMode == .sftpConnecting) || (activeTab.activityMessage != nil)
        if needsSpinner { startSpinner() } else { stopSpinner() }

        // Check for input modes that use the status bar
        switch inputMode {
        // Text input prompts (user types, cursor shown)
        case .filter:
            display.drawInputLine(prompt: "filter", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .search:
            display.drawInputLine(prompt: "search", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .rename:
            display.drawInputLine(prompt: "rename", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .createFile:
            display.drawInputLine(prompt: "new file", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .createDirectory:
            display.drawInputLine(prompt: "new dir", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .cdPath:
            display.drawInputLine(prompt: "cd", text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .sftpHostKey:
            let prompt = sftpHostKeyIsChanged
                ? "HOST KEY CHANGED! Trust? (yes/no/once)"
                : "Trust host key? (yes/no/once)"
            display.drawInputLine(prompt: prompt, text: inputBuffer, cursorPos: inputCursorPos)
            return
        case .sftpPassword:
            let host = sftpPendingProfile?.sshConfig.host ?? ""
            let maskedPwd = String(repeating: "*", count: sftpPasswordBuffer.count)
            display.drawInputLine(prompt: "Password for \(host)", text: maskedPwd, cursorPos: sftpPasswordBuffer.count)
            return

        // Single-key chord/confirmation prompts (block cursor, no ": ")
        case .deleteConfirm:
            let count = activeTab.operationPaths.count
            display.drawChordPrompt("Delete \(count) item(s)? (y/n)")
            return
        case .crocSendConfirm:
            let count = activeTab.operationPaths.count
            display.drawChordPrompt("Send \(count) item(s) with croc? (y/n)")
            return
        case .pasteOverwriteConfirm:
            let count = (yankClipboard ?? Self.sharedYankClipboard)?.paths.count ?? 0
            display.drawChordPrompt("Paste \(count) item(s)? Existing files will be overwritten (y/n)")
            return
        case .bookmarkSet:
            display.drawChordPrompt("set bookmark")
            return
        case .bookmarkJump:
            display.drawChordPrompt("jump to bookmark")
            return
        case .copyChord:
            display.drawChordPrompt("copy: (c)path (d)dir (f)file (n)name")
            return
        case .uploadFailedPrompt:
            let host = failedUpload?.host ?? ""
            display.drawChordPrompt("Upload to \(host) failed! (r)etry (c)opy path (d)ismiss")
            return

        // Waiting state with spinner
        case .sftpConnecting:
            let host = sftpPendingProfile?.sshConfig.host ?? ""
            display.drawStatusMessage("Connecting to \(host)...", spinnerChar: spinnerChar)
            return

        case .sftpConnect:
            // Rendered by renderSftpPicker() directly
            return
        default:
            break
        }

        // Show SFTP connect error briefly in status bar if present
        if let error = sftpConnectError {
            display.drawStatusMessage("SFTP error: \(error)")
            // Clear error after displaying it once in a full render cycle
            sftpConnectError = nil
            return
        }

        if let activity = activeTab.activityMessage {
            display.drawStatusMessage(activity, spinnerChar: spinnerChar)
            return
        }

        // Show transient status message briefly (auto-clears after one render)
        if let msg = statusMessage {
            display.drawStatusMessage(msg)
            statusMessage = nil
            return
        }

        // Powerline status bar
        let tab = activeTab
        let dir = activeDir

        // Determine mode
        let isVisual = inputMode == .visualSelect || inputMode == .visualUnselect
        let isSearch = tab.searchResults != nil
        let modeBg = isVisual ? theme.modeSelectBg : theme.modeNormalBg
        let modeFg = isVisual ? theme.modeSelectFg : theme.modeNormalFg
        let modeLabel: String
        if isVisual { modeLabel = " VIS " }
        else if isSearch { modeLabel = " SRC " }
        else if tab.dataSource.isRemote { modeLabel = " SFTP " }
        else { modeLabel = " NOR " }

        // Left segments
        var leftSegs: [RFStatusSegment] = []
        leftSegs.append(RFStatusSegment(text: modeLabel, fg: modeFg, bg: modeBg, bold: true))

        if let entry = dir.hoveredEntry {
            let sz = entry.sizeString
            if !sz.isEmpty {
                leftSegs.append(RFStatusSegment(text: " \(sz) ", fg: modeBg, bg: theme.modeAltBg, bold: false))
            }
        }

        // Right segments
        var rightSegs: [RFStatusSegment] = []

        // Sort + extras
        var infoText = " \(tab.sortOrder.displayName) "
        if tab.showHidden { infoText += "H " }
        if !tab.selected.isEmpty { infoText += "\(tab.selected.count)sel " }
        if let yank = yankClipboard {
            infoText += "\(yank.paths.count)\(yank.isCut ? "✂" : "⎘") "
        }
        rightSegs.append(RFStatusSegment(text: infoText, fg: theme.modeAltFg, bg: theme.modeAltBg, bold: false))

        // Position
        let total = dir.visibleEntries.count
        let pos = dir.cursor + 1
        let pct: String
        if total <= 1 { pct = "All" }
        else if pos <= 1 { pct = "Top" }
        else if pos >= total { pct = "Bot" }
        else { pct = "\(pos * 100 / total)%" }
        rightSegs.append(RFStatusSegment(text: " \(pct) \(pos)/\(total) ", fg: modeFg, bg: modeBg, bold: true))

        display.drawPowerlineStatusBar(left: leftSegs, right: rightSegs)
    }

    // MARK: - Path Completion

    private func completePath() {
        var path = inputBuffer
        if path.hasPrefix("~") {
            path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + path.dropFirst()
        }
        if !path.hasPrefix("/") {
            path = (activeTab.currentDir.path as NSString).appendingPathComponent(path)
        }

        let dir = (path as NSString).deletingLastPathComponent
        let prefix = (path as NSString).lastPathComponent

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let matches = contents.filter { $0.hasPrefix(prefix) }.sorted()

        if matches.count == 1 {
            let completed = (dir as NSString).appendingPathComponent(matches[0])
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: completed, isDirectory: &isDir), isDir.boolValue {
                inputBuffer = completed + "/"
            } else {
                inputBuffer = completed
            }
            inputCursorPos = inputBuffer.count
        } else if matches.count > 1 {
            // Find common prefix
            let common = commonPrefix(matches)
            if common.count > prefix.count {
                inputBuffer = (dir as NSString).appendingPathComponent(common)
                inputCursorPos = inputBuffer.count
            }
        }
    }

    /// Replace the Documents directory path with ~ for display.
    /// Also recognizes bookmarked external paths and shows ~BookmarkName.
    /// On iOS, Documents is the user's "home" — NSHomeDirectory() is the container root.
    private func abbreviateHome(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        let homeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = (homeURL.path as NSString).standardizingPath
        if standardized == home { return "~" }
        if standardized.hasPrefix(home + "/") {
            return "~/" + standardized.dropFirst(home.count + 1)
        }

        // Check if path is under a bookmarked external location
        if let bookmark = BookmarkedLocationsManager.shared.bookmarkName(for: path) {
            if bookmark.relativePath.isEmpty {
                return "~\(bookmark.name)"
            }
            return "~\(bookmark.name)/\(bookmark.relativePath)"
        }

        return path
    }

    private func commonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
            }
        }
        return prefix
    }

    private func deleteWordBackward() {
        guard inputCursorPos > 0 else { return }
        var pos = inputCursorPos - 1
        // Skip trailing spaces
        while pos > 0, inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: pos)] == " " {
            pos -= 1
        }
        // Skip word characters
        while pos > 0, inputBuffer[inputBuffer.index(inputBuffer.startIndex, offsetBy: pos - 1)] != " " {
            pos -= 1
        }
        let start = inputBuffer.index(inputBuffer.startIndex, offsetBy: pos)
        let end = inputBuffer.index(inputBuffer.startIndex, offsetBy: inputCursorPos)
        inputBuffer.removeSubrange(start..<end)
        inputCursorPos = pos
    }
}

#endif
