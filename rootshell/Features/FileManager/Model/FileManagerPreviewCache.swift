//
//  FileManagerPreviewCache.swift
//  rootshell
//
//  Local copies of remote files for Quick Look and drag-out. Kept under
//  Caches so the system may reclaim them; cleared on first use each launch.
//

import Foundation

enum FileManagerPreviewCache {
    /// Largest remote file fetched for a preview.
    static let maxPreviewBytes: Int64 = 512 * 1024 * 1024

    private static let root: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("FileManagerPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    /// A file URL for `entry`: the file itself when local, else a fresh download.
    static func localURL(for entry: RFEntry, fs: FileSystemEndpoint) async throws -> URL {
        if case .local(let resolver) = fs.backend {
            return URL(fileURLWithPath: resolver.resolve(entry.path))
        }
        guard entry.size <= maxPreviewBytes else {
            throw FileManagerPreviewError.tooLarge
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(entry.name)
        let local = FileSystemEndpoint(backend: .local(.identity))
        try await FileTreeCopier.copyTree(entry.path, to: destination.path, from: fs, to: local)
        return destination
    }
}

enum FileManagerPreviewError: LocalizedError {
    case tooLarge

    var errorDescription: String? {
        String(localized: "This file is too large to preview.", comment: "File manager preview error")
    }
}
