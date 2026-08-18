//
//  FileOpenImporter.swift
//  rootshell
//
//  Copies a file shared from another app ("Open in rootshell") into
//  ~/incoming (Documents/incoming) so the local shell's editors can read
//  and write it. Two delivery modes are handled: system-made copies in
//  Documents/Inbox (moved out — Inbox contents can't be edited in place)
//  and security-scoped URLs to external originals (copied, original left
//  untouched).
//

import Foundation

nonisolated enum FileOpenError: LocalizedError, Sendable {
    case isDirectory
    case accessDenied(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .isDirectory:
            return String(
                localized: "Folders can't be opened in the editor.",
                comment: "Error when a shared item is a folder"
            )
        case .accessDenied(let filename):
            return String(
                localized: "Rootshell wasn't granted access to \(filename).",
                comment: "Error when a shared file can't be read"
            )
        case .copyFailed(let reason):
            return String(
                localized: "The file couldn't be imported: \(reason)",
                comment: "Error when copying a shared file fails"
            )
        }
    }
}

/// Serializes imports away from the main actor. Keeping destination selection
/// and the move/copy in one actor prevents simultaneous opens of identically
/// named files from racing for the same deduped destination.
private actor FileOpenImportWorker {
    func importFile(from url: URL) throws -> String {
        try FileOpenImporter.importFileSynchronously(from: url)
    }
}

nonisolated enum FileOpenImporter {

    static let incomingDirectoryName = "incoming"
    private static let worker = FileOpenImportWorker()

    /// Imports the shared file into Documents/incoming and returns the
    /// final absolute path.
    static func importFile(from url: URL) async throws -> String {
        try await worker.importFile(from: url)
    }

    fileprivate static func importFileSynchronously(from url: URL) throws -> String {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw FileOpenError.copyFailed("Documents directory unavailable")
        }

        let incomingDir = documents.appendingPathComponent(incomingDirectoryName, isDirectory: true)
        do {
            try fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        } catch {
            throw FileOpenError.copyFailed(error.localizedDescription)
        }

        // System-made Inbox copies are ours already; no security scope needed.
        // Move (not copy) so Inbox doesn't accumulate stale duplicates.
        let inboxDir = documents.appendingPathComponent("Inbox", isDirectory: true)
        if isDescendant(url, of: inboxDir) {
            try ensureNotDirectory(url)
            let destination = dedupedDestination(for: url.lastPathComponent, in: incomingDir)
            do {
                try fm.moveItem(at: url, to: destination)
            } catch {
                throw FileOpenError.copyFailed(error.localizedDescription)
            }
            return destination.path
        }

        // External original (Files app, iCloud Drive, other providers).
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        try ensureNotDirectory(url)
        let destination = dedupedDestination(for: url.lastPathComponent, in: incomingDir)

        // Coordinated read forces iCloud items to materialize before the copy.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                try fm.copyItem(at: readURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if coordinationError != nil || copyError != nil {
            if !fm.isReadableFile(atPath: url.path) {
                throw FileOpenError.accessDenied(url.lastPathComponent)
            }
            let underlying = copyError ?? coordinationError!
            throw FileOpenError.copyFailed(underlying.localizedDescription)
        }

        return destination.path
    }

    private static func ensureNotDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            throw FileOpenError.isDirectory
        }
    }

    /// Sanitized, collision-free destination. Control characters are stripped
    /// for a usable terminal filename; shell metacharacters are preserved and
    /// escaped at command construction time. Existing names dedupe as
    /// stem-1.ext, stem-2.ext, ...
    private static func dedupedDestination(for filename: String, in directory: URL) -> URL {
        var sanitized = String(filename.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        })
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "shared-file"
        }

        let stem = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension

        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(sanitized)
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// True only when `url` is below the app's own directory. Component-wise
    /// comparison avoids treating an unrelated external path containing the
    /// text "/Documents/Inbox/" as an app-owned Inbox copy.
    private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let candidateComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let directoryComponents = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard candidateComponents.count > directoryComponents.count else { return false }
        return candidateComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }
}
