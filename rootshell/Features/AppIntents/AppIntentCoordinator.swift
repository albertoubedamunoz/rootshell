//
//  AppIntentCoordinator.swift
//  rootshell
//
//  Buffer between App Intents / URL opens and MainView. Deposit-then-notify
//  survives the cold-start race (an intent's perform() can run before any
//  window's onReceive subscription exists, or before Ghostty finishes
//  initializing). Requests carry no originating window, so delivery is
//  consume-once with key-window bias: the key window claims immediately,
//  non-key windows retry after a short delay and claim only if the buffer
//  still has entries. At most one window ever acts on a request.
//
//  A second, window-targeted buffer backs AppleScript's `create window`:
//  requests are staged, a fresh scene is requested, and the first empty
//  window to appear claims them instead of opening its default shell.
//

import Foundation
import UIKit
import os

private let logger = Logger(subsystem: "com.rootshell", category: "AppIntentCoordinator")

extension Notification.Name {
    /// Posted after an intent request was deposited.
    /// Carries no payload — consumers pull from AppIntentCoordinator.
    static let appIntentRequestReceived = Notification.Name("appIntentRequestReceived")
}

@MainActor
final class AppIntentCoordinator {
    static let shared = AppIntentCoordinator()

    enum IntentRequest {
        case openProfile(ProfileIntentRequest)
        /// `command` is typed into the shell once it starts (Catalyst only).
        case openLocalShell(directory: String?, command: String?)
        case openSSH(SSHURLComponents)
        case openMosh(MoshURLComponents)
    }

    private var pending: [IntentRequest] = []

    var hasPending: Bool { !pending.isEmpty }

    func deposit(_ request: IntentRequest) {
        pending.append(request)
        NotificationCenter.default.post(name: .appIntentRequestReceived, object: nil)
    }

    /// First claimant wins; empties the buffer.
    func consumeAll() -> [IntentRequest] {
        defer { pending.removeAll() }
        return pending
    }

    // MARK: - URL / Apple event deposits

    /// One open reaches us through several paths at once (odoc command, scene
    /// urlContexts, app- and window-level .onOpenURL). Each invocation gets a
    /// record that accumulates the paths which delivered it; a delivery is a
    /// twin only if some record is still waiting on that path, so a path with
    /// nothing left to answer is a deliberate second invocation.
    private struct URLDelivery {
        let key: String
        var sources: Set<String>
        var expiresAt: Date
    }

    private var recentURLDeliveries: [URLDelivery] = []
    private static let urlDedupeWindow: TimeInterval = 1.5

    /// Returns false when another delivery path already took this request.
    @discardableResult
    func depositURLRequest(_ request: IntentRequest, source: String) -> Bool {
        let now = Date()
        recentURLDeliveries.removeAll { $0.expiresAt <= now }

        // Keyed on the resolved request, not the url, so /tmp and /tmp/
        // collapse to one tab.
        let key = Self.dedupeKey(for: request)
        let expiresAt = now.addingTimeInterval(Self.urlDedupeWindow)

        // Oldest record still awaiting this path claims the delivery (FIFO), so
        // interleaved invocations pair off in order.
        if let index = recentURLDeliveries.firstIndex(where: {
            $0.key == key && !$0.sources.contains(source)
        }) {
            recentURLDeliveries[index].sources.insert(source)
            recentURLDeliveries[index].expiresAt = expiresAt
            logger.info("[urlopen] suppressed duplicate source=\(source, privacy: .public)")
            return false
        }

        recentURLDeliveries.append(URLDelivery(key: key, sources: [source], expiresAt: expiresAt))
        logger.info("[urlopen] deposit source=\(source, privacy: .public)")
        deposit(request)
        return true
    }

    private static func dedupeKey(for request: IntentRequest) -> String {
        switch request {
        case .openProfile(let profileRequest):
            return "profile|\(profileRequest.profileID)"
        case .openLocalShell(let directory, let command):
            return "shell|\(directory ?? "")|\(command ?? "")"
        case .openSSH(let components):
            return "ssh|\(components.displayString)"
        case .openMosh(let components):
            return "mosh|\(components.displayString)"
        }
    }

    // MARK: - New-window requests

    /// FIFO: one entry per requested scene, claimed one per new window.
    private var pendingForNewWindow: [(request: IntentRequest, stagedAt: Date)] = []
    private static let newWindowRequestTTL: TimeInterval = 5

    /// Stage `request` and request one scene for it (the same nil-session
    /// activation Cmd-N uses). Entries expire so a stale one can never
    /// hijack a later, unrelated new window.
    func depositForNewWindow(_ request: IntentRequest) {
        // Cold launch: the first window is already on its way, so let it
        // claim the request rather than opening a second window.
        let hasWindow = UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene }
        guard hasWindow else {
            deposit(request)
            return
        }
        pendingForNewWindow.append((request, Date()))
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    /// Each new empty window takes the oldest live entry, so N calls map to
    /// N windows in order.
    func claimNewWindowRequest() -> IntentRequest? {
        let cutoff = Date().addingTimeInterval(-Self.newWindowRequestTTL)
        pendingForNewWindow.removeAll { $0.stagedAt < cutoff }
        guard !pendingForNewWindow.isEmpty else { return nil }
        return pendingForNewWindow.removeFirst().request
    }
}
