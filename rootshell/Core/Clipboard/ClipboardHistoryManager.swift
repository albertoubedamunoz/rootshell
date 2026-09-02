//
//  ClipboardHistoryManager.swift
//  rootshell
//
//  In-app clipboard history: captures clipboard activity that happens inside
//  the app (explicit copies, copy-on-select, remote OSC 52 writes, pastes)
//  into an encrypted-at-rest store. Entirely optional; disabling the feature
//  wipes the store and its encryption key.
//

import Foundation
import os
import UIKit

// MARK: - Entry model

// nonisolated so decode (and the byteCount/preview backfill) can run inside the
// store's detached load task.
nonisolated struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    enum Source: Codable, Equatable, Hashable, Sendable {
        /// copy-on-select (write_clipboard_cb with the selection clipboard)
        case selectionCopy
        /// copy(_:) funnel: Cmd+C, context menu, selection bubble
        case explicitCopy
        /// Remote terminal or desktop session wrote the device clipboard.
        /// The legacy case name is retained for persisted-history compatibility.
        case osc52(sessionLabel: String)
        /// Content pasted into a terminal (may originate outside the app)
        case paste
        /// Copy Link menu action
        case copyLink
        /// Saved result of a clipboard transform
        case transform(name: String)
    }

    let id: UUID
    /// Mutate only via replaceText(_:) so the stored derived fields stay in sync.
    private(set) var text: String
    let createdAt: Date
    /// Sort key; bumped by dedup and by Copy/Paste actions on the entry.
    var lastUsedAt: Date
    var source: Source
    var pinned: Bool
    /// Stored, not derived: rows render preview and enforceCaps sums byteCount on
    /// every pass, so neither may scan the full text after capture.
    private(set) var byteCount: Int
    private(set) var preview: String

    init(text: String, source: Source) {
        self.id = UUID()
        self.text = text
        self.createdAt = Date()
        self.lastUsedAt = self.createdAt
        self.source = source
        self.pinned = false
        self.byteCount = text.utf8.count
        self.preview = Self.makePreview(from: text)
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, lastUsedAt, source, pinned, byteCount, preview
    }

    /// Backfills byteCount/preview for files written before they were stored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let text = try container.decode(String.self, forKey: .text)
        self.text = text
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.lastUsedAt = try container.decode(Date.self, forKey: .lastUsedAt)
        self.source = try container.decode(Source.self, forKey: .source)
        self.pinned = try container.decode(Bool.self, forKey: .pinned)
        self.byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? text.utf8.count
        self.preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? Self.makePreview(from: text)
    }

    /// Sets text and its derived fields together (coalesce path).
    mutating func replaceText(_ newText: String) {
        text = newText
        byteCount = newText.utf8.count
        preview = Self.makePreview(from: newText)
    }

    /// Characters examined when deriving a preview.
    private static let previewScanLimit = 4_096

    /// First two non-empty lines, capped for list rows. Bounded: examines at most
    /// previewScanLimit characters starting at the first non-whitespace character,
    /// so whitespace-only previews are impossible (record() rejects all-whitespace
    /// text) without scanning huge entries.
    private static func makePreview(from text: String) -> String {
        let start = text.firstIndex(where: { !$0.isWhitespace }) ?? text.startIndex
        let window = text[start...].prefix(previewScanLimit)
        let lines = window
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return String(lines.prefix(2).joined(separator: "\n").prefix(200))
    }

    var sourceIconName: String {
        switch source {
        case .selectionCopy: return "cursorarrow.motionlines"
        case .explicitCopy: return "doc.on.doc"
        case .osc52: return "antenna.radiowaves.left.and.right"
        case .paste: return "doc.on.clipboard"
        case .copyLink: return "link"
        case .transform: return "wand.and.stars"
        }
    }

    var sourceLabel: String {
        switch source {
        case .selectionCopy:
            return String(localized: "Selection", comment: "Clipboard entry source: copy-on-select")
        case .explicitCopy:
            return String(localized: "Copied", comment: "Clipboard entry source: explicit copy")
        case .osc52(let sessionLabel):
            return String(localized: "Remote: \(sessionLabel)", comment: "Clipboard entry source: OSC 52 write from a remote session")
        case .paste:
            return String(localized: "Pasted", comment: "Clipboard entry source: pasted into a terminal")
        case .copyLink:
            return String(localized: "Link", comment: "Clipboard entry source: Copy Link action")
        case .transform(let name):
            return String(localized: "Transform: \(name)", comment: "Clipboard entry source: saved transform result")
        }
    }
}

