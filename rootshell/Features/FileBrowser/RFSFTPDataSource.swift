//
//  RFSFTPDataSource.swift
//  rootshell
//
//  SFTP remote implementation of RFDataSource.
//  Each instance manages its own SSH + SFTP connection.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat
import os.log

/// SFTP remote data source for the rf file browser.
/// Holds its own SSHClient and SFTPClient (via Citadel).
@MainActor
final class RFSFTPDataSource: RFDataSource {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-sftp")

    let isRemote = true
    var connectionLabel: String { "\(config.username)@\(config.host)" }

    /// Whether `other` addresses the same server-side file scope, so an identical
    /// absolute path on both is literally the same file. Used only to suppress a
    /// destructive paste onto the source itself, so it errs conservative: it must
    /// be *certain* the two are the same before short-circuiting.
    ///
    /// - Account scope matters: chrooted / user-scoped servers map the same path to
    ///   different files per user, so `username` (plus `port`/`jumpHost`) must match.
    /// - The same server is often reached under different host strings — letter case
    ///   (DNS is case-insensitive) or a `.local` name vs. its resolved/cached IP —
    ///   so we match on any shared host candidate rather than the raw string.
    ///
    /// Limitation: arbitrary aliases that share no host/IP candidate (e.g. a CNAME
    /// or `/etc/hosts` entry with a wholly different name and no cached IP) can't be
    /// proven equal statically and are treated as different.
    func isSameLocation(as other: any RFDataSource) -> Bool {
        guard let other = other as? RFSFTPDataSource else { return false }
        guard config.username == other.config.username,
              config.port == other.config.port,
              Self.sameJumpLocation(config.jumpHost, other.config.jumpHost) else { return false }
        return !Self.hostCandidates(config).isDisjoint(with: Self.hostCandidates(other.config))
    }

    /// Lower-cased host plus any cached IP — the set of strings that may name this
    /// server. A non-empty intersection means the same machine.
    private static func hostCandidates(_ config: SSHConfig) -> Set<String> {
        var set: Set<String> = [config.host.lowercased()]
        if let ip = config.cachedIP, !ip.isEmpty { set.insert(ip.lowercased()) }
        return set
    }

