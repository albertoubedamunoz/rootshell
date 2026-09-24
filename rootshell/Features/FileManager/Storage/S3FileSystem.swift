//
//  S3FileSystem.swift
//  rootshell
//
//  Filesystem semantics over an S3 bucket namespace. Paths are `/bucket/key`,
//  or `/key` when the provider is limited to one bucket. Folders are key
//  prefixes, listed with a "/" delimiter; an empty folder is kept as a
//  zero-byte "prefix/" marker object.
//

import Foundation
import NIOHTTP1
import SotoS3

nonisolated struct S3FileSystem: Sendable {
    let session: S3Session

    private var provider: StorageProvider { session.provider }

    /// A bucket and the key within it; an empty key is the bucket itself.
    struct Location: Sendable {
        let bucket: String
        let key: String
    }

    /// nil for the root of an unrestricted provider, which lists buckets.
    func location(of path: String) -> Location? {
        let components = FileTransferLogic.normalize(path).split(separator: "/").map(String.init)
        if let bucket = provider.effectiveBucket {
            return Location(bucket: bucket, key: components.joined(separator: "/"))
        }
        guard let bucket = components.first else { return nil }
        return Location(bucket: bucket, key: components.dropFirst().joined(separator: "/"))
    }

    var homeDirectory: String {
        FileTransferLogic.normalize(provider.initialPath)
    }

    // MARK: - Listing and metadata

    func list(_ path: String) async throws -> [RFEntry] {
        let base = FileTransferLogic.normalize(path)
        guard let location = location(of: base) else { return try await listBuckets() }
        let service = await session.service(for: location.bucket)
        let prefix = location.key.isEmpty ? "" : location.key + "/"
        var entries: [RFEntry] = []
        var token: String?
        repeat {
            let page = try await mapped(path) {
                try await service.listObjectsV2(.init(
                    bucket: location.bucket, continuationToken: token, delimiter: "/", prefix: prefix.isEmpty ? nil : prefix
                ))
            }
            for common in page.commonPrefixes ?? [] {
                guard let name = common.prefix.flatMap({ S3KeyLogic.childName($0, under: prefix) }) else { continue }
                entries.append(Self.entry(name, in: base, isDirectory: true))
            }
            for object in page.contents ?? [] {
                guard let name = object.key.flatMap({ S3KeyLogic.childName($0, under: prefix) }) else { continue }
                entries.append(Self.entry(name, in: base, isDirectory: false, size: object.size ?? 0, modified: object.lastModified))
            }
            token = page.isTruncated == true ? page.nextContinuationToken : nil
        } while token != nil
        return entries
    }

    private func listBuckets() async throws -> [RFEntry] {
        var entries: [RFEntry] = []
        var token: String?
        repeat {
            let page = try await mapped("/") { try await session.defaultService.listBuckets(.init(continuationToken: token)) }
            for bucket in page.buckets ?? [] {
                guard let name = bucket.name else { continue }
                if let region = bucket.bucketRegion { await session.noteRegion(region, for: name) }
                entries.append(Self.entry(name, in: "/", isDirectory: true, modified: bucket.creationDate))
            }
            token = page.continuationToken
        } while token != nil
        return entries
    }

    /// A key names a file; a key with objects beneath it names a folder.
    func info(_ path: String) async throws -> FileSystemEndpoint.ItemInfo {
        guard let location = location(of: path) else { return Self.directoryInfo }
        let service = await session.service(for: location.bucket)
        if location.key.isEmpty {
            // Scoped keys may not allow HeadBucket; only a definite 404 means missing.
            do {
                _ = try await service.headBucket(.init(bucket: location.bucket))
            } catch where StorageError.isNotFound(error) {
                throw StorageError.notFound(path)
            } catch {}
            return Self.directoryInfo
        }
        do {
            let head = try await service.headObject(.init(bucket: location.bucket, key: location.key))
            return FileSystemEndpoint.ItemInfo(
                isDirectory: false, isSymlink: false, size: UInt64(max(0, head.contentLength ?? 0)),
                permissions: nil, modified: head.lastModified
            )
        } catch where StorageError.isNotFound(error) {
            let page = try await mapped(path) {
                try await service.listObjectsV2(.init(bucket: location.bucket, maxKeys: 1, prefix: location.key + "/"))
            }
            guard page.contents?.isEmpty == false || page.commonPrefixes?.isEmpty == false else {
                throw StorageError.notFound(path)
            }
            return Self.directoryInfo
        } catch {
            throw StorageError.from(error, path: path)
        }
    }

    // MARK: - Mutation

    func makeDirectory(_ path: String) async throws {
        let (service, location) = try await object(path)
        _ = try await mapped(path) {
            try await service.putObject(.init(body: .init(bytes: Data()), bucket: location.bucket, contentLength: 0, key: location.key + "/"))
        }
    }

    func removeFile(_ path: String) async throws {
        let (service, location) = try await object(path)
        _ = try await mapped(path) { try await service.deleteObject(.init(bucket: location.bucket, key: location.key)) }
    }

    /// Removes a folder's marker; its contents are separate objects.
    func removeDirectory(_ path: String) async throws {
        let (service, location) = try await object(path)
        _ = try await mapped(path) { try await service.deleteObject(.init(bucket: location.bucket, key: location.key + "/")) }
    }

    /// Deletes a file, or every object under a folder in batches.
    func removeRecursively(_ path: String) async throws {
        let (service, location) = try await object(path)
        guard try await info(path).isDirectory else {
            return try await removeFile(path)
        }
        let keys = try await objects(under: location, service: service).map(\.key)
        try await delete(keys, in: location.bucket, service: service, path: path)
    }

    /// Server-side copy then delete; a folder moves object by object, and its
    /// originals are only deleted once every copy succeeded.
    func rename(_ from: String, to: String) async throws {
        let (_, source) = try await object(from)
        let (_, target) = try await object(to)
        let item = try await info(from)
        guard item.isDirectory else {
            try await copyObject(source, to: target, size: Int64(item.size), path: from)
            return try await removeFile(from)
        }
        guard !FileTransferLogic.isSameOrDescendant(FileTransferLogic.normalize(to), of: FileTransferLogic.normalize(from)) else {
            throw StorageError.unsupported(String(localized: "A folder can't be moved into itself.", comment: "Storage error"))
        }
        let service = await session.service(for: source.bucket)
        let contents = try await objects(under: source, service: service)
        let prefix = source.key + "/"
        for object in contents {
            try Task.checkCancellation()
            let relative = String(object.key.dropFirst(prefix.count))
            let destination = Location(bucket: target.bucket, key: target.key + "/" + relative)
            try await copyObject(Location(bucket: source.bucket, key: object.key), to: destination, size: object.size, path: from)
        }
        try await delete(contents.map(\.key), in: source.bucket, service: service, path: from)
    }

    // MARK: - Streams

    func openReader(_ path: String) async throws -> any ChunkReader {
        let (service, location) = try await object(path)
        let head = try await mapped(path) { try await service.headObject(.init(bucket: location.bucket, key: location.key)) }
        return S3ObjectReader(
            service: service, bucket: location.bucket, key: location.key,
            size: UInt64(max(0, head.contentLength ?? 0)), eTag: head.eTag
        )
    }

    func openWriter(_ path: String) async throws -> any ChunkWriter {
        let (service, location) = try await object(path)
        return S3ObjectWriter(service: service, bucket: location.bucket, key: location.key)
    }

    // MARK: - Server-side copy

    /// Same endpoint and keys: the server can copy without the data passing through the device.
    func canCopyOnServer(from other: S3FileSystem) -> Bool {
        provider.endpointIdentity == other.provider.endpointIdentity
            && provider.accessKeyID == other.provider.accessKeyID
            && provider.sessionToken == other.provider.sessionToken
    }

    func copyOnServer(_ sourcePath: String, from source: S3FileSystem, to path: String) async throws {
        let (_, from) = try await source.object(sourcePath)
        let (_, to) = try await object(path)
        let size = try await source.info(sourcePath).size
        try await copyObject(from, to: to, size: Int64(size), path: sourcePath)
    }

    /// CopyObject handles up to 5 GB; larger objects copy in 1 GB ranges.
    private func copyObject(_ source: Location, to target: Location, size: Int64, path: String) async throws {
        let service = await session.service(for: target.bucket)
        let copySource = S3KeyLogic.copySource(bucket: source.bucket, key: source.key)
        guard size > 5 << 30 else {
            _ = try await mapped(path) { try await service.copyObject(.init(bucket: target.bucket, copySource: copySource, key: target.key)) }
            return
        }
        let upload = try await mapped(path) { try await service.createMultipartUpload(.init(bucket: target.bucket, key: target.key)) }
        guard let uploadID = upload.uploadId else {
            throw StorageError.service(String(localized: "The server didn't start the upload.", comment: "Storage upload error"))
        }
        do {
            let partSize: Int64 = 1 << 30
            var parts: [S3.CompletedPart] = []
            for (index, start) in stride(from: Int64(0), to: size, by: Int(partSize)).enumerated() {
                try Task.checkCancellation()
                let end = min(start + partSize, size) - 1
                let output = try await service.uploadPartCopy(.init(
                    bucket: target.bucket, copySource: copySource, copySourceRange: "bytes=\(start)-\(end)",
                    key: target.key, partNumber: index + 1, uploadId: uploadID
                ))
                parts.append(S3.CompletedPart(eTag: output.copyPartResult.eTag, partNumber: index + 1))
            }
            _ = try await service.completeMultipartUpload(.init(
                bucket: target.bucket, key: target.key, multipartUpload: .init(parts: parts), uploadId: uploadID
            ))
        } catch {
            // Unstructured so a cancelled job still cleans up.
            await Task {
                _ = try? await service.abortMultipartUpload(.init(bucket: target.bucket, key: target.key, uploadId: uploadID))
            }.value
            throw StorageError.from(error, path: path)
        }
    }

    // MARK: - Helpers

    private static let directoryInfo = FileSystemEndpoint.ItemInfo(
        isDirectory: true, isSymlink: false, size: 0, permissions: nil, modified: nil
    )

    /// The service and location for an object; bucket roots aren't objects.
    private func object(_ path: String) async throws -> (S3, Location) {
        guard let location = location(of: path), !location.key.isEmpty else {
            throw StorageError.unsupported(String(localized: "Buckets can't be created, changed or deleted here.", comment: "Storage error"))
        }
        return (await session.service(for: location.bucket), location)
    }

    /// Every object whose key starts with the folder's prefix, marker included.
    private func objects(under folder: Location, service: S3) async throws -> [(key: String, size: Int64)] {
        var result: [(key: String, size: Int64)] = []
        var token: String?
        repeat {
            try Task.checkCancellation()
            let page = try await mapped(folder.key) {
                try await service.listObjectsV2(.init(bucket: folder.bucket, continuationToken: token, prefix: folder.key + "/"))
            }
            result += (page.contents ?? []).compactMap { object in object.key.map { ($0, object.size ?? 0) } }
            token = page.isTruncated == true ? page.nextContinuationToken : nil
        } while token != nil
        return result
    }

    private func delete(_ keys: [String], in bucket: String, service: S3, path: String) async throws {
        var remaining = keys[...]
        if provider.preset.supportsBatchDelete {
            while !remaining.isEmpty {
                try Task.checkCancellation()
                let batch = remaining.prefix(1000)
                do {
                    let output = try await service.deleteObjects(.init(
                        bucket: bucket, delete: .init(objects: batch.map { S3.ObjectIdentifier(key: $0) }, quiet: true)
                    ))
                    if let failure = output.errors?.first {
                        throw StorageError.service(failure.message ?? failure.code ?? failure.key ?? path)
                    }
                    remaining = remaining.dropFirst(batch.count)
                } catch let error as AWSErrorType where error.context?.responseCode == .notImplemented {
                    break
                } catch {
                    throw StorageError.from(error, path: path)
                }
            }
        }
        for key in remaining {
            try Task.checkCancellation()
            _ = try await mapped(path) { try await service.deleteObject(.init(bucket: bucket, key: key)) }
        }
    }

    private func mapped<T>(_ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw StorageError.from(error, path: path)
        }
    }

    private static func entry(_ name: String, in directory: String, isDirectory: Bool, size: Int64 = 0, modified: Date? = nil) -> RFEntry {
        RFEntry(
            name: name, path: FileTransferLogic.join(directory, name), isDirectory: isDirectory, isSymlink: false,
            isHidden: name.hasPrefix("."), isExecutable: false, size: size, modifiedDate: modified, gitStatus: nil
        )
    }
}

