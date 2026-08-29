//
//  PushNotificationRouter.swift
//  rootshell
//
//  Presentation, tap routing, and cross-source arbitration for decrypted
//  push notifications (category com.rootshell.push). Routes resolve to the
//  window + tab + pane the hook ran in, including tmux -CC panes.
//

import Foundation
import RootshellPushKit
import UIKit
import UserNotifications
import os

@MainActor
enum PushNotificationRouter {
    private static let logger = Logger(subsystem: "com.rootshell", category: "PushRouter")

    struct Resolved: Equatable {
        let windowId: String
        let tabID: UUID
        let surfaceID: UUID
    }

    private struct PendingRoute {
        let route: PushRoute
        let expires: Date
    }

    private static var pending: PendingRoute?
    private static var lastSyncedEvent: Date = .distantPast
    private static var deliveredIdentifiers: [UUID: Set<String>] = [:]

    // MARK: - Header

    static func header(from userInfo: [AnyHashable: Any]) -> PushHeader? {
        guard let dict = userInfo[PushConfiguration.headerUserInfoKey],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(PushHeader.self, from: data)
    }

    /// Header from the extension, or decrypted here when the extension did
    /// not run (macOS delivers pushes straight to a running Catalyst app).
    static func decryptedHeader(from userInfo: [AnyHashable: Any]) -> (header: PushHeader, decryptedLocally: Bool)? {
        if let h = header(from: userInfo) { return (h, false) }
        guard let env = PushEnvelope(userInfo: userInfo), isAccepted(env),
              let key = try? PushConfiguration.keychain.loadPrivateKey(),
              let h = try? env.open(with: key) else { return nil }
        return (h, true)
    }

    /// Revoked senders and stale registrations are enforced here; the relay keeps no state.
    static func isAccepted(_ env: PushEnvelope) -> Bool {
        PushSharedState().loadPolicy().accepts(env)
    }

    static func isRejected(_ userInfo: [AnyHashable: Any]) -> Bool {
        if userInfo[PushConfiguration.rejectedUserInfoKey] != nil { return true }
        if let env = PushEnvelope(userInfo: userInfo), !isAccepted(env) { return true }
        return false
    }

    /// Re-posts a raw push as a local notification carrying the decrypted content.
    private static func presentLocally(_ header: PushHeader, eid: String, sound: UNNotificationSound?) async {
        let content = UNMutableNotificationContent()
        content.title = header.title
        content.body = header.body ?? ""
        content.subtitle = header.statusSubtitle ?? ""
        content.threadIdentifier = "push-\(header.thread ?? eid)"
        content.categoryIdentifier = PushConfiguration.categoryIdentifier
        content.relevanceScore = header.status == "blocked" ? 1 : 0.5
        if header.status == "blocked" { content.interruptionLevel = .timeSensitive }
        content.sound = sound
        if let dict = try? header.userInfoDictionary() {
            content.userInfo = [PushConfiguration.headerUserInfoKey: dict]
        }
        PushSharedState().append(PushEventRecord(header: header, eid: eid))
        let request = UNNotificationRequest(identifier: "push-\(eid)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.error("local re-post failed: \(String(describing: error), privacy: .public)")
        }
        // A suppressed remote push still lands in Notification Center history on
        // macOS; drop the raw copy. syncDelivered repeats this on activation.
        await removeRawDelivered(eid: eid)
    }

    static func attentionStatus(_ status: String?) -> AgentAttentionStatus? {
        switch status {
        case "done": return .done
        case "blocked": return .blocked
        case "failed": return .failed
        default: return nil
        }
    }

    // MARK: - Resolution

