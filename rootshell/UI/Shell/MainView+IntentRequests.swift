//
//  MainView+IntentRequests.swift
//  rootshell
//
//  Consumes requests deposited by AppIntentCoordinator (Shortcuts actions
//  and ssh:///mosh:// URL opens) and routes each to the existing handler.
//

import SwiftUI
import UIKit
import os

extension MainView {

    /// Drains AppIntentCoordinator requests into tabs. Safe to call on every
    /// .appIntentRequestReceived and from the handleOnAppear cold-start
    /// sweep: the buffer is consume-once, so only the first window to claim
    /// acts. With multiple windows, non-key windows defer briefly so the key
    /// window wins; if no window is key (cold-start foregrounding), the
    /// deferred pass still claims — a request is never dropped.
    func consumePendingIntentRequests(retriesRemaining: Int = 20) {
        guard AppIntentCoordinator.shared.hasPending else { return }

        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        if windowScenes.count > 1 && !windowIsKeyWindow {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard AppIntentCoordinator.shared.hasPending else { return }
                dispatchIntentRequests(retriesRemaining: retriesRemaining)
            }
            return
        }

        dispatchIntentRequests(retriesRemaining: retriesRemaining)
    }

    private func dispatchIntentRequests(retriesRemaining: Int) {
        // On cold start Ghostty may still be initializing, and
        // openTerminalTab drops tab requests until ghosttyApp.app exists.
        // Hold the requests and retry briefly instead of losing them.
        guard ghosttyApp.app != nil else {
            guard retriesRemaining > 0 else {
                Ghostty.logger.error("Giving up on intent request: Ghostty never initialized")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                dispatchIntentRequests(retriesRemaining: retriesRemaining - 1)
            }
            return
        }

        dispatchClaimedIntentRequests(AppIntentCoordinator.shared.consumeAll())
    }

    /// Routes already-claimed requests (AppleScript `create window` hands a
    /// fresh window its staged requests this way). Same Ghostty-init retry
    /// as the buffered path.
    func dispatchClaimedIntentRequests(_ requests: [AppIntentCoordinator.IntentRequest], retriesRemaining: Int = 20) {
        guard !requests.isEmpty else { return }
        guard ghosttyApp.app != nil else {
            guard retriesRemaining > 0 else {
                Ghostty.logger.error("Giving up on intent request: Ghostty never initialized")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                dispatchClaimedIntentRequests(requests, retriesRemaining: retriesRemaining - 1)
            }
            return
        }

        for request in requests {
            switch request {
            case .openProfile(let profileRequest):
                handleProfileIntent(profileRequest)
            case .openLocalShell(let directory, let command):
                createLocalShellTab(intentDirectory: directory, startupCommand: command)
            case .openSSH(let components):
                handleSSHURL(components)
            case .openMosh(let components):
                handleMoshURL(components)
            }
        }
    }
}
