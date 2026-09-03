//
//  AppIntentCoordinator.swift
//  rootshell
//
//  Buffer between App Intents / URL opens and MainView. Deposit-then-notify
//  survives the cold-start race (an intent's perform() can run before any
//  window's onReceive subscription exists, or before Ghostty finishes
//  initializing). URL/odoc opens are targeted at a scene chosen at deposit
//  time (Catalyst) and that window is surfaced; Shortcuts requests stay
//  untargeted and use key-window bias: the key window claims immediately,
//  non-key windows retry after a short delay. A watchdog releases any
//  request nobody claimed. At most one window ever acts on a request.
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

    /// A URL open is targeted at the scene chosen at deposit time; Shortcuts
    /// requests stay untargeted and go to whichever window claims first.
    private struct PendingRequest {
        let id = UUID()
        let request: IntentRequest
        var targetSceneSessionID: String?
    }

    private var pending: [PendingRequest] = []
    private static let unclaimedWatchdogDelay: TimeInterval = 2.5

    /// True when this scene has something to claim (see `consume(forScene:)`).
    func hasPending(forScene sceneSessionID: String?) -> Bool {
        !claimable(forScene: sceneSessionID).isEmpty
    }

    /// This scene's targeted requests, every untargeted one, and any whose
    /// target scene is no longer connected.
    private func claimable(forScene sceneSessionID: String?) -> [PendingRequest] {
        let liveSessionIDs = Set(UIApplication.shared.connectedScenes.map { $0.session.persistentIdentifier })
        return pending.filter { entry in
            guard let target = entry.targetSceneSessionID else { return true }
            return target == sceneSessionID || !liveSessionIDs.contains(target)
        }
    }

    func hasTargetedPending(forScene sceneSessionID: String?) -> Bool {
        guard let sceneSessionID else { return false }
        return pending.contains { $0.targetSceneSessionID == sceneSessionID }
    }

    func deposit(_ request: IntentRequest) {
        deposit(request, targetSceneSessionID: nil)
    }

    private func deposit(_ request: IntentRequest, targetSceneSessionID: String?) {
        let entry = PendingRequest(request: request, targetSceneSessionID: targetSceneSessionID)
        pending.append(entry)
        NotificationCenter.default.post(name: .appIntentRequestReceived, object: nil)
        scheduleUnclaimedWatchdog(for: entry.id)
    }

    /// Claims everything `claimable`; other live scenes' requests stay put.
    func consume(forScene sceneSessionID: String?) -> [IntentRequest] {
        let claimed = claimable(forScene: sceneSessionID)
        pending.removeAll { entry in claimed.contains { $0.id == entry.id } }
        return claimed.map(\.request)
    }

    /// A request still pending after the delay had no window claim it (the
    /// target scene died, never linked, or no regular window exists). Drop
    /// the target so any window may claim, re-notify, and surface a window.
    private func scheduleUnclaimedWatchdog(for id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.unclaimedWatchdogDelay))
            guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
            logger.error("[urlopen] unclaimed target=\(self.pending[index].targetSceneSessionID ?? "-", privacy: .public) \(Self.sceneSnapshot(), privacy: .public)")
            pending[index].targetSceneSessionID = nil
            NotificationCenter.default.post(name: .appIntentRequestReceived, object: nil)
            #if targetEnvironment(macCatalyst)
            if CatalystSceneDelegate.hasActivatedAnyScene {
                CatalystSceneDelegate.activateMainWindowForExternalEvent()
            }
            #endif
        }
    }

    /// One-line scene/key summary for the `[urlopen]` diagnostics.
    static func sceneSnapshot() -> String {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        #if targetEnvironment(macCatalyst)
        let visor = scenes.filter { CatalystSceneDelegate.isVisorScene($0) }.count
        #else
        let visor = 0
        #endif
        let key = scenes.filter { $0.keyWindow != nil }.count
        let active = scenes.filter { $0.activationState == .foregroundActive }.count
        return "scenes=\(scenes.count) visor=\(visor) key=\(key) active=\(active) appState=\(UIApplication.shared.applicationState.rawValue)"
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
    /// `deliveredTo` is the scene UIKit handed the URL to (cold-start
    /// `willConnectTo`), which may not be in `connectedScenes` yet.
    @discardableResult
    func depositURLRequest(_ request: IntentRequest, source: String, deliveredTo: UIWindowScene? = nil) -> Bool {
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

        // Pick the receiving window now rather than letting every MainView
        // race on key state, and make sure it is actually on screen. With no
        // regular window, request one; the new window adopts the request.
        #if targetEnvironment(macCatalyst)
        let target = deliveredTo.flatMap { CatalystSceneDelegate.isVisorScene($0) ? nil : $0 }
            ?? CatalystSceneDelegate.preferredRegularScene()
        logger.info("[urlopen] deposit source=\(source, privacy: .public) target=\(target?.session.persistentIdentifier ?? "-", privacy: .public) \(Self.sceneSnapshot(), privacy: .public)")
        deposit(request, targetSceneSessionID: target?.session.persistentIdentifier)
        // Before the first scene activates, launch itself is bringing up the
        // window that adopts this; requesting another would open two.
        if target != nil || CatalystSceneDelegate.hasActivatedAnyScene {
            CatalystSceneDelegate.activateMainWindowForExternalEvent(scene: target)
        }
        #else
        logger.info("[urlopen] deposit source=\(source, privacy: .public)")
        deposit(request)
        #endif
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
