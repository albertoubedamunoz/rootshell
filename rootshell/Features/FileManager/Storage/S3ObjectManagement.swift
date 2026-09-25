//
//  S3ObjectManagement.swift
//  rootshell
//
//  Operations beyond the filesystem surface: object details and editing its
//  headers, share links, incomplete multipart uploads, and creating and
//  deleting buckets.
//

import Foundation
import NIOCore
import NIOHTTP1
import SotoS3

/// The headers and user metadata an edit replaces as one set; "" means unset.
nonisolated struct S3ObjectHeaders: Sendable, Equatable {
    var contentType = ""
    var cacheControl = ""
    var contentDisposition = ""
    var contentEncoding = ""
    var contentLanguage = ""
    var metadata: [String: String] = [:]

    init() {}

    init(_ head: S3.HeadObjectOutput) {
        contentType = head.contentType ?? ""
        cacheControl = head.cacheControl ?? ""
        contentDisposition = head.contentDisposition ?? ""
        contentEncoding = head.contentEncoding ?? ""
        contentLanguage = head.contentLanguage ?? ""
        metadata = head.metadata ?? [:]
    }
}

/// An object's HeadObject response, as the info sheet shows it.
nonisolated struct S3ObjectDetails: Sendable {
    let headers: S3ObjectHeaders
    let size: Int64
    let modified: Date?
    let eTag: String?
    let storageClass: String
    let encryption: String?
    let kmsKeyID: String?
    let versionID: String?
    let tagCount: Int
    /// x-amz-restore, present while an archived object is being or has been restored.
    let restore: String?
    let isArchived: Bool

    init(_ head: S3.HeadObjectOutput) {
        headers = S3ObjectHeaders(head)
        size = head.contentLength ?? 0
        modified = head.lastModified
        eTag = head.eTag.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        // HeadObject omits the class for STANDARD.
        storageClass = head.storageClass?.rawValue ?? S3.StorageClass.standard.rawValue
        encryption = head.serverSideEncryption?.rawValue
        kmsKeyID = head.ssekmsKeyId
        versionID = head.versionId == "null" ? nil : head.versionId
        tagCount = head.tagCount ?? 0
        restore = head.restore
        isArchived = head.storageClass == .glacier || head.storageClass == .deepArchive || head.archiveStatus != nil
    }

    /// Whether `head` still describes this object. The ETag misses metadata-only
    /// rewrites, so headers, modification date and version are compared too.
    func isSameVersion(as head: S3.HeadObjectOutput) -> Bool {
        let fresh = S3ObjectDetails(head)
        return fresh.eTag == eTag && fresh.headers == headers && fresh.modified == modified && fresh.versionID == versionID
    }
}

/// A multipart upload that was started and never completed or aborted.
nonisolated struct S3PendingUpload: Sendable, Identifiable {
    let key: String
    let uploadID: String
    let initiated: Date?
    var id: String { uploadID }
}

extension S3FileSystem {
    // MARK: - Details and headers

    func details(_ path: String) async throws -> S3ObjectDetails {
        let (service, location) = try await object(path)
        return S3ObjectDetails(try await mapped(path) { try await service.headObject(.init(bucket: location.bucket, key: location.key)) })
    }

    /// Replaces the object's headers and metadata by copying it onto itself,
    /// only if it is still exactly the `base` that was edited.
    func updateHeaders(_ path: String, to headers: S3ObjectHeaders, base: S3ObjectDetails) async throws {
        guard base.eTag != nil else {
            throw StorageError.service(String(localized: "The server didn't report a version for “\(path)”, so it can't be edited safely.", comment: "Storage error; argument is a path"))
        }
        let (_, location) = try await object(path)
        try await copyObject(location, to: location, size: 0, path: path, headers: headers, base: base)
    }

    // MARK: - Share links

    var signsShareLinks: Bool { !provider.isAnonymous }

    /// A GET URL for the object, presigned for `seconds` (SigV4 allows up to a week).
    /// Anonymous providers get the plain URL, which only works for public objects.
    func shareURL(_ path: String, expiresIn seconds: Int64) async throws -> URL {
        let (service, location) = try await object(path)
        guard let url = S3KeyLogic.objectURL(
            endpoint: service.config.endpoint, bucket: location.bucket, key: location.key,
            forceVirtualHost: service.config.options.contains(.s3ForceVirtualHost)
        ) else {
            throw StorageError.misconfigured(String(localized: "The endpoint isn't a valid address.", comment: "Storage provider validation"))
        }
        guard signsShareLinks else { return url }
        return try await mapped(path) {
            try await service.signURL(url: url, httpMethod: .GET, expires: .seconds(min(seconds, 604_800)))
        }
    }