    /// Whether two routes traverse the same jump host *location*. Compares only the
    /// location-defining fields (host/port/username) — auth details like authMethod,
    /// fallback keys, and key-resolution hints don't change which server is reached,
    /// so including them would wrongly split the same route into "different".
    private static func sameJumpLocation(_ a: SSHConfig.JumpHostConfig?,
                                         _ b: SSHConfig.JumpHostConfig?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.host.lowercased() == b.host.lowercased()
                && a.port == b.port
                && a.username == b.username
        default:
            return false
        }
    }

    let config: SSHConfig
    private var sshClient: SSHClient?
    private var jumpClient: SSHClient?
    private var sftpClient: SFTPClient?
    private(set) var homePath: String = "/"
    private var tempDir: String?

    /// Callback for host key validation prompts.
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    /// Callback for keyboard-interactive (RFC 4256) prompts (2FA/OTP/PAM). nil = cancel.
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    init(config: SSHConfig) {
        self.config = config
    }

    // MARK: - Connection Lifecycle

    /// Connect SSH and open SFTP subsystem.
    func connect() async throws {
        let result = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: onHostKeyValidation,
            onKeyboardInteractiveChallenge: onKeyboardInteractiveChallenge
        )
        sshClient = result.client
        jumpClient = result.jumpClient

        guard let client = sshClient else {
            throw SFTPError.connectionFailed(host: config.host, underlying: nil)
        }

        do {
            sftpClient = try await client.openSFTP()
        } catch {
            throw SFTPError.connectionFailed(host: config.host, underlying: error)
        }

        // Resolve home directory
        do {
            homePath = try await sftpClient!.getRealPath(atPath: ".")
        } catch {
            homePath = "/"
        }
    }

    /// Disconnect and clean up.
    func disconnect() {
        let sftp = sftpClient
        let ssh = sshClient
        let jump = jumpClient
        sftpClient = nil
        sshClient = nil
        jumpClient = nil
        Task {
            try? await sftp?.close()
            try? await ssh?.close()
            try? await jump?.close()
        }
    }

    private var sftp: SFTPClient {
        get throws {
            guard let sftp = sftpClient else { throw SFTPError.notConnected }
            return sftp
        }
    }

    // MARK: - Directory Listing

    func loadDirectory(at path: String) async throws -> [RFEntry] {
        try await SFTPOperations.listDirectoryEntries(sftp: sftp, path: path)
    }

    // MARK: - File Preview

    func readFilePreview(at path: String, maxBytes: Int) async throws -> Data? {
        try await SFTPOperations.readFileHead(sftp: sftp, path: path, maxBytes: maxBytes)
    }

    func downloadToTemp(remotePath: String, maxBytes: Int?) async throws -> String {
        let dir = ensureTempDir()
        // Use a UUID subdirectory to avoid collisions while preserving the
        // original filename — bat needs the extension for language detection.
        let subdir = (dir as NSString).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        let filename = (remotePath as NSString).lastPathComponent
        let localPath = (subdir as NSString).appendingPathComponent(filename)

        if let maxBytes {
            // Partial download for size-capped previews
            let data = try await SFTPOperations.readFileHead(sftp: sftp, path: remotePath, maxBytes: maxBytes)
            try data.write(to: URL(fileURLWithPath: localPath))
        } else {
            // Full download (for images, etc.)
            try await SFTPOperations.downloadFile(sftp: sftp, remotePath: remotePath, localPath: localPath)
        }

        return localPath
    }

    func cleanupTempFiles() {
        guard let dir = tempDir else { return }
        try? FileManager.default.removeItem(atPath: dir)
        tempDir = nil
    }

    private func ensureTempDir() -> String {
        if let dir = tempDir { return dir }
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("rf-sftp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDir = dir
        return dir
    }

    // MARK: - File Operations

    func createDirectory(at path: String) async throws {
        try await sftp.createDirectory(atPath: path)
    }

    func createFile(at path: String) async throws {
        let file = try await sftp.openFile(filePath: path, flags: [.create, .write, .truncate])
        try await file.close()
    }

    func rename(from oldPath: String, to newPath: String) async throws {
        try await sftp.rename(at: oldPath, to: newPath)
    }

    func fileExists(at path: String) async -> Bool {
        do {
            _ = try await sftp.getAttributes(at: path)
            return true
        } catch {
            return false
        }
    }

    func delete(at path: String) async throws {
        let attrs = try await sftp.getAttributes(at: path)
        if SFTPOperations.isDirectory(attrs) {
            try await deleteDirectoryRecursive(path: path)
        } else {
            try await sftp.remove(at: path)
        }
    }

    /// Recursively delete a remote directory and all its contents.
    private func deleteDirectoryRecursive(path: String) async throws {
        let entries = try await SFTPOperations.listDirectoryEntries(sftp: sftp, path: path)
        for entry in entries {
            try Task.checkCancellation()
            if entry.isDirectory {
                try await deleteDirectoryRecursive(path: entry.path)
            } else {
                try await sftp.remove(at: entry.path)
            }
        }
        try await sftp.rmdir(at: path)
    }

    func copyFile(sourcePath: String, destPath: String, force: Bool) async throws {
        // Copying a file onto itself is a no-op. Bail before any I/O: the upload
        // opens the destination with .truncate, so re-writing the source onto itself
        // could corrupt the original if the upload fails midway.
        if sourcePath == destPath { return }
        let attrs = try await sftp.getAttributes(at: sourcePath)
        if SFTPOperations.isDirectory(attrs) {
            try await copyDirectoryRecursive(sourcePath: sourcePath, destPath: destPath, force: force)
        } else {
            // SFTP has no server-side copy — download to temp then re-upload
            let tempPath = (ensureTempDir() as NSString).appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(atPath: tempPath) }

            try await SFTPOperations.downloadFile(sftp: sftp, remotePath: sourcePath, localPath: tempPath)
            if force { try? await sftp.remove(at: destPath) }
            try await SFTPOperations.uploadFile(sftp: sftp, localPath: tempPath, remotePath: destPath)
        }
    }

    /// Recursively copy a remote directory.
    private func copyDirectoryRecursive(sourcePath: String, destPath: String, force: Bool) async throws {
        if force { try? await delete(at: destPath) }
        try await sftp.createDirectory(atPath: destPath)
        let entries = try await SFTPOperations.listDirectoryEntries(sftp: sftp, path: sourcePath)
        for entry in entries {
            try Task.checkCancellation()
            let dest = SFTPOperations.joinPath(destPath, entry.name)
            try await copyFile(sourcePath: entry.path, destPath: dest, force: force)
        }
    }

    func moveFile(sourcePath: String, destPath: String, force: Bool) async throws {
        // Moving a file onto itself is a no-op; bail before the destructive delete.
        if sourcePath == destPath { return }
        if force {
            // Delete destination (could be file or directory)
            try? await delete(at: destPath)
        }
        try await sftp.rename(at: sourcePath, to: destPath)
    }

    // MARK: - Cross-Source Transfer

    func downloadToLocal(remotePath: String, localPath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        // Check if source is a directory
        let attrs = try await sftp.getAttributes(at: remotePath)
        if SFTPOperations.isDirectory(attrs) {
            try await downloadDirectoryToLocal(remotePath: remotePath, localPath: localPath, onProgress: onProgress)
        } else {
            try await SFTPOperations.downloadFile(
                sftp: sftp, remotePath: remotePath, localPath: localPath,
                onProgress: onProgress
            )
        }
    }

    /// Recursively download a remote directory to a local path.
    /// Does not use withIntermediateDirectories to avoid silently merging
    /// into an existing directory — the caller handles force-delete first.
    private func downloadDirectoryToLocal(remotePath: String, localPath: String,
                                          onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(atPath: localPath, withIntermediateDirectories: false)
        let entries = try await SFTPOperations.listDirectoryEntries(sftp: sftp, path: remotePath)
        for entry in entries {
            try Task.checkCancellation()
            let dest = (localPath as NSString).appendingPathComponent(entry.name)
            try await downloadToLocal(remotePath: entry.path, localPath: dest, onProgress: onProgress)
        }
    }

    func uploadFromLocal(localPath: String, remotePath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        // Check if source is a directory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: localPath, isDirectory: &isDir), isDir.boolValue {
            try await uploadDirectoryFromLocal(localPath: localPath, remotePath: remotePath, onProgress: onProgress)
            return
        }
        try await SFTPOperations.uploadFile(
            sftp: sftp, localPath: localPath, remotePath: remotePath,
            onProgress: onProgress
        )
    }

    /// Recursively upload a local directory to a remote path.
    private func uploadDirectoryFromLocal(localPath: String, remotePath: String,
                                          onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try await sftp.createDirectory(atPath: remotePath)
        let contents = try FileManager.default.contentsOfDirectory(atPath: localPath)
        for name in contents {
            try Task.checkCancellation()
            let src = (localPath as NSString).appendingPathComponent(name)
            let dest = SFTPOperations.joinPath(remotePath, name)
            try await uploadFromLocal(localPath: src, remotePath: dest, onProgress: onProgress)
        }
    }

    // MARK: - Path Utilities

    func resolveHomePath() async throws -> String {
        homePath
    }

    func joinPath(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    func parentPath(of path: String) -> String {
        SFTPOperations.parentPath(of: path)
    }
}

#endif
