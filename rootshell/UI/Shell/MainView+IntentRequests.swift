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
        // A request claimed here would open its tab off-screen; the visor's
        // terminal comes from VisorController alone.
        guard !isVisorWindow else { return }
        guard AppIntentCoordinator.shared.hasPending else { return }

        // The hidden visor scene stays connected once summoned. Counting it
        // would push a lone visible window into the deferred branch below and
        // let the visor race it for the request.
        let connected = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        #if targetEnvironment(macCatalyst)
        let windowScenes = connected.filter { !CatalystSceneDelegate.isVisorScene($0) }
        #else
        let windowScenes = connected
        #endif
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

        let claimed = AppIntentCoordinator.shared.consumeAll()
        guard !claimed.isEmpty else { return }
        Ghostty.logger.info("[urlopen] claim window=\(windowId, privacy: .public) key=\(windowIsKeyWindow) count=\(claimed.count)")
        dispatchClaimedIntentRequests(claimed)
    }

    /// Catalyst empty-window bring-up: a request deposited before this window
    /// appeared is this window's content, so it becomes the FIRST tab instead
    /// of a default shell followed by a second one. Claim and dispatch are one
    /// MainActor step; `false` means nothing was pending and the caller must
    /// fall back to its default shell.
    @discardableResult
    func adoptPendingIntentRequestsAsFirstContent() -> Bool {
        guard !isVisorWindow, AppIntentCoordinator.shared.hasPending else { return false }
        let requests = AppIntentCoordinator.shared.consumeAll()
        guard !requests.isEmpty else { return false }
        Ghostty.logger.info("[urlopen] adopt-as-first window=\(windowId, privacy: .public) count=\(requests.count)")
        dispatchClaimedIntentRequests(requests)
        return true
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
                Ghostty.logger.info("[urlopen] dispatch window=\(windowId, privacy: .public) dir=\(directory ?? "-", privacy: .private)")
                createLocalShellTab(intentDirectory: directory, startupCommand: command)
            case .openSSH(let components):
                handleSSHURL(components)
            case .openMosh(let components):
                handleMoshURL(components)
            }
        }
    }
}
