//
//  HTTPCaptureModel.swift
//  rootshell
//
//  Per-window HTTP capture panel state. Owned by MainView and kept while the
//  panel is hidden, so reopening lands on the same session and request.
//

#if !CHINA_BUILD

import Foundation

@MainActor
@Observable
final class HTTPCaptureModel {
    enum Route: Hashable {
        case transaction(String)
    }

    enum Sheet: Identifiable {
        case sessions
        case settings
        case trustGuide
        case share(URL)
        case rewriteRule(CaptureRewriteRule)

        var id: String {
            switch self {
            case .sessions: "sessions"
            case .settings: "settings"
            case .trustGuide: "trustGuide"
            case .share(let url): "share-\(url.path)"
            case .rewriteRule(let rule): "rule-\(rule.id)"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case all, decrypted, tunnels, problems
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All", comment: "HTTP capture filter")
            case .decrypted: String(localized: "HTTP", comment: "HTTP capture filter: decrypted and plain HTTP requests")
            case .tunnels: String(localized: "Tunnels", comment: "HTTP capture filter: connections not inspected")
            case .problems: String(localized: "Issues", comment: "HTTP capture filter: errors, pinning and failures")
            }
        }
    }

    enum StatusClass: Int, CaseIterable, Identifiable {
        case success = 2, redirect = 3, clientError = 4, serverError = 5
        var id: Int { rawValue }
        var title: String { "\(rawValue)xx" }
    }

    private(set) var sessionID: String?
    private(set) var document: CaptureSessionDocument?
    var selectedTransactionID: String?
    var path: [Route] = []
    var search = ""
    var scope: Scope = .all
    var kindFilter: CaptureContentKind?
    var statusFilter: StatusClass?
    var sheet: Sheet?
    var errorMessage: String?
    /// On-screen panel instances. Switching sidebar ↔ overlay briefly has two,
    /// and their appear/disappear calls can arrive in either order.
    private var visibleCount = 0
    private var isVisible: Bool { visibleCount > 0 }

    /// Opens the recording session, else the newest one.
    func openDefault() {
        let target = CaptureController.shared.activeSessionID ?? CaptureSessionStore.shared.sessions.first?.id
        if let target, target != sessionID {
            open(sessionID: target)
        }
    }

    func open(sessionID id: String) {
        document?.stopWatching()
        sessionID = id
        selectedTransactionID = nil
        path = []
        let document = CaptureSessionDocument(sessionID: id)
        self.document = document
        if isVisible { document.startWatching() }
    }

    func setVisible(_ visible: Bool) {
        visibleCount = max(0, visibleCount + (visible ? 1 : -1))
        if isVisible {
            if document == nil { openDefault() }
            document?.startWatching()
        } else {
            document?.stopWatching()
        }
    }

    func tearDown() {
        document?.stopWatching()
    }

    var hasFilters: Bool {
        scope != .all || kindFilter != nil || statusFilter != nil || !search.isEmpty
    }

    func clearFilters() {
        scope = .all
        kindFilter = nil
        statusFilter = nil
        search = ""
    }

    func filtered(_ transactions: [CaptureTransaction]) -> [CaptureTransaction] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return transactions.filter { tx in
            switch scope {
            case .all: break
            case .decrypted: if tx.kind != .http { return false }
            case .tunnels: if tx.kind != .tunnel { return false }
            case .problems:
                let isProblem = tx.kind == .rejected || tx.kind == .failure || tx.error != nil || (tx.status ?? 0) >= 400
                if !isProblem { return false }
            }
            if let kindFilter, tx.kind != .http || tx.contentKind != kindFilter { return false }
            if let statusFilter, (tx.status ?? 0) / 100 != statusFilter.rawValue { return false }
            if !needle.isEmpty {
                let haystack = "\(tx.method) \(tx.url) \(tx.displayHost) \(tx.status.map(String.init) ?? "")".lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
    }
}

#endif
