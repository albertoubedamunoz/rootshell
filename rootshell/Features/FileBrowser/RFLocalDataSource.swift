//
//  RFLocalDataSource.swift
//  rootshell
//
//  Local filesystem implementation of RFDataSource.
//  Wraps FileManager operations, preserving existing rf behavior.
//

#if !targetEnvironment(macCatalyst)

import Foundation

/// Local filesystem data source for the rf file browser.
/// All operations delegate to FileManager and are effectively synchronous.
@MainActor
final class RFLocalDataSource: RFDataSource {

    let isRemote = false
    let connectionLabel = "Local"

    /// Any local source addresses the same device filesystem.
    func isSameLocation(as other: any RFDataSource) -> Bool {
        other is RFLocalDataSource
    }

    // MARK: - Directory Listing

    func loadDirectory(at path: String) async throws -> [RFEntry] {
        RFEntry.loadDirectory(at: path)
    }

    // MARK: - File Preview

    func readFilePreview(at path: String, maxBytes: Int) async throws -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { fh.closeFile() }
        return fh.readData(ofLength: maxBytes)
    }

    func downloadToTemp(remotePath: String, maxBytes: Int?) async throws -> String {
        // Local files don't need temp copies — return the path as-is
        remotePath
    }

    func cleanupTempFiles() {
        // Nothing to clean up for local files
    }

    // MARK: - File Operations

    func createDirectory(at path: String) async throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: false
        )
    }

    func createFile(at path: String) async throws {
        FileManager.default.createFile(atPath: path, contents: nil)
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
    }

    func fileExists(at path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func delete(at path: String) async throws {
        try FileManager.default.removeItem(atPath: path)
    }

    func copyFile(sourcePath: String, destPath: String, force: Bool) async throws {
        let fm = FileManager.default
        // Copying a file onto itself is a no-op; bail before the destructive remove
        // so the source is never deleted.
        if (sourcePath as NSString).standardizingPath == (destPath as NSString).standardizingPath {
            return
        }
        if force, fm.fileExists(atPath: destPath) {
            try fm.removeItem(atPath: destPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: destPath)
    }

    func moveFile(sourcePath: String, destPath: String, force: Bool) async throws {
        let fm = FileManager.default
        // Moving a file onto itself is a no-op; bail before the destructive remove.
        if (sourcePath as NSString).standardizingPath == (destPath as NSString).standardizingPath {
            return
        }
        if force, fm.fileExists(atPath: destPath) {
            try fm.removeItem(atPath: destPath)
        }
        try fm.moveItem(atPath: sourcePath, toPath: destPath)
    }

    // MARK: - Cross-Source Transfer

    func downloadToLocal(remotePath: String, localPath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.copyItem(atPath: remotePath, toPath: localPath)
    }

    func uploadFromLocal(localPath: String, remotePath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.copyItem(atPath: localPath, toPath: remotePath)
    }

    // MARK: - Path Utilities

    func resolveHomePath() async throws -> String {
        NSHomeDirectory()
    }

    func joinPath(_ base: String, _ component: String) -> String {
        (base as NSString).appendingPathComponent(component)
    }

    func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

#endif