    /// Order: tmux pane bound to the gateway named in the route, any tmux
    /// pane with that id, the pane token itself, then any pane on the host.
    static func resolve(_ route: PushRoute?) -> Resolved? {
        guard let route else { return nil }
        let paneUUID = route.pane.flatMap(UUID.init(uuidString:))
        let tmuxPaneId = route.tmuxPane.flatMap { $0.hasPrefix("%") ? Int($0.dropFirst()) : nil }
        var candidates: [(Resolved, Ghostty.TerminalView, Int)] = []

        for (windowId, model) in TmuxWindowRegistry.allWindows() {
            for tab in model.tabs {
                for pane in tab.splitTree {
                    guard let view = pane as? Ghostty.TerminalView else { continue }
                    var score = 0
                    if let tmuxPaneId, let binding = view.tmuxPaneBinding, binding.paneId == tmuxPaneId {
                        score = binding.parentUUID == paneUUID ? 4 : 3
                    } else if let paneUUID, view.uuid == paneUUID, view.tmuxPaneBinding == nil {
                        score = 2
                    } else if let host = route.host, matchesHost(view, host) {
                        score = 1
                    }
                    guard score > 0 else { continue }
                    if let cwd = route.cwd, score < 4, view.pwd == cwd { score += 1 }
                    candidates.append((Resolved(windowId: windowId, tabID: tab.id, surfaceID: view.uuid), view, score))
                }
            }
        }
        if candidates.isEmpty {
            let panes = TmuxWindowRegistry.allWindows().flatMap { $0.model.tabs }.flatMap { tab in
                tab.splitTree.compactMap { ($0 as? Ghostty.TerminalView).map { "\($0.uuid.uuidString.prefix(8)) tmux=\($0.tmuxPaneBinding?.paneId ?? -1) host=\($0.connectionConfig.underlyingSSHConfig?.host ?? "local")" } }
            }
            logger.info("resolve: no candidates; panes=\(panes.joined(separator: ", "), privacy: .public)")
        }
        return candidates.max { $0.2 < $1.2 }?.0
    }

    private static func matchesHost(_ view: Ghostty.TerminalView, _ host: String) -> Bool {
        guard let ssh = view.connectionConfig.underlyingSSHConfig else { return false }
        let user = host.split(separator: "@").first.map(String.init)
        let name = host.split(separator: "@").last.map(String.init) ?? host
        let short = ssh.host.split(separator: ".").first.map(String.init) ?? ssh.host
        return (short == name || ssh.host == name) && (user == nil || user == ssh.username)
    }

    static func isViewed(_ resolved: Resolved) -> Bool {
        guard let model = TerminalWindowRegistry.tabsModel(for: resolved.windowId),
              let tab = model.tabs.first(where: { $0.id == resolved.tabID }),
              let view = tab.splitTree.first(where: { $0.uuid == resolved.surfaceID }) else { return false }
        return AgentPaneVisibility.isViewed(appBackgrounded: Ghostty.isAppBackgrounded,
                                            selectedTabID: model.selectedTabID,
                                            containingTabID: tab.id,
                                            focusedPaneID: tab.focusedPane?.uuid,
                                            paneID: view.uuid,
                                            isKeyWindow: view.window?.isKeyWindow ?? false)
    }

    // MARK: - Foreground presentation

    static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        let content = notification.request.content
        if isRejected(content.userInfo) {
            logger.info("dropped: revoked sender or stale registration")
            return []
        }
        guard let (header, decryptedLocally) = decryptedHeader(from: content.userInfo) else { return [.banner, .list] }
        if decryptedLocally {
            let eid = PushEnvelope(userInfo: content.userInfo)?.eid ?? UUID().uuidString
            Task { await presentLocally(header, eid: eid, sound: content.sound) }
            return []
        }
        let resolved = resolve(header.route)
        let status = attentionStatus(header.status)

