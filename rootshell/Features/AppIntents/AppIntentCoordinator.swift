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

import Foundation

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
        case openLocalShell(directory: String?)
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
}
