//
//  S3ObjectStreams.swift
//  rootshell
//
//  ChunkReader and ChunkWriter over S3 objects, so PipelinedTransfer and
//  FileTreeCopier move bytes to and from storage like any other endpoint.
//  Reads are ranged GETs; writes are reassembled in order into multipart
//  upload parts, or a single PUT for small files.
//

import Foundation
import NIOCore
import SotoS3
import UniformTypeIdentifiers

/// Ranged GETs pinned to the ETag seen at open, so an object replaced
/// mid-copy fails the copy instead of mixing two versions.
nonisolated struct S3ObjectReader: ChunkReader {
    let service: S3
    let bucket: String
    let key: String
    let size: UInt64
    let eTag: String?

    func read(at offset: UInt64, length: UInt32) async throws -> Data {
        guard offset < size, length > 0 else { return Data() }
        let end = min(offset + UInt64(length), size) - 1
        do {
            let output = try await service.getObject(.init(bucket: bucket, ifMatch: eTag, key: key, range: "bytes=\(offset)-\(end)"))
            let buffer = try await output.body.collect(upTo: Int(end - offset + 1))
            return Data(buffer.readableBytesView)
        } catch {
            throw StorageError.from(error, path: key)
        }
    }

    func close() async throws {}
}

/// Positional writes arrive out of order from the pipeline; contiguous bytes
/// are cut into parts and uploaded while later chunks are still being read.
/// The object only appears when the upload completes, so a failed or
/// aborted copy leaves any existing object untouched.
actor S3ObjectWriter: ChunkWriter {
    /// Parts start at 8 MB and double every 1,000 parts to stay within
    /// S3's 10,000-part limit, allowing objects of roughly 500 GB.
    private static let basePartSize = 8 << 20
    private static let maxPartSize = 64 << 20
    /// Bytes buffered in parts not yet uploaded before writes wait.
    private static let inFlightBudget = 64 << 20
    /// Bytes parked ahead of a missing earlier chunk before later writes wait for it.
    private static let outOfOrderBudget = 16 << 20

    nonisolated let service: S3
    nonisolated let bucket: String
    nonisolated let key: String
    private let contentType: String?

    private var outOfOrder: [UInt64: Data] = [:]
    private var outOfOrderBytes = 0
    private var nextOffset: UInt64 = 0
    private var buffer = Data()
    private var uploadID: Task<String, Error>?
    private var parts: [(size: Int, task: Task<S3.CompletedPart, Error>)] = []
    private var settledCount = 0
    private var completed: [S3.CompletedPart] = []
    private var inFlightBytes = 0
    private var failure: Error?
    private var isFinished = false

    init(service: S3, bucket: String, key: String) {
        self.service = service
        self.bucket = bucket
        self.key = key
        let ext = (key as NSString).pathExtension
        contentType = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.preferredMIMEType
    }

    nonisolated var replacesAtomically: Bool { true }

    func write(_ data: Data, at offset: UInt64) async throws {
        if let failure { throw failure }
        guard !isFinished, offset >= nextOffset, outOfOrder[offset] == nil else {
            throw StorageError.incompleteUpload
        }
        outOfOrder[offset] = data
        outOfOrderBytes += data.count
        while let next = outOfOrder.removeValue(forKey: nextOffset) {
            buffer.append(next)
            outOfOrderBytes -= next.count
            nextOffset += UInt64(next.count)
        }
        while buffer.count >= partSize(for: parts.count + 1) {
            let size = partSize(for: parts.count + 1)
            startPart(Data(buffer.prefix(size)))
            buffer = Data(buffer.dropFirst(size))
        }
        // A stalled earlier chunk mustn't let later ones pile up: while this chunk
        // is still parked, hold the pipeline. The missing chunk never waits here.
        while outOfOrderBytes > Self.outOfOrderBudget, nextOffset <= offset, !isFinished, failure == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        if let failure { throw failure }
        if isFinished { throw StorageError.incompleteUpload }
        // Back-pressure: reading stalls until uploads catch up.
        while inFlightBytes > Self.inFlightBudget, settledCount < parts.count {
            try await settleNextPart()
        }
    }

    func close() async throws {
        guard !isFinished else { return }
        if let failure {
            await abort()
            throw failure
        }
        guard outOfOrder.isEmpty else {
            await abort()
            throw StorageError.incompleteUpload
        }
        do {
            if let uploadID {
                if !buffer.isEmpty { startPart(buffer) }
                buffer = Data()
                while settledCount < parts.count { try await settleNextPart() }
                let id = try await uploadID.value
                let sorted = completed.sorted { ($0.partNumber ?? 0) < ($1.partNumber ?? 0) }
                let output = try await service.completeMultipartUpload(.init(
                    bucket: bucket, key: key, multipartUpload: .init(parts: sorted), uploadId: id
                ))
                try StorageError.requireETag(output.eTag)
            } else {
                // Small files: one request, no upload to create or abort.
                _ = try await service.putObject(.init(
                    body: .init(bytes: buffer), bucket: bucket, contentLength: Int64(buffer.count),
                    contentType: contentType, key: key
                ))
            }
            isFinished = true
        } catch {
            await abort()
            throw StorageError.from(error, path: key)
        }
    }

    func abort() async {
        guard !isFinished else { return }
        isFinished = true
        buffer = Data()
        outOfOrder = [:]
        outOfOrderBytes = 0
        for part in parts { part.task.cancel() }
        guard let uploadID else { return }
        let (service, bucket, key) = (service, bucket, key)
        // Unstructured, so a cancelled job still aborts: an orphaned upload keeps billing.
        await Task {
            guard let id = try? await uploadID.value else { return }
            _ = try? await service.abortMultipartUpload(.init(bucket: bucket, key: key, uploadId: id))
        }.value
    }

    // MARK: - Parts

    private func partSize(for partNumber: Int) -> Int {
        min(Self.basePartSize << ((partNumber - 1) / 1000), Self.maxPartSize)
    }

    private func startPart(_ data: Data) {
        let number = parts.count + 1
        let id = multipartUploadID()
        let (service, bucket, key) = (service, bucket, key)
        let task = Task {
            let uploadID = try await id.value
            let output = try await service.uploadPart(.init(
                body: .init(bytes: data), bucket: bucket, contentLength: Int64(data.count),
                key: key, partNumber: number, uploadId: uploadID
            ))
            return S3.CompletedPart(eTag: output.eTag, partNumber: number)
        }
        parts.append((data.count, task))
        inFlightBytes += data.count
    }

    private func multipartUploadID() -> Task<String, Error> {
        if let uploadID { return uploadID }
        let (service, bucket, key, contentType) = (service, bucket, key, contentType)
        let task = Task {
            let output = try await service.createMultipartUpload(.init(bucket: bucket, contentType: contentType, key: key))
            guard let id = output.uploadId else {
                throw StorageError.service(String(localized: "The server didn't start the upload.", comment: "Storage upload error"))
            }
            return id
        }
        uploadID = task
        return task
    }

    /// Waits for the oldest unsettled part; claims it before awaiting so
    /// concurrent writers never settle the same part twice.
    private func settleNextPart() async throws {
        let part = parts[settledCount]
        settledCount += 1
        do {
            completed.append(try await part.task.value)
            inFlightBytes -= part.size
        } catch {
            let mapped = StorageError.from(error, path: key)
            failure = failure ?? mapped
            throw mapped
        }
    }
}
