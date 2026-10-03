//
//  AttachmentUploader.swift
//  rootshell
//
//  SFTP-based uploader for paste attachments (images, PDFs, files).
//  Borrows the pane's connection when it can, else opens a parallel one via
//  SSHConnectionHelper. PipelinedTransfer handles large files.
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat
import os.log

/// Upload state for the attachment uploader
enum AttachmentUploadState {
    case idle
    case connecting
    case uploading(fileName: String, fileIndex: Int, totalFiles: Int, progress: Double)
    case completed(paths: [String])
    case failed(Error)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

/// Format for inserting the uploaded path into the terminal
enum PasteInsertFormat: String, CaseIterable, Sendable {
    case pathOnly = "path"
    case markdownImage = "markdown-image"

    var displayName: String {
        switch self {
        case .pathOnly: String(localized: "File path", comment: "Attachment upload insert format")
        case .markdownImage: String(localized: "Markdown image", comment: "Attachment upload insert format")
        }
    }

    var detail: String {
        switch self {
        case .pathOnly: String(localized: "Inserts the remote file path at cursor", comment: "Attachment upload insert format description")
        case .markdownImage: String(localized: "Inserts as ![](path) for markdown-aware tools", comment: "Attachment upload insert format description")
        }
    }

    func format(_ escapedPath: String) -> String {
        switch self {
        case .pathOnly: escapedPath
        case .markdownImage: "![](\(escapedPath))"
        }
    }
}

/// Uploads paste attachments to a remote server via SFTP
@MainActor
final class AttachmentUploader {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AttachmentUploader")

    let config: SSHConfig
    let attachments: [PasteAttachment]
    let destination: String

    private(set) var state: AttachmentUploadState = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((AttachmentUploadState) -> Void)?

    private var sshClient: SSHClient?
    private var jumpClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var uploadTask: Task<Void, Never>?
    private var isCancelled = false

    /// Opens an SFTP channel on the pane's own connection, so an upload never
    /// authenticates (and prompts Face ID) a second time.
    private let borrowedChannel: (@Sendable () async throws -> SFTPClient)?
    private var usesBorrowedChannel = false

    /// `connectionOwner` is the pane holding the connection (a tmux or herdr
    /// pane's gateway); nil always opens a separate connection.
    init(
        config: SSHConfig,
        attachments: [PasteAttachment],
        destination: String,
        connectionOwner: Ghostty.TerminalView? = nil
    ) {
        self.config = config
        self.attachments = attachments
        self.destination = destination
        if let connectionOwner {
            self.borrowedChannel = SFTPConnectionFactory.paneChannelOpener(for: connectionOwner, host: config.host)
        } else {
            self.borrowedChannel = nil
        }
    }

    /// Upload all attachments and return remote paths
    func upload() async throws -> [String] {
        state = .connecting
        var remotePaths: [String] = []

        do {
            if let borrowed = try await openBorrowedChannel() {
                sftpClient = borrowed
                usesBorrowedChannel = true
            } else {
                sftpClient = try await openOwnConnection()
            }
            guard let sftp = sftpClient else {
                throw AttachmentUploadError.sftpFailed
            }

            // Ensure destination directory exists
            try await ensureDirectory(sftp: sftp, path: destination)

            // Upload each attachment
            for (index, attachment) in attachments.enumerated() {
                try Task.checkCancellation()

                let remotePath = joinRemotePath(destination, attachment.suggestedName)
                let fileName = attachment.suggestedName

                state = .uploading(
                    fileName: fileName,
                    fileIndex: index,
                    totalFiles: attachments.count,
                    progress: 0
                )

                try await uploadAttachment(
                    attachment,
                    to: remotePath,
                    sftp: sftp,
                    fileIndex: index
                )

                remotePaths.append(remotePath)
            }

            state = .completed(paths: remotePaths)
            cleanup()
            return remotePaths

        } catch is CancellationError {
            state = .failed(AttachmentUploadError.cancelled)
            cleanup()
            throw AttachmentUploadError.cancelled
        } catch {
            if isCancelled {
                state = .failed(AttachmentUploadError.cancelled)
                cleanup()
                throw AttachmentUploadError.cancelled
            }
            state = .failed(error)
            cleanup()
            throw error
        }
    }

    /// Start upload asynchronously
    func startAsync() {
        uploadTask = Task { @MainActor in
            _ = try? await upload()
        }
    }

    /// Cancel the upload
    func cancel() {
        Self.logger.info("Attachment upload cancelled")
        isCancelled = true
        onStateChange = nil
        uploadTask?.cancel()
        uploadTask = nil
    }

    // MARK: - Private

