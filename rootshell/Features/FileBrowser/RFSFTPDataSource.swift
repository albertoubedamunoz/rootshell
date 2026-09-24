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
    /// destructive paste onto the source itself.
    func isSameLocation(as other: any RFDataSource) -> Bool {
        guard let other = other as? RFSFTPDataSource else { return false }
        return config.reachesSameAccount(as: other.config)
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

    private var fileSystem: FileSystemEndpoint {
        get throws { FileSystemEndpoint(backend: .sftp(try sftp)) }
    }

    /// Runs a tree copy while reporting cumulative bytes, as rf's callers expect.
    private func copyTree(
        _ source: String, to destination: String,
        from sourceFS: FileSystemEndpoint, to destinationFS: FileSystemEndpoint,
        onProgress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws {
        var total: Int64 = 0
        try await FileTreeCopier.copyTree(source, to: destination, from: sourceFS, to: destinationFS) { delta in
            total += delta
            onProgress(total)
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

    /// Deletes a file, or a directory and its contents. A symlinked directory is
    /// unlinked, never descended into.
    func delete(at path: String) async throws {
        try await fileSystem.removeRecursively(path)
    }

    func copyFile(sourcePath: String, destPath: String, force: Bool) async throws {
        // Copying a file onto itself is a no-op. Bail before any I/O: the copy
        // opens the destination with .truncate, so re-writing the source onto itself
        // could corrupt the original if the copy fails midway.
        if sourcePath == destPath { return }
        let fs = try fileSystem
        if force, await fs.exists(destPath) { try await fs.removeRecursively(destPath) }
        // SFTP has no server-side copy; bytes stream through the app with no temp file.
        try await copyTree(sourcePath, to: destPath, from: fs, to: fs)
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
        try await copyTree(
            remotePath, to: localPath,
            from: fileSystem, to: FileSystemEndpoint(backend: .local(.current())),
            onProgress: onProgress
        )
    }

    func uploadFromLocal(localPath: String, remotePath: String,
                         onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try await copyTree(
            localPath, to: remotePath,
            from: FileSystemEndpoint(backend: .local(.current())), to: fileSystem,
            onProgress: onProgress
        )
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
