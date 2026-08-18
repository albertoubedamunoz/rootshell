//
//  OpenLocalShellIntent.swift
//  rootshell
//
//  Shortcuts action that opens a new local shell tab.
//

import AppIntents

/// Shortcuts action: open a local shell tab, optionally in a directory.
struct OpenLocalShellIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Local Shell"
    static var description: IntentDescription = "Opens a new local shell tab."
    static var openAppWhenRun = true

    @Parameter(title: "Directory", description: "Working directory for the new shell, relative to the rootshell home folder unless absolute.")
    var directory: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        AppIntentCoordinator.shared.deposit(.openLocalShell(directory: directory))
        return .result()
    }
}
