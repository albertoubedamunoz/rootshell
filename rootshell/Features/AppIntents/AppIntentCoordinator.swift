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

    // MARK: - New-window requests

    private var pendingForNewWindow: [IntentRequest] = []
    private var newWindowExpiry: Task<Void, Never>?

    /// Stage `request` for a window that is created right here (the same
    /// nil-session activation Cmd-N uses). Expires after a few seconds so a
    /// stale entry can never hijack a later, unrelated new window.
    func depositForNewWindow(_ request: IntentRequest) {
        // Cold launch: the first window is already on its way, so let it
        // claim the request rather than opening a second window.
        let hasWindow = UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene }
        guard hasWindow else {
            deposit(request)
            return
        }
        pendingForNewWindow.append(request)
        newWindowExpiry?.cancel()
        newWindowExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingForNewWindow.removeAll()
        }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    /// Consume-once: the first empty window to appear takes them all.
    func claimNewWindowRequests() -> [IntentRequest] {
        defer {
            pendingForNewWindow.removeAll()
            newWindowExpiry?.cancel()
            newWindowExpiry = nil
        }
        return pendingForNewWindow
    }
}