    /// nil when there is nothing to borrow or the borrow failed. A tssh exec
    /// channel needs an sftp-server binary, where a fresh connection can still
    /// reach sshd's internal-sftp.
    private func openBorrowedChannel() async throws -> SFTPClient? {
        guard let borrowedChannel else { return nil }
        do {
            return try await borrowedChannel()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.info("Borrowed SFTP channel unavailable, opening a connection: \(error.localizedDescription)")
            return nil
        }
    }

    private func openOwnConnection() async throws -> SFTPClient {
        // Connect via SSHConnectionHelper with strict host key policy:
        // Only accept keys already verified by the main terminal session.
        // CitadelHostKeyValidatorDelegate auto-accepts known+matching keys
        // before calling this callback, so this callback only fires for
        // changed or unknown keys — which we must reject.
        let result = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: { request in
                // This callback is only reached when the key is NEW or CHANGED.
                // Known+matching keys are auto-accepted by the validator itself.
                // Reject to prevent silently trusting MITM or key rotation.
                Self.logger.warning("Upload SFTP connection rejected: host key not previously verified")
                return .reject
            }
        )
        sshClient = result.client
        jumpClient = result.jumpClient

        guard let client = sshClient else {
            throw AttachmentUploadError.connectionFailed
        }

        // Open SFTP subsystem
        return try await client.openSFTP()
    }

    private func uploadAttachment(
        _ attachment: PasteAttachment,
        to remotePath: String,
        sftp: SFTPClient,
        fileIndex: Int
    ) async throws {
        let data = attachment.data
        let fileSize = data.count

        if fileSize > 2 * 1024 * 1024 {
            // Large file: use PipelinedTransfer via temp file
            try await uploadLargeAttachment(data: data, remotePath: remotePath, sftp: sftp, fileIndex: fileIndex)
        } else {
            // Small file: direct write
            try await uploadSmallAttachment(data: data, remotePath: remotePath, sftp: sftp, fileIndex: fileIndex)
        }
    }

    private func uploadSmallAttachment(
        data: Data,
        remotePath: String,
        sftp: SFTPClient,
        fileIndex: Int
    ) async throws {
        let file = try await sftp.openFile(
            filePath: remotePath,
            flags: [.create, .truncate, .write]
        )

        var buffer = ByteBuffer()
        buffer.writeData(data)
        try await file.write(buffer, at: 0)
        try await file.close()

        state = .uploading(
            fileName: attachments[fileIndex].suggestedName,
            fileIndex: fileIndex,
            totalFiles: attachments.count,
            progress: 1.0
        )
    }

    private func uploadLargeAttachment(
        data: Data,
        remotePath: String,
        sftp: SFTPClient,
        fileIndex: Int
    ) async throws {
        // Write data to temp file for PipelinedTransfer (requires FileHandle)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try await sftp.openFile(
            filePath: remotePath,
            flags: [.create, .truncate, .write]
        )

        let localHandle = try FileHandle(forReadingFrom: tempURL)
        defer { try? localHandle.close() }

        let totalSize = UInt64(data.count)
        let fileName = attachments[fileIndex].suggestedName
        let totalFiles = attachments.count

        try await PipelinedTransfer.uploadFile(
            file: file,
            from: localHandle,
            fileSize: totalSize
        ) { @MainActor [weak self] bytesWritten in
            guard let self else { return }
            let progress = totalSize > 0 ? Double(bytesWritten) / Double(totalSize) : 0
            self.state = .uploading(
                fileName: fileName,
                fileIndex: fileIndex,
                totalFiles: totalFiles,
                progress: progress
            )
        }

        try await file.close()
    }

    private func ensureDirectory(sftp: SFTPClient, path: String) async throws {
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            // Ignore "already exists" errors
            let desc = String(describing: error).lowercased()
            if !desc.contains("exist") && !desc.contains("failure") {
                Self.logger.warning("mkdir failed for \(path): \(error)")
            }
        }
    }

    private func joinRemotePath(_ base: String, _ component: String) -> String {
        SFTPOperations.joinPath(base, component)
    }

    private func cleanup() {
        // A borrowed channel rides the pane's connection, which outlives this
        // upload, so close it explicitly. Our own connection is left to NIO.
        if usesBorrowedChannel, let sftp = sftpClient {
            Task { try? await withTimeout(seconds: 2) { try await sftp.close() } }
        }
        usesBorrowedChannel = false
        sftpClient = nil
        sshClient = nil
        jumpClient = nil
    }
}

// MARK: - Errors

enum AttachmentUploadError: LocalizedError {
    case connectionFailed
    case sftpFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to connect for upload"
        case .sftpFailed: return "Failed to open SFTP session"
        case .cancelled: return "Upload cancelled"
        }
    }
}
