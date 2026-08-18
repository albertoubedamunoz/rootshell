//
//  RFDataSource.swift
//  rootshell
//
//  Protocol abstracting filesystem I/O for the rf file browser.
//  Allows local (FileManager) and remote (SFTP) backends to be
//  used interchangeably.
//

#if !targetEnvironment(macCatalyst)

import Foundation

/// Abstracts filesystem I/O for the rf file browser.
/// Each RFTab holds a reference to its data source, enabling
/// local and SFTP tabs to coexist within the same RFCommand.
@MainActor
protocol RFDataSource: AnyObject {
    /// Whether this data source operates over a network connection.
    /// When true, RF disables git status, search, editor, and drop-to-shell.
    var isRemote: Bool { get }

    /// Display label for the connection (e.g., "user@host" or "Local").
    var connectionLabel: String { get }

    /// Whether `other` refers to the same underlying location — the same device
    /// for local sources, the same server for remote ones — so an identical path
    /// on both is literally the same file even when the two sources are distinct
    /// objects (e.g. two tabs opened on the same host). Used to detect a paste
    /// onto the source file itself before any destructive transfer.
    func isSameLocation(as other: any RFDataSource) -> Bool

    // MARK: - Directory Listing

    /// Load directory entries at the given path.
    func loadDirectory(at path: String) async throws -> [RFEntry]

    // MARK: - File Preview

    /// Read up to `maxBytes` from the beginning of a file for preview.
    /// Returns nil if the file cannot be read.
    func readFilePreview(at path: String, maxBytes: Int) async throws -> Data?

    /// Download a remote file to a local temp path for preview (images, etc.).
    /// For local sources, returns the original path unchanged.
    /// `maxBytes` caps the download size; nil means no cap.
    func downloadToTemp(remotePath: String, maxBytes: Int?) async throws -> String

    /// Clean up any temp files created by `downloadToTemp`.
    func cleanupTempFiles()

    // MARK: - File Operations

    /// Create a directory at the given path.
    func createDirectory(at path: String) async throws

    /// Create an empty file at the given path.
    func createFile(at path: String) async throws

    /// Rename or move a file/directory.
    func rename(from oldPath: String, to newPath: String) async throws

    /// Check whether a file or directory exists at the given path.
    func fileExists(at path: String) async -> Bool

    /// Delete a file or directory.
    func delete(at path: String) async throws

    /// Copy a file within this data source.
    func copyFile(sourcePath: String, destPath: String, force: Bool) async throws

    /// Move a file within this data source.
    func moveFile(sourcePath: String, destPath: String, force: Bool) async throws

    // MARK: - Cross-Source Transfer

    /// Download a remote file to a local path.
    /// For local sources, this is equivalent to copyFile.
    func downloadToLocal(remotePath: String, localPath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws

    /// Upload a local file to this data source's remote path.
    /// For local sources, this is equivalent to copyFile.
    func uploadFromLocal(localPath: String, remotePath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws

    // MARK: - Path Utilities

    /// Resolve the home/initial directory path.
    func resolveHomePath() async throws -> String

    /// Join two path components.
    func joinPath(_ base: String, _ component: String) -> String

    /// Get the parent directory of a path.
    func parentPath(of path: String) -> String
}

#endif