        if let resolved {
            // Explicit `send`/`test` notifications always show; agent events follow the
            // same viewed-pane and policy rules as screen-detected ones.
            if header.kind == "agent" {
                if isViewed(resolved) {
                    logger.info("suppressed: pane is being viewed")
                    return []
                }
                if let status {
                    if AgentAttentionNotificationRouter.shouldSuppressExternal(pane: resolved.surfaceID, status: status) {
                        logger.info("suppressed: screen detection already notified")
                        return []
                    }
                    if !AgentNotificationPolicy.current.allows(status) {
                        logger.info("suppressed: policy")
                        return []
                    }
                }
            }
            noteDelivered(identifier: notification.request.identifier, pane: resolved.surfaceID, status: status)
        }
        var options: UNNotificationPresentationOptions = [.banner, .list]
        if content.sound != nil { options.insert(.sound) }
        return options
    }

    private static func noteDelivered(identifier: String, pane: UUID, status: AgentAttentionStatus?) {
        deliveredIdentifiers[pane, default: []].insert(identifier)
        if let status { AgentAttentionNotificationRouter.externalEventDelivered(pane: pane, status: status) }
    }

    /// Called from the attention router's seen pass: looking at the pane
    /// answers its push notifications too.
    static func paneViewed(_ pane: UUID) {
        guard let ids = deliveredIdentifiers.removeValue(forKey: pane), !ids.isEmpty else { return }
        NotificationManager.shared.removeNotifications(identifiers: Array(ids))
    }

    // MARK: - Tap

    static func handleTap(userInfo: [AnyHashable: Any]) {
        guard let header = decryptedHeader(from: userInfo)?.header else {
            logger.error("tap: no decryptable header")
            return
        }
        let r = header.route
        logger.info("tap route pane=\(r?.pane ?? "-", privacy: .public) tmux=\(r?.tmuxPane ?? "-", privacy: .public) host=\(r?.host ?? "-", privacy: .public) cwd=\(r?.cwd ?? "-", privacy: .public) resolved=\(String(describing: resolve(r)), privacy: .public)")
        if let route = header.route {
            pending = PendingRoute(route: route, expires: Date().addingTimeInterval(60))
        }
        retryPending()
    }

    /// Retried when tabs restore, tmux panes project, or a scene activates.
    static func retryPending() {
        guard let p = pending else { return }
        guard p.expires > Date() else { pending = nil; return }
        guard let resolved = resolve(p.route) else { return }
        pending = nil
        navigate(to: resolved)
    }

    static func navigate(to resolved: Resolved) {
        Task { @MainActor in
            // A tap from a hidden/background app: wait for the system to finish
            // activating before touching focus, or the responder chain detaches.
            if UIApplication.shared.applicationState != .active {
                await Self.next(UIApplication.didBecomeActiveNotification)
            }
            // Only bring a different window forward; re-activating the key window
            // resets first responder under the terminal's feet.
            if let scene = MainView.windowScene(forWindowId: resolved.windowId),
               scene.activationState != .foregroundActive || scene.keyWindow == nil {
                UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil) { error in
                    Self.logger.error("scene activation failed: \(error.localizedDescription)")
                }
                await Self.next(UIScene.didActivateNotification, from: scene)
            }
            NotificationCenter.default.post(name: .navigateToTerminal, object: nil,
                                            userInfo: ["tabID": resolved.tabID, "surfaceID": resolved.surfaceID])
        }
    }

    /// Suspends until `name` is posted (optionally by `object`).
    private static func next(_ name: Notification.Name, from object: AnyObject? = nil) async {
        let stream = NotificationCenter.default.notifications(named: name, object: object)
        for await _ in stream { return }
    }

    /// Remote push delivered to the app process (macOS, app hidden or in the
    /// background). Replaces the raw alert with the decrypted one.
    static func handleRemote(userInfo: [AnyHashable: Any]) async {
        guard let env = PushEnvelope(userInfo: userInfo) else { return }
        logger.info("remote delivery eid=\(env.eid, privacy: .public) state=\(UIApplication.shared.applicationState.rawValue)")
        guard isAccepted(env) else {
            await removeRawDelivered(eid: env.eid)
            return
        }
        guard header(from: userInfo) == nil,
              let key = try? PushConfiguration.keychain.loadPrivateKey(),
              let header = try? env.open(with: key) else { return }
        await presentLocally(header, eid: env.eid, sound: .default)
    }

    private static func rawDeliveredIdentifier(eid: String) async -> String? {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return delivered.first {
            PushEnvelope(userInfo: $0.request.content.userInfo)?.eid == eid
                && $0.request.content.userInfo[PushConfiguration.headerUserInfoKey] == nil
        }?.request.identifier
    }

    private static func removeRawDelivered(eid: String) async {
        if let id = await rawDeliveredIdentifier(eid: eid) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // MARK: - Background deliveries

    /// Feeds pushes decrypted while the app was not running into the
    /// arbitration ledger, and tracks their identifiers for withdrawal.
    static func syncDelivered() {
        let records = PushSharedState().load().filter { $0.receivedAt > lastSyncedEvent }
        for record in records {
            guard let resolved = resolve(record.route) else { continue }
            if let status = attentionStatus(record.status) {
                AgentAttentionNotificationRouter.externalEventDelivered(pane: resolved.surfaceID, status: status, at: record.receivedAt)
            }
        }
        if let last = records.map(\.receivedAt).max() { lastSyncedEvent = last }

        Task {
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            for n in delivered where n.request.content.categoryIdentifier == PushConfiguration.categoryIdentifier {
                if isRejected(n.request.content.userInfo) {
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [n.request.identifier])
                    continue
                }
                guard let (header, decryptedLocally) = decryptedHeader(from: n.request.content.userInfo) else { continue }
                if decryptedLocally {
                    // Delivered raw while the app was not running: replace it with the decrypted version.
                    let eid = PushEnvelope(userInfo: n.request.content.userInfo)?.eid ?? n.request.identifier
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [n.request.identifier])
                    await presentLocally(header, eid: eid, sound: n.request.content.sound)
                    continue
                }
                guard let resolved = resolve(header.route) else { continue }
                deliveredIdentifiers[resolved.surfaceID, default: []].insert(n.request.identifier)
            }
        }
        retryPending()
    }
}