    // MARK: - Incomplete uploads

    func incompleteUploads(in bucket: String) async throws -> [S3PendingUpload] {
        let service = await session.service(for: bucket)
        var result: [S3PendingUpload] = []
        var keyMarker: String?
        var uploadIDMarker: String?
        repeat {
            try Task.checkCancellation()
            let page = try await mapped("/" + bucket) {
                try await service.listMultipartUploads(.init(bucket: bucket, keyMarker: keyMarker, uploadIdMarker: uploadIDMarker))
            }
            result += (page.uploads ?? []).compactMap { upload in
                guard let key = upload.key, let id = upload.uploadId else { return nil }
                return S3PendingUpload(key: key, uploadID: id, initiated: upload.initiated)
            }
            let more = page.isTruncated == true && (page.nextKeyMarker != nil || page.nextUploadIdMarker != nil)
            keyMarker = more ? page.nextKeyMarker : nil
            uploadIDMarker = more ? page.nextUploadIdMarker : nil
        } while keyMarker != nil || uploadIDMarker != nil
        return result.sorted { ($0.initiated ?? .distantPast) < ($1.initiated ?? .distantPast) }
    }

    func abort(_ upload: S3PendingUpload, in bucket: String) async throws {
        let service = await session.service(for: bucket)
        do {
            _ = try await service.abortMultipartUpload(.init(bucket: bucket, key: upload.key, uploadId: upload.uploadID))
        } catch where StorageError.isNotFound(error) {
            // Already completed or aborted elsewhere.
        } catch {
            throw StorageError.from(error, path: "/" + bucket + "/" + upload.key)
        }
    }

    // MARK: - Buckets

    /// Creates a bucket; on AWS in the provider's region.
    func createBucket(_ name: String) async throws {
        try requireAllBuckets()
        guard S3KeyLogic.isValidBucketName(name) else {
            throw StorageError.unsupported(String(
                localized: "Bucket names are 3 to 63 lowercase letters, numbers, dots and hyphens, starting and ending with a letter or number.",
                comment: "Storage error: invalid bucket name"
            ))
        }
        // CreateBucket on an owned bucket can succeed and reset its ACL (AWS us-east-1).
        let exists: Bool
        do {
            _ = try await session.defaultService.headBucket(.init(bucket: name))
            exists = true
        } catch where StorageError.isNotFound(error) {
            exists = false
        } catch let error as AWSErrorType where error.context?.responseCode == .movedPermanently {
            // AWS redirects a HEAD for a bucket that lives in another region.
            exists = true
        } catch {
            throw StorageError.from(error, path: "/" + name)
        }
        guard !exists else {
            throw StorageError.service(String(localized: "A bucket named “\(name)” already exists.", comment: "Storage error; argument is a bucket name"))
        }
        let region = provider.effectiveRegion
        // us-east-1 rejects an explicit constraint; other providers take theirs from the endpoint.
        let configuration = provider.preset.isAWS && provider.resolvedEndpoint == nil && region != "us-east-1"
            ? S3.CreateBucketConfiguration(locationConstraint: .init(rawValue: region))
            : nil
        _ = try await mapped("/" + name) {
            try await session.defaultService.createBucket(.init(bucket: name, createBucketConfiguration: configuration))
        }
        await session.noteRegion(region, for: name)
    }

    /// Deletes an empty bucket. Contents are never removed with it.
    func deleteBucket(_ bucket: String, path: String) async throws {
        try requireAllBuckets()
        let service = await session.service(for: bucket)
        do {
            try await service.deleteBucket(.init(bucket: bucket))
        } catch let error as AWSErrorType where error.errorCode == "BucketNotEmpty" {
            throw StorageError.service(String(
                localized: "“\(bucket)” isn't empty. Delete its contents first.",
                comment: "Storage error; argument is a bucket name"
            ))
        } catch {
            throw StorageError.from(error, path: path)
        }
        await session.forget(bucket)
    }

    /// A provider limited to one bucket can't create or delete any.
    private func requireAllBuckets() throws {
        guard provider.effectiveBucket == nil else {
            throw StorageError.unsupported(String(
                localized: "This storage provider is limited to one bucket.",
                comment: "Storage error"
            ))
        }
    }
}

extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
