#if !targetEnvironment(macCatalyst)

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
enum RFSortOrder: Sendable {
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
struct RFEntry: Sendable {
    let name: String
    let path: String          // Absolute path
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isExecutable: Bool
    let size: Int64
    let modifiedDate: Date?
    var gitStatus: RFGitFileStatus?

    // MARK: - Display Properties

    /// File extension (lowercase, without dot).
    var fileExtension: String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext
    }

    /// Resolved icon definition with per-file Nerd Font icon and RGB color.
    var iconDef: RFIconDef {
        RFIconRegistry.resolve(self)
    }

    /// Color for this entry's name (theme-dependent, state-aware).
    /// Icon color comes from iconDef.fg directly.
    @MainActor
    func nameColor(theme: RFTheme) -> (UInt8, UInt8, UInt8) {
        if isDirectory { return theme.directoryColor }
        if isSymlink { return theme.symlinkColor }
        if isHidden { return theme.hiddenColor }
        if isExecutable { return theme.executableColor }
        // Use the per-icon color for regular files
        return iconDef.fg
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

    /// Git status color.
    @MainActor
    func gitColor(theme: RFTheme) -> (UInt8, UInt8, UInt8)? {
        guard let status = gitStatus else { return nil }
        switch status {
        case .modified:  return theme.gitModified
        case .staged:    return theme.gitStaged
        case .added:     return theme.gitStaged
        case .untracked: return theme.gitUntracked
        case .deleted:   return theme.gitDeleted
        case .renamed:   return theme.gitModified
        case .conflict:  return theme.gitConflict
        case .ignored:   return nil
        }
    }

    /// Convert to display entry for rendering.
    @MainActor
    func toDisplayEntry(theme: RFTheme) -> RFDisplayEntry {
        var rightParts: [String] = []
        if !gitIndicator.isEmpty {
            rightParts.append(gitIndicator)
        }
        let sz = sizeString
        if !sz.isEmpty {
            rightParts.append(sz)
        }
        let rightText = rightParts.joined(separator: " ")

        let icon = iconDef
        let entryColor = nameColor(theme: theme)
        return RFDisplayEntry(
            name: name,
            path: path,
            icon: icon.text,
            iconColor: theme.readableDecorativeColor(icon.fg),
            color: theme.readableTextColor(entryColor),
            isDirectory: isDirectory,
            rightText: rightText,
            rightColor: gitColor(theme: theme).map { theme.readableDecorativeColor($0) }
        )
    }
}

// MARK: - Loading

extension RFEntry {
    /// Load entries from a directory path.
    /// If the path is a bookmarked location (symlink to a security-scoped resource),
    /// uses the BookmarkedLocationsManager's resolved URL for access while keeping
    /// entry paths relative to the original path for consistent navigation.
    static func loadDirectory(at path: String) -> [RFEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .isSymbolicLinkKey
        ]

        // Use the security-scoped URL if this path is a bookmarked location,
        // otherwise fall back to the plain file URL.
        let accessURL = BookmarkedLocationsManager.shared.accessibleURL(for: path)
            ?? URL(fileURLWithPath: path)

        guard let contents = try? fm.contentsOfDirectory(
            at: accessURL,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            return []
        }

        return contents.compactMap { url in
            // Build the entry path under the ORIGINAL path prefix so navigation
            // (leave/back/forward) stays consistent with the symlink path.
            let entryPath = (path as NSString).appendingPathComponent(url.lastPathComponent)

            guard let resources = try? url.resourceValues(forKeys: Set(keys)) else {
                // If resource values fail, check if the entry is a bookmark symlink
                let isBkmk = BookmarkedLocationsManager.shared.isBookmarkSymlink(named: url.lastPathComponent)
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

            // For symlinks where isDirectory is false (target outside sandbox),
            // check if this is a bookmark symlink — bookmarks are always directories.
            if isLink && !isDir {
                if BookmarkedLocationsManager.shared.isBookmarkSymlink(named: url.lastPathComponent) {
                    isDir = true
                }
            }

            let isExec = fm.isExecutableFile(atPath: url.path) && !isDir

            return RFEntry(
                name: url.lastPathComponent,
                path: entryPath,
                isDirectory: isDir,
                isSymlink: isLink,
                isHidden: url.lastPathComponent.hasPrefix("."),
                isExecutable: isExec,
                size: size,
                modifiedDate: modified,
                gitStatus: nil
            )
        }
    }

    /// Sort entries with the given order. Directories always come first.
    static func sorted(_ entries: [RFEntry], by order: RFSortOrder) -> [RFEntry] {
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

#endif
