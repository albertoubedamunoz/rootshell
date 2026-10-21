//
//  AgentInboxStore.swift
//  rootshell
//
//  The in-app inbox: history, sections and read state for the agent events the
//  island already mirrors. The island keeps only what is unread (it is a
//  snapshot); this store keeps the "已完成 / 已归档" tail the inbox screen needs.
//
//  Rows wrap the wire type rather than extending it: `AgentInboxItem` is the
//  Live Activity payload and must stay free of message text (privacy option A).
//  The summary lives here, in the app process only.
//

import Foundation
import Observation
import os

// MARK: - Section

nonisolated enum AgentInboxSection: String, Codable, Sendable, CaseIterable, Hashable {
    case needsYou
    case working
    case done
    case archived

    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs You", comment: "Inbox section")
        case .working: String(localized: "In Progress", comment: "Inbox section")
        case .done: String(localized: "Finished", comment: "Inbox section")
        case .archived: String(localized: "Archived", comment: "Inbox section")
        }
    }
}

// MARK: - Row

nonisolated struct AgentInboxRow: Codable, Hashable, Sendable, Identifiable {
    var event: AgentInboxItem
    /// In-app only. Never makes it into the Live Activity payload.
    var summary: String?
    var host: String?
    var tab: String?
    var isRead: Bool
    var isArchived: Bool

    var id: String { event.id }
    var agent: String { event.agent }
    var receivedAt: Date { event.at }
    var deepLink: URL { event.deepLink }
    var status: AgentInboxStatus { AgentInboxStatus(raw: event.status) }

    var section: AgentInboxSection {
        if isArchived { return .archived }
        switch status {
        case .blocked: return .needsYou
        // `other` covers statuses a newer relay may send: treat them as work in
        // progress rather than burying them in Done.
        case .other: return .working
        case .done, .failed: return .done
        }
    }

    init(event: AgentInboxItem, summary: String? = nil, host: String? = nil, tab: String? = nil,
         isRead: Bool = false, isArchived: Bool = false) {
        self.event = event
        self.summary = summary
        self.host = host
        self.tab = tab
        self.isRead = isRead
        self.isArchived = isArchived
    }
}

// MARK: - Feed

/// Pure value logic: insertion, dedupe, ordering, read state.
nonisolated struct AgentInboxFeed: Codable, Hashable, Sendable {
    private(set) var rows: [AgentInboxRow]

    init(rows: [AgentInboxRow] = []) {
        self.rows = rows
    }

    var isEmpty: Bool { rows.isEmpty }

    var unreadCount: Int {
        rows.filter { !$0.isRead && !$0.isArchived }.count
    }

    func rows(in section: AgentInboxSection) -> [AgentInboxRow] {
        rows.filter { $0.section == section }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    mutating func insert(_ row: AgentInboxRow) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            // A redelivered event refreshes its status but must not resurrect a
            // row the person already read or archived.
            var merged = row
            merged.isRead = rows[index].isRead
            merged.isArchived = rows[index].isArchived
            merged.summary = row.summary ?? rows[index].summary
            rows[index] = merged
        } else {
            rows.append(row)
        }
        rows.sort { $0.receivedAt > $1.receivedAt }
    }

    mutating func markRead(paneDeepLink: URL) {
        for index in rows.indices where rows[index].deepLink == paneDeepLink {
            rows[index].isRead = true
        }
    }

    mutating func markAllRead() {
        for index in rows.indices {
            rows[index].isRead = true
        }
    }

    mutating func archive(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isArchived = true
        rows[index].isRead = true
    }

    /// Drops rows older than the island's own lifetime.
    mutating func prune(olderThan age: TimeInterval, now: Date) {
        rows.removeAll { now.timeIntervalSince($0.receivedAt) >= age }
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentInboxStore {
    static let shared = AgentInboxStore()

    private static let storageKey = "agentInboxFeed.v1"
    private static let maxAge: TimeInterval = 12 * 60 * 60
    private static let log = Logger(subsystem: "com.rootshell", category: "AgentInbox")

    private(set) var feed: AgentInboxFeed
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: AppIdentifiers.defaultAppGroupID) ?? .standard
        self.defaults = resolved
        if let data = resolved.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(AgentInboxFeed.self, from: data) {
            self.feed = decoded
        } else {
            self.feed = AgentInboxFeed()
        }
        feed.prune(olderThan: Self.maxAge, now: Date())
    }

    var unreadCount: Int { feed.unreadCount }
    var isEmpty: Bool { feed.isEmpty }

    func rows(in section: AgentInboxSection) -> [AgentInboxRow] { feed.rows(in: section) }

    @discardableResult
    func record(event: AgentInboxItem, summary: String?, host: String?, tab: String?) -> AgentInboxRow {
        let row = AgentInboxRow(event: event, summary: summary, host: host, tab: tab)
        feed.insert(row)
        persist()
        return row
    }

    func markRead(deepLink: URL) {
        feed.markRead(paneDeepLink: deepLink)
        persist()
    }

    func markAllRead() {
        guard feed.unreadCount > 0 else { return }
        feed.markAllRead()
        persist()
    }

    func archive(_ id: String) {
        feed.archive(id)
        persist()
    }

    #if DEBUG
    /// Design-review seed: launches with `-AgentInboxDemoSeed` to fill the inbox
    /// with representative rows. Debug builds only; no shipping path calls it.
    func seedDemoIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-AgentInboxDemoSeed") else { return }
        // Demo rows carry the language they were seeded in, so re-seeding after
        // a language switch has to start from an empty feed.
        if arguments.contains("-AgentInboxDemoReset") { feed = AgentInboxFeed() }
        let now = Date()
        var seededItems: [AgentInboxItem] = []
        let seeds: [(String, String, String, String, String, TimeInterval)] = [
            ("demo-1", "claude-code", "blocked", "mac-mini-m4", "web-app", 120),
            ("demo-2", "codex", "blocked", "imac-zt", "api", 300),
            ("demo-3", "oh-my-pi", "running", "mac-mini-m4", "app-ios", 360),
            ("demo-4", "deepseek-harness", "done", "oma.zt", "web-app", 1080),
            ("demo-5", "hermes", "failed", "imac-zt", "site", 3600),
        ]
        let summaries: [String] = [
            String(localized: "Demo: Bash wants to run `wrangler deploy --env prod`", comment: "Demo seed text"),
            String(localized: "Demo: keep Clerk sessions, self-host Auth.js", comment: "Demo seed text"),
            String(localized: "Demo: editing src/session/store.ts · 58%", comment: "Demo seed text"),
            String(localized: "Demo: retry button after the 10s timeout, 14 tests pass", comment: "Demo seed text"),
            String(localized: "Demo: dependency install failed, lockfile conflict", comment: "Demo seed text"),
        ]
        for (index, seed) in seeds.enumerated() {
            let event = AgentInboxItem(
                id: seed.0,
                agent: seed.1,
                status: seed.2,
                at: now.addingTimeInterval(-seed.5),
                deepLink: URL(string: "rootshell://pane/\(String(format: "%08d", index + 1))-0000-4000-8000-000000000000")!
            )
            record(event: event, summary: summaries[index], host: seed.3, tab: seed.4)
            #if DEBUG
            seededItems.append(event)
            #endif
        }
        #if DEBUG
        LiveActivityManager.shared.debugSeedAgentInbox(seededItems)
        #endif
    }
    #endif

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(feed), forKey: Self.storageKey)
        } catch {
            Self.log.error("inbox persist failed: \(String(describing: error), privacy: .public)")
        }
    }
}