// MARK: - Manager

@MainActor
@Observable
final class ClipboardHistoryManager {
    static let shared = ClipboardHistoryManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ClipboardHistory")

    // MARK: Settings keys

    static let enabledKey = "clipboardManagerEnabled"

    enum Retention: String, CaseIterable, Identifiable {
        case forever
        case day
        case week
        case month

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .forever: return String(localized: "Forever", comment: "Clipboard history retention option")
            case .day: return String(localized: "1 Day", comment: "Clipboard history retention option")
            case .week: return String(localized: "7 Days", comment: "Clipboard history retention option")
            case .month: return String(localized: "30 Days", comment: "Clipboard history retention option")
            }
        }

        var maxAge: TimeInterval? {
            switch self {
            case .forever: return nil
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .month: return 30 * 86_400
            }
        }
    }

    // MARK: Caps

    /// Entries larger than this are not captured at all (never truncated).
    static let maxEntryBytes = 1_048_576
    static let maxUnpinned = 200
    static let maxPinned = 50
    /// Bound on the whole store so the single-file rewrite stays cheap.
    static let maxTotalBytes = 20 * 1024 * 1024

    // MARK: Settings

    var isEnabled: Bool = false {
        didSet {
            guard settingsLoaded, ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Clipboard.managerEnabled, isEnabled) }
            if !isEnabled { wipe() }
        }
    }

    var requireBiometric: Bool = false {
        didSet {
            guard settingsLoaded, ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Clipboard.requireBiometric, requireBiometric) }
            if requireBiometric { isUnlocked = false }
        }
    }

    var retention: Retention = .week {
        didSet {
            guard settingsLoaded, ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Clipboard.retention, retention) }
            if sweepRetention() { scheduleSave() }
        }
    }

    private static let ownedKeys: Set<String> = [
        Settings.Clipboard.managerEnabled.name, Settings.Clipboard.requireBiometric.name, Settings.Clipboard.retention.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Clipboard.managerEnabled.name) { isEnabled = store.get(Settings.Clipboard.managerEnabled) }
        if keys.contains(Settings.Clipboard.requireBiometric.name) {
            requireBiometric = store.get(Settings.Clipboard.requireBiometric)
        }
        if keys.contains(Settings.Clipboard.retention.name) { retention = store.get(Settings.Clipboard.retention) }
    }

    // MARK: State

    /// Most recently used first. Canonical order; UI renders pinned section separately.
    /// didSet fires on in-place element mutation too (value-type array), so the
    /// revision reliably covers coalesce text rewrites that change neither count
    /// nor identity.
    private(set) var entries: [ClipboardEntry] = [] {
        didSet { entriesRevision &+= 1 }
    }

    /// Bumped on every entries mutation; search keys on it so active results
    /// can't go stale when text changes without changing entry count.
    private(set) var entriesRevision = 0

    /// Biometric session state; reset when the app backgrounds.
    var isUnlocked = false

    /// Re-entrancy guard: set while the manager itself drives a synthetic
    /// clipboard operation (paste-back) so it isn't captured as history.
    var suppressCapture = false

    private let store = ClipboardHistoryStore()
    private var settingsLoaded = false
    private var isLoaded = false
    /// Captures arriving before the initial store load; replayed after load so
    /// an early capture can't clobber the file with a one-entry store.
    private var pendingRecords: [(text: String, source: ClipboardEntry.Source)] = []
    private var saveDebounceTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {
        ProtectedDataGuard.whenAvailable { [weak self] in
            self?.loadSettingsAndStore()
        }

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isUnlocked = false
                    self.forceSave()
                }
            }
        )
    }

    private func loadSettingsAndStore() {
        let store = SettingsStore.shared
        isEnabled = store.get(Settings.Clipboard.managerEnabled)
        requireBiometric = store.get(Settings.Clipboard.requireBiometric)
        retention = store.get(Settings.Clipboard.retention)
        settingsLoaded = true

        guard isEnabled else {
            isLoaded = true
            pendingRecords = []
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            guard !self.isLoaded else { return }
            self.entries = loaded
            self.isLoaded = true
            var dirty = self.sweepRetention()
            let pending = self.pendingRecords
            self.pendingRecords = []
            for record in pending {
                self.insert(record.text, source: record.source)
                dirty = true
            }
            if dirty { self.scheduleSave() }
        }
    }

    // MARK: Capture

    func record(_ text: String, source: ClipboardEntry.Source) {
        guard isEnabled, !suppressCapture else { return }
        // Allocation-free whitespace check; trimmingCharacters would copy up to
        // 1MB per capture, and copy-on-select captures arrive in bursts.
        guard text.contains(where: { !$0.isWhitespace }) else { return }
        let bytes = text.utf8.count
        guard bytes <= Self.maxEntryBytes else {
            Self.logger.info("Skipping clipboard capture: \(bytes) bytes exceeds cap")
            return
        }
        guard isLoaded else {
            pendingRecords.append((text, source))
            return
        }
        insert(text, source: source)
        scheduleSave()
    }

    private func insert(_ text: String, source: ClipboardEntry.Source) {
        // Dedup: identical text bumps the existing entry instead of duplicating.
        // byteCount first so length mismatches reject on an Int compare.
        let byteCount = text.utf8.count
        if let index = entries.firstIndex(where: { $0.byteCount == byteCount && $0.text == text }) {
            var entry = entries.remove(at: index)
            entry.lastUsedAt = Date()
            entry.source = source
            entries.insert(entry, at: 0)
            return
        }

        // Coalesce a growing/shrinking drag selection into one entry: the same
        // copy-on-select gesture emits a burst of writes where each text extends
        // or trims the previous one.
        if case .selectionCopy = source,
           let newest = entries.first,
           case .selectionCopy = newest.source,
           !newest.pinned,
           Date().timeIntervalSince(newest.lastUsedAt) < 10,
           text.hasPrefix(newest.text) || newest.text.hasPrefix(text)
            || text.hasSuffix(newest.text) || newest.text.hasSuffix(text) {
            entries[0].replaceText(text)
            entries[0].lastUsedAt = Date()
            return
        }

        entries.insert(ClipboardEntry(text: text, source: source), at: 0)
        enforceCaps()
    }

    // MARK: Entry actions

    /// Pins or unpins an entry. Pinning is refused (returns false) at the pin cap.
    @discardableResult
    func togglePin(_ id: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if !entries[index].pinned {
            let pinnedCount = entries.count(where: { $0.pinned })
            guard pinnedCount < Self.maxPinned else { return false }
        }
        entries[index].pinned.toggle()
        scheduleSave()
        return true
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Clears all entries (including pinned) but keeps the feature enabled.
    func clearAll() {
        guard isLoaded else { return }
        saveDebounceTask?.cancel()
        entries = []
        pendingRecords = []
        store.write([])
    }

    func markUsed(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.lastUsedAt = Date()
        entries.insert(entry, at: 0)
        scheduleSave()
    }

    // MARK: Caps + retention

    private func enforceCaps() {
        var unpinnedCount = entries.count(where: { !$0.pinned })
        if unpinnedCount > Self.maxUnpinned {
            for index in stride(from: entries.count - 1, through: 0, by: -1) where !entries[index].pinned {
                entries.remove(at: index)
                unpinnedCount -= 1
                if unpinnedCount <= Self.maxUnpinned { break }
            }
        }

        var totalBytes = entries.reduce(0) { $0 + $1.byteCount }
        if totalBytes > Self.maxTotalBytes {
            for index in stride(from: entries.count - 1, through: 0, by: -1) where !entries[index].pinned {
                totalBytes -= entries[index].byteCount
                entries.remove(at: index)
                if totalBytes <= Self.maxTotalBytes { break }
            }
        }
    }

    /// Drops unpinned entries older than the retention window. Returns true if anything changed.
    @discardableResult
    private func sweepRetention() -> Bool {
        guard let maxAge = retention.maxAge else { return false }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let before = entries.count
        entries.removeAll { !$0.pinned && $0.lastUsedAt < cutoff }
        return entries.count != before
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    func forceSave() {
        saveDebounceTask?.cancel()
        persistNow()
    }

    private func persistNow() {
        guard isEnabled, isLoaded else { return }
        store.write(entries)
    }

    private func wipe() {
        saveDebounceTask?.cancel()
        pendingRecords = []
        entries = []
        isUnlocked = false
        // Mark loaded so an in-flight load() (started before disable) bails at its
        // `guard !isLoaded` instead of writing the old decrypted snapshot back over
        // the wipe. This is also the correct post-wipe state: the store is gone, so
        // there is nothing left to load, and a later re-enable starts empty.
        isLoaded = true
        store.wipe()
    }
}
