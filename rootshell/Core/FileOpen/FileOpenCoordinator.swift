//
//  FileOpenCoordinator.swift
//  rootshell
//
//  Window-targeted buffer between the system's file-open delivery
//  (CFBundleDocumentTypes → .onOpenURL) and MainView. Deposit-then-notify
//  survives the cold-start race (a file can arrive before the target window's
//  onReceive subscription or before Ghostty finishes initializing). Each
//  event carries the receiving MainView's window ID, so global notification
//  fan-out cannot let a different window steal the editor tab.
//
//  iOS/iPadOS/visionOS only: on macOS the coordinator turns file URLs into
//  an unsupported-platform alert (registration is shared through Info.plist).
//

import Foundation
import os.log

extension Notification.Name {
    /// Posted after a shared file was imported (or failed to import).
    /// Carries no payload — consumers pull from FileOpenCoordinator.
    static let fileOpenReceived = Notification.Name("fileOpenReceived")
}

@MainActor
final class FileOpenCoordinator {
    static let shared = FileOpenCoordinator()

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "FileOpenCoordinator"
    )

    enum FileOpenEvent {
        case open(path: String)
        case failed(filename: String, message: String)
    }

    private struct PendingFileOpen {
        let targetWindowID: String
        let event: FileOpenEvent
    }

    private var pending: [PendingFileOpen] = []

    func hasPending(for windowID: String) -> Bool {
        pending.contains { $0.targetWindowID == windowID }
    }

    func handleIncomingFileURL(_ url: URL, targetWindowID: String) {
        #if targetEnvironment(macCatalyst)
        let path = url.path
        let filename = url.lastPathComponent
        let message = String(
            localized: "Opening shared files isn't supported on macOS.",
            comment: "Error when opening a shared file on macOS"
        )
        Self.logger.info("Rejecting unsupported file-open request on macOS: \(path, privacy: .private)")
        pending.append(PendingFileOpen(
            targetWindowID: targetWindowID,
            event: .failed(filename: filename, message: message)
        ))
        NotificationCenter.default.post(name: .fileOpenReceived, object: nil)
        #else
        let filename = url.lastPathComponent
        Task { @MainActor in
            do {
                let importedPath = try await FileOpenImporter.importFile(from: url)
                Self.logger.info("Imported shared file to \(importedPath, privacy: .private)")
                pending.append(PendingFileOpen(
                    targetWindowID: targetWindowID,
                    event: .open(path: importedPath)
                ))
            } catch {
                let message = error.localizedDescription
                Self.logger.error("Failed to import shared file \(filename, privacy: .public): \(message, privacy: .public)")
                pending.append(PendingFileOpen(
                    targetWindowID: targetWindowID,
                    event: .failed(filename: filename, message: message)
                ))
            }
            NotificationCenter.default.post(name: .fileOpenReceived, object: nil)
        }
        #endif
    }

    /// Empties and returns only the events routed to this window.
    func consumePending(for windowID: String) -> [FileOpenEvent] {
        let events = pending.compactMap { pendingEvent in
            pendingEvent.targetWindowID == windowID ? pendingEvent.event : nil
        }
        pending.removeAll { $0.targetWindowID == windowID }
        return events
    }
}
