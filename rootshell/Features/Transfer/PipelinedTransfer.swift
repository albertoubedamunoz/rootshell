//
//  PipelinedTransfer.swift
//  rootshell
//
//  Pipelined SFTP file transfer utility for concurrent chunk I/O.
//  Used by both SFTPSession and SCPTransfer to overlap network round-trips.
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat
import os.log

/// Pipelined SFTP transfer operations that overlap multiple read/write requests
/// to minimize latency overhead on high-RTT links.
enum PipelinedTransfer {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "PipelinedTransfer")

    /// Number of concurrent SFTP requests in flight
    static let pipelineDepth = 8

    /// Chunk size per request (1MB)
    nonisolated static let chunkSize: UInt32 = 1_048_576

    /// Files below this size use sequential transfer (2MB)
    static let pipelineThreshold: UInt64 = 2_097_152

    // MARK: - Error Type

    /// Wraps local filesystem I/O failures so callers can distinguish them from SFTP errors.
    struct LocalIOError: Error {
        let underlying: Error
    }

    // MARK: - Sendable Wrapper

    /// Wrapper around SFTPFile for use in task group closures.
    /// Safe because SFTPFile operations dispatch to the NIO EventLoop internally.
    struct SendableSFTPFile: @unchecked Sendable {
        let file: SFTPFile
    }

    // MARK: - Download

    /// Download a remote file using pipelined reads for large files.
    ///
    /// - Parameters:
    ///   - file: Open SFTPFile handle (must have read access)
    ///   - fileSize: Known file size, or nil to fall back to sequential
    ///   - localHandle: FileHandle open for writing to the destination
    ///   - onProgress: Called with cumulative bytes written so far
    static func downloadFile(
        file: SFTPFile,
        fileSize: UInt64?,
        to localHandle: FileHandle,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        guard let fileSize, fileSize >= pipelineThreshold else {
            try await downloadSequential(file: file, to: localHandle, onProgress: onProgress)
            return
        }

        let sendableFile = SendableSFTPFile(file: file)
        let totalChunks = Int((fileSize + UInt64(chunkSize) - 1) / UInt64(chunkSize))
        var nextChunkToSubmit = 0
        var nextChunkToWrite = 0
        var inFlight = 0
        var pendingChunks: [Int: Data] = [:]
        var totalBytesWritten: Int64 = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            // Each child task reads its full byte range, looping on short reads.
            // SFTP servers commonly cap read responses (e.g. OpenSSH: 256KB max),
            // so a single read(length: 1MB) may return far less than requested.
            func submitChunkRead(_ chunkIndex: Int) {
                let rangeStart = UInt64(chunkIndex) * UInt64(chunkSize)
                let rangeEnd = min(rangeStart + UInt64(chunkSize), fileSize)
                inFlight += 1
                group.addTask {
                    var accumulated = Data()
                    var currentOffset = rangeStart
                    while currentOffset < rangeEnd {
                        let remaining = UInt32(rangeEnd - currentOffset)
                        var buffer = try await sendableFile.file.read(from: currentOffset, length: remaining)
                        if buffer.readableBytes == 0 { break }
                        let data = buffer.readData(length: buffer.readableBytes) ?? Data()
                        accumulated.append(data)
                        currentOffset += UInt64(data.count)
                    }
                    return (chunkIndex, accumulated)
                }
            }

            // Seed the pipeline with initial batch
            let initialBatch = min(pipelineDepth, totalChunks)
            for i in 0..<initialBatch {
                submitChunkRead(i)
            }
            nextChunkToSubmit = initialBatch

            // Process results and submit new chunks as slots free up
            for try await (chunkIndex, data) in group {
                try Task.checkCancellation()
                inFlight -= 1

                pendingChunks[chunkIndex] = data

                // Flush contiguous chunks to disk in order
                while let chunk = pendingChunks[nextChunkToWrite] {
                    pendingChunks.removeValue(forKey: nextChunkToWrite)
                    if !chunk.isEmpty {
                        do {
                            try localHandle.write(contentsOf: chunk)
                        } catch {
                            throw LocalIOError(underlying: error)
                        }
                        totalBytesWritten += Int64(chunk.count)
                        onProgress(totalBytesWritten)
                    }
                    nextChunkToWrite += 1
                }

                // Refill: keep inFlight at pipelineDepth, bounded by pending buffer
                while nextChunkToSubmit < totalChunks
                    && inFlight < pipelineDepth
                    && pendingChunks.count < pipelineDepth
                {
                    submitChunkRead(nextChunkToSubmit)
                    nextChunkToSubmit += 1
                }
            }

            // Flush any remaining chunks
            while let chunk = pendingChunks[nextChunkToWrite] {
                pendingChunks.removeValue(forKey: nextChunkToWrite)
                if !chunk.isEmpty {
                    do {
                        try localHandle.write(contentsOf: chunk)
                    } catch {
                        throw LocalIOError(underlying: error)
                    }
                    totalBytesWritten += Int64(chunk.count)
                    onProgress(totalBytesWritten)
                }
                nextChunkToWrite += 1
            }
        }
    }

    // MARK: - Upload

    /// Upload a local file using pipelined writes for large files.
    ///
    /// - Parameters:
    ///   - file: Open SFTPFile handle (must have write access)
    ///   - localHandle: FileHandle open for reading from the source
    ///   - fileSize: Known file size, or nil to fall back to sequential
    ///   - onProgress: Called with cumulative bytes submitted so far
    static func uploadFile(
        file: SFTPFile,
        from localHandle: FileHandle,
        fileSize: UInt64?,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        guard let fileSize, fileSize >= pipelineThreshold else {
            try await uploadSequential(file: file, from: localHandle, onProgress: onProgress)
            return
        }

        let sendableFile = SendableSFTPFile(file: file)
        var bytesRead: UInt64 = 0
        var bytesCompleted: Int64 = 0

        // Pre-read chunks sequentially, tracking cumulative offset from actual bytes read
        // (FileHandle.read can return fewer bytes than requested)
        func readNextChunk() throws -> (Data, UInt64)? {
            let data: Data?
            do {
                data = try localHandle.read(upToCount: Int(chunkSize))
            } catch {
                throw LocalIOError(underlying: error)
            }
            guard let data, !data.isEmpty else { return nil }
            let offset = bytesRead
            bytesRead += UInt64(data.count)
            return (data, offset)
        }

        try await withThrowingTaskGroup(of: Int64.self) { group in
            // Seed the pipeline
            for _ in 0..<pipelineDepth {
                guard let (data, offset) = try readNextChunk() else { break }
                let chunkData = data
                let chunkOffset = offset
                let byteCount = Int64(data.count)
                group.addTask {
                    var buffer = ByteBuffer()
                    buffer.writeData(chunkData)
                    try await sendableFile.file.write(buffer, at: chunkOffset)
                    return byteCount
                }
            }

            // As writes complete, submit more
            for try await bytesWritten in group {
                try Task.checkCancellation()
                bytesCompleted += bytesWritten
                onProgress(bytesCompleted)

                if let (data, offset) = try readNextChunk() {
                    let chunkData = data
                    let chunkOffset = offset
                    let byteCount = Int64(data.count)
                    group.addTask {
                        var buffer = ByteBuffer()
                        buffer.writeData(chunkData)
                        try await sendableFile.file.write(buffer, at: chunkOffset)
                        return byteCount
                    }
                }
            }
        }
    }

    // MARK: - Sequential Fallbacks

    /// Sequential download for small files or unknown sizes, using the larger 1MB chunk size.
    private static func downloadSequential(
        file: SFTPFile,
        to localHandle: FileHandle,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        var offset: UInt64 = 0
        var totalBytesWritten: Int64 = 0

        while true {
            try Task.checkCancellation()
            var buffer = try await file.read(from: offset, length: chunkSize)
            if buffer.readableBytes == 0 { break }

            guard let data = buffer.readData(length: buffer.readableBytes) else { break }
            do {
                try localHandle.write(contentsOf: data)
            } catch {
                throw LocalIOError(underlying: error)
            }

            offset += UInt64(data.count)
            totalBytesWritten += Int64(data.count)
            onProgress(totalBytesWritten)
        }
    }

    /// Sequential upload for small files or unknown sizes, using the larger 1MB chunk size.
    private static func uploadSequential(
        file: SFTPFile,
        from localHandle: FileHandle,
        onProgress: @MainActor (Int64) -> Void
    ) async throws {
        var offset: UInt64 = 0
        var totalBytesWritten: Int64 = 0

        while true {
            try Task.checkCancellation()
            let data: Data?
            do {
                data = try localHandle.read(upToCount: Int(chunkSize))
            } catch {
                throw LocalIOError(underlying: error)
            }
            guard let data, !data.isEmpty else { break }

            var buffer = ByteBuffer()
            buffer.writeData(data)
            try await file.write(buffer, at: offset)

            offset += UInt64(data.count)
            totalBytesWritten += Int64(data.count)
            onProgress(totalBytesWritten)
        }
    }
}
