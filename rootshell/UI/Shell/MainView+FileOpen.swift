//
//  MainView+FileOpen.swift
//  rootshell
//
//  Consumes shared-file open events deposited by FileOpenCoordinator
//  ("Open in rootshell" from other apps) and turns each into a local-shell
//  tab that launches $EDITOR on the imported file.
//

import SwiftUI
import os

extension MainView {

    /// Drains this window's FileOpenCoordinator events into editor tabs. Safe
    /// to call on every .fileOpenReceived and from the handleOnAppear
    /// cold-start sweep: events are consumed only by their target window.
    func consumePendingFileOpens(retriesRemaining: Int = 20) {
        guard FileOpenCoordinator.shared.hasPending(for: windowId) else { return }

        // On cold start Ghostty may still be initializing, and
        // openTerminalTab drops tab requests until ghosttyApp.app exists.
        // Hold the events and retry briefly instead of losing the file.
        guard ghosttyApp.app != nil else {
            guard retriesRemaining > 0 else {
                Ghostty.logger.error("Giving up on shared-file open: Ghostty never initialized")
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                consumePendingFileOpens(retriesRemaining: retriesRemaining - 1)
            }
            return
        }

        for event in FileOpenCoordinator.shared.consumePending(for: windowId) {
            switch event {
            case .open(let path):
                createFileEditorTab(filePath: path)
            case .failed(let filename, let message):
                alerts.handleFileOpenFailure(message: "\(filename): \(message)")
            }
        }
    }
}