nonisolated enum StorageError: LocalizedError {
    case notFound(String)
    case unsupported(String)
    case misconfigured(String)
    case service(String)
    case incompleteUpload

    var errorDescription: String? {
        switch self {
        case .notFound(let path):
            String(localized: "“\(path)” doesn't exist.", comment: "Storage error; argument is a path")
        case .unsupported(let message), .misconfigured(let message), .service(let message):
            message
        case .incompleteUpload:
            String(localized: "The upload was incomplete.", comment: "Storage error")
        }
    }

    static let noSymlinks = StorageError.unsupported(
        String(localized: "Cloud storage can't hold symbolic links.", comment: "Storage error")
    )
    static let noPermissions = StorageError.unsupported(
        String(localized: "Cloud storage doesn't keep permissions or modification dates.", comment: "Storage error")
    )

    static func isNotFound(_ error: Error) -> Bool {
        (error as? AWSErrorType)?.context?.responseCode == .notFound
    }

    static func from(_ error: Error, path: String) -> Error {
        if error is StorageError || error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        guard let aws = error as? AWSErrorType else { return error }
        switch aws.context?.responseCode {
        case .notFound?:
            return StorageError.notFound(path)
        case .forbidden?:
            let detail = aws.context?.message ?? ""
            return StorageError.service(detail.isEmpty
                ? String(localized: "Access denied.", comment: "Storage error")
                : detail)
        default:
            let detail = aws.context?.message ?? ""
            return StorageError.service(detail.isEmpty ? aws.errorCode : detail)
        }
    }
}
