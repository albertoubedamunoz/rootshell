import Foundation

/// Git status for a single file.
nonisolated enum RFGitFileStatus: Sendable {
    case modified
    case staged
    case untracked
    case added
    case deleted
    case renamed
    case conflict
    case ignored
}

/// Sort order for directory listings.
nonisolated enum RFSortOrder: Sendable {
    case nameAsc
    case nameDesc
    case sizeAsc
    case sizeDesc
    case modifiedAsc
    case modifiedDesc
    case typeAsc

    var displayName: String {
        switch self {
        case .nameAsc:     return "Name ↑"
        case .nameDesc:    return "Name ↓"
        case .sizeAsc:     return "Size ↑"
        case .sizeDesc:    return "Size ↓"
        case .modifiedAsc: return "Date ↑"
        case .modifiedDesc: return "Date ↓"
        case .typeAsc:     return "Type"
        }
    }

    func next() -> RFSortOrder {
        switch self {
        case .nameAsc:     return .nameDesc
        case .nameDesc:    return .sizeDesc
        case .sizeDesc:    return .sizeAsc
        case .sizeAsc:     return .modifiedDesc
        case .modifiedDesc: return .modifiedAsc
        case .modifiedAsc: return .typeAsc
        case .typeAsc:     return .nameAsc
        }
    }
}

/// A single file or directory entry with metadata.
/// `isDirectory` follows symlinks, so a link to a directory can be entered.
nonisolated struct RFEntry: Sendable {
    let name: String
    let path: String          // Absolute path
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isExecutable: Bool
    let size: Int64
    let modifiedDate: Date?
    var gitStatus: RFGitFileStatus?
    /// POSIX mode bits including the file-type bits, when known.
    var permissions: UInt32? = nil
    var symlinkTarget: String? = nil
    var owner: String? = nil

    /// File extension (lowercase, without dot).
    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Human-readable file size.
    var sizeString: String {
        if isDirectory { return "" }
        if size < 1024 { return "\(size)B" }
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.1fK", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1fM", mb) }
        let gb = mb / 1024
        return String(format: "%.1fG", gb)
    }

    /// Git status indicator character.
    var gitIndicator: String {
        guard let status = gitStatus else { return "" }
        switch status {
        case .modified:  return "M"
        case .staged:    return "S"
        case .untracked: return "?"
        case .added:     return "A"
        case .deleted:   return "D"
        case .renamed:   return "R"
        case .conflict:  return "C"
        case .ignored:   return ""
        }
    }
}

// MARK: - Loading

extension RFEntry {
    /// Load entries from a directory path.
    /// If the path is a bookmarked location (symlink to a security-scoped resource),
    /// uses the BookmarkedLocationsManager's resolved URL for access while keeping
    /// entry paths relative to the original path for consistent navigation.
    @MainActor
    static func loadDirectory(at path: String) -> [RFEntry] {
        (try? loadLocalDirectory(at: path, resolver: .current())) ?? []
    }

    /// Off-main variant; the resolver carries the bookmark state captured on the main actor.
    nonisolated static func loadLocalDirectory(at path: String, resolver: LocalPathResolver) throws -> [RFEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey
        ]

        let contents = try fm.contentsOfDirectory(
            at: URL(fileURLWithPath: resolver.resolve(path)),
            includingPropertiesForKeys: keys,
            options: []
        )

        return contents.compactMap { url in
            // Build the entry path under the ORIGINAL path prefix so navigation
            // (leave/back/forward) stays consistent with the symlink path.
            let entryPath = (path as NSString).appendingPathComponent(url.lastPathComponent)

            guard let resources = try? url.resourceValues(forKeys: Set(keys)) else {
                // If resource values fail, check if the entry is a bookmark symlink
                let isBkmk = resolver.bookmarkNames.contains(url.lastPathComponent)
                return RFEntry(
                    name: url.lastPathComponent,
                    path: entryPath,
                    isDirectory: isBkmk,
                    isSymlink: isBkmk,
                    isHidden: url.lastPathComponent.hasPrefix("."),
                    isExecutable: false,
                    size: 0,
                    modifiedDate: nil,
                    gitStatus: nil
                )
            }

            var isDir = resources.isDirectory ?? false
            let isLink = resources.isSymbolicLink ?? false
            let size = Int64(resources.fileSize ?? 0)
            let modified = resources.contentModificationDate

            if isLink && !isDir {
                // Bookmarks are always directories, even when the target is outside the sandbox.
                var targetIsDir: ObjCBool = false
                isDir = resolver.bookmarkNames.contains(url.lastPathComponent)
                    || (fm.fileExists(atPath: url.path, isDirectory: &targetIsDir) && targetIsDir.boolValue)
            }

            let isExec = fm.isExecutableFile(atPath: url.path) && !isDir

            var mode: UInt32?
            var info = stat()
            if lstat(url.path, &info) == 0 { mode = UInt32(info.st_mode) }

            return RFEntry(
                name: url.lastPathComponent,
                path: entryPath,
                isDirectory: isDir,
                isSymlink: isLink,
                isHidden: url.lastPathComponent.hasPrefix("."),
                isExecutable: isExec,
                size: size,
                modifiedDate: modified,
                gitStatus: nil,
                permissions: mode,
                symlinkTarget: isLink ? try? fm.destinationOfSymbolicLink(atPath: url.path) : nil
            )
        }
    }

    /// Sort entries with the given order. Directories always come first.
    nonisolated static func sorted(_ entries: [RFEntry], by order: RFSortOrder) -> [RFEntry] {
        entries.sorted { a, b in
            // Directories first
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }

            switch order {
            case .nameAsc:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .nameDesc:
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedDescending
            case .sizeAsc:
                return a.size < b.size
            case .sizeDesc:
                return a.size > b.size
            case .modifiedAsc:
                return (a.modifiedDate ?? .distantPast) < (b.modifiedDate ?? .distantPast)
            case .modifiedDesc:
                return (a.modifiedDate ?? .distantPast) > (b.modifiedDate ?? .distantPast)
            case .typeAsc:
                if a.fileExtension != b.fileExtension {
                    return a.fileExtension < b.fileExtension
                }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }
}
