//
//  FileTreeCopier.swift
//  rootshell
//
//  Copies files and directory trees between any two FileSystemEndpoints.
//  Shared by the file manager's transfer queue and the rf browser.
//

import Foundation

enum FileTreeCopier {
    struct Item {
        enum Kind {
            case directory
            case file
            case symlink(target: String)
        }

        let kind: Kind
        let source: String
        let destination: String
        let size: Int64
        let mode: UInt32?
        let modified: Date?

        var isFile: Bool {
            if case .file = kind { return true }
            return false
        }
    }

    /// The item plus, for a directory, everything beneath it in copy order.
    /// The selected item is dereferenced if it is a link; nested links are
    /// copied as links, so a link cycle can't recurse forever.
    static func expand(_ path: String, into target: String, fs: FileSystemEndpoint) async throws -> [Item] {
        let info: FileSystemEndpoint.ItemInfo
        if let followed = try? await fs.info(path) {
            info = followed
        } else {
            info = try await fs.info(path, followLinks: false)
            if info.isSymlink {
                return [Item(kind: .symlink(target: try await fs.readLink(path)), source: path, destination: target, size: 0, mode: nil, modified: nil)]
            }
        }
        guard info.isDirectory else {
            return [Item(kind: .file, source: path, destination: target, size: Int64(clamping: info.size), mode: info.permissions, modified: info.modified)]
        }
        var items = [Item(kind: .directory, source: path, destination: target, size: 0, mode: info.permissions, modified: info.modified)]
        try await walk(path, into: target, fs: fs, items: &items)
        return items
    }

    private static func walk(_ directory: String, into target: String, fs: FileSystemEndpoint, items: inout [Item]) async throws {
        for entry in try await fs.list(directory) {
            try Task.checkCancellation()
            let destination = FileTransferLogic.join(target, entry.name)
            if entry.isSymlink {
                let linkTarget: String
                if let known = entry.symlinkTarget {
                    linkTarget = known
                } else {
                    linkTarget = try await fs.readLink(entry.path)
                }
                items.append(Item(kind: .symlink(target: linkTarget), source: entry.path, destination: destination, size: 0, mode: nil, modified: nil))
            } else if entry.isDirectory {
                items.append(Item(kind: .directory, source: entry.path, destination: destination, size: 0, mode: entry.permissions, modified: entry.modifiedDate))
                try await walk(entry.path, into: destination, fs: fs, items: &items)
            } else {
                items.append(Item(kind: .file, source: entry.path, destination: destination, size: entry.size, mode: entry.permissions, modified: entry.modifiedDate))
            }
        }
    }

    /// Creates one item at its destination. `onBytes` receives byte deltas and is
    /// rewound with a negative delta if a file copy fails; a partial file is removed.
    static func copy(
        _ item: Item,
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint,
        preserveAttributes: Bool,
        onBytes: (Int64) -> Void
    ) async throws {
        try await removeSymlink(at: item.destination, on: destination)
        switch item.kind {
        case .directory:
            if !(await destination.exists(item.destination)) {
                try await destination.makeDirectory(item.destination)
            }
        case .symlink(let target):
            try await destination.createSymlink(at: item.destination, target: target)
        case .file:
            try await copyFile(item, from: source, to: destination, onBytes: onBytes)
            if preserveAttributes {
                if let modified = item.modified { try? await destination.setModificationDate(item.destination, date: modified) }
                if let mode = item.mode { try? await destination.setPermissions(item.destination, mode: mode) }
            }
        }
    }

    /// Applies directory modes after their contents exist, deepest first,
    /// so a read-only directory can still be filled.
    static func applyDirectoryModes(_ items: [Item], on destination: FileSystemEndpoint) async {
        for item in items.reversed() {
            guard case .directory = item.kind, let mode = item.mode else { continue }
            try? await destination.setPermissions(item.destination, mode: mode)
        }
    }

    /// Copies a whole tree, stopping at the first failure.
    static func copyTree(
        _ path: String,
        to target: String,
        from source: FileSystemEndpoint,
        to destination: FileSystemEndpoint,
        preserveAttributes: Bool = false,
        onBytes: (Int64) -> Void = { _ in }
    ) async throws {
        let items = try await expand(path, into: target, fs: source)
        for item in items {
            try Task.checkCancellation()
            try await copy(item, from: source, to: destination, preserveAttributes: preserveAttributes, onBytes: onBytes)
        }
        if preserveAttributes { await applyDirectoryModes(items, on: destination) }
    }

    /// A symlink already at a destination is replaced, never written or descended
    /// through, so a merge can't redirect data outside the target folder.
    private static func removeSymlink(at path: String, on destination: FileSystemEndpoint) async throws {
        guard let existing = try? await destination.info(path, followLinks: false), existing.isSymlink else { return }
        try await destination.removeFile(path)
    }

    private static func copyFile(_ item: Item, from source: FileSystemEndpoint, to destination: FileSystemEndpoint, onBytes: (Int64) -> Void) async throws {
        let reader = try await source.openReader(item.source)
        let writer: any ChunkWriter
        do {
            writer = try await destination.openWriter(item.destination)
        } catch {
            try? await reader.close()
            throw error
        }
        var counted: Int64 = 0
        var failure: Error?
        do {
            try await PipelinedTransfer.copy(from: reader, to: writer, size: item.size > 0 ? UInt64(item.size) : nil) { total in
                onBytes(total - counted)
                counted = total
            }
        } catch {
            failure = error
        }
        try? await reader.close()
        // The item only counts as copied once the destination accepts the close.
        do {
            try await writer.close()
        } catch {
            failure = failure ?? error
        }
        if let failure {
            // Never leave a truncated file behind or count its bytes.
            onBytes(-counted)
            try? await destination.removeFile(item.destination)
            throw failure
        }
    }
}
