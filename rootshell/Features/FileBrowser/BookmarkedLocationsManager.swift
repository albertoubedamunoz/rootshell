#if !targetEnvironment(macCatalyst)

import Combine
import Foundation
import OSLog

// MARK: - Data Model

struct BookmarkedLocation: Codable, Identifiable {
    let id: UUID
    var name: String
    var bookmarkData: Data

    /// Resolved URL from bookmark data (transient, not encoded)
    var resolvedURL: URL?
    /// Whether the bookmark data is stale and needs re-creation
    var isStale: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, bookmarkData
    }

    init(id: UUID = UUID(), name: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)

        // Resolve bookmark data on decode
        var stale = false
        resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        isStale = stale
    }
}

// MARK: - Errors

enum BookmarkedLocationError: LocalizedError {
    case emptyName
    case invalidCharacters
    case reservedName
    case nameTooLong
    case nameConflictsWithExistingFile
    case duplicateName
    case accessDenied
    case bookmarkCreationFailed
    case symlinkCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Name cannot be empty"
        case .invalidCharacters:
            return "Name cannot contain /, \\, or whitespace"
        case .reservedName:
            return "Name cannot be . or .., or start with a dot"
        case .nameTooLong:
            return "Name must be 64 characters or fewer"
        case .nameConflictsWithExistingFile:
            return "A file or folder with this name already exists in Documents"
        case .duplicateName:
            return "A bookmark with this name already exists"
        case .accessDenied:
            return "Could not access the selected folder"
        case .bookmarkCreationFailed:
            return "Failed to create security-scoped bookmark"
        case .symlinkCreationFailed(let reason):
            return "Failed to create symlink: \(reason)"
        }
    }
}

// MARK: - Manager

@MainActor
final class BookmarkedLocationsManager: ObservableObject {
    static let shared = BookmarkedLocationsManager()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "BookmarkedLocationsManager"
    )

    @Published private(set) var locations: [BookmarkedLocation] = []

    private let fileManager = FileManager.default
    private var accessedURLs: [UUID: URL] = [:]

    private init() {}

    // MARK: - Storage Paths

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var configDir: URL {
        documentsURL.appendingPathComponent(".ghostty")
    }

    private var storageURL: URL {
        configDir.appendingPathComponent("bookmarked_locations.json")
    }

    // MARK: - Public API

    func addLocation(name: String, folderURL: URL) throws {
        try validateName(name)

        // Start accessing the security-scoped resource
        guard folderURL.startAccessingSecurityScopedResource() else {
            throw BookmarkedLocationError.accessDenied
        }

        // Create bookmark data
        let bookmarkData: Data
        do {
            bookmarkData = try folderURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            folderURL.stopAccessingSecurityScopedResource()
            throw BookmarkedLocationError.bookmarkCreationFailed
        }

        // Create symlink
        let symlinkPath = documentsURL.appendingPathComponent(name).path
        do {
            try fileManager.createSymbolicLink(
                atPath: symlinkPath,
                withDestinationPath: folderURL.path
            )
        } catch {
            folderURL.stopAccessingSecurityScopedResource()
            throw BookmarkedLocationError.symlinkCreationFailed(error.localizedDescription)
        }

        var location = BookmarkedLocation(name: name, bookmarkData: bookmarkData)
        location.resolvedURL = folderURL

        accessedURLs[location.id] = folderURL
        locations.append(location)

        save()
        updateIOSSystemConfig()

        let locationName = name
        Self.logger.info("Added bookmarked location: \(locationName)")
    }

    func removeLocation(_ location: BookmarkedLocation) {
        // Remove symlink
        let symlinkPath = documentsURL.appendingPathComponent(location.name).path
        try? fileManager.removeItem(atPath: symlinkPath)

        // Stop accessing security-scoped resource
        if let url = accessedURLs.removeValue(forKey: location.id) {
            url.stopAccessingSecurityScopedResource()
        }

        locations.removeAll { $0.id == location.id }

        save()
        updateIOSSystemConfig()

        let locationName = location.name
        Self.logger.info("Removed bookmarked location: \(locationName)")
    }

    func syncOnLaunch() {
        // Stop any previously accessed URLs to avoid leaking access counts
        // on repeated calls (e.g., scene recreation, multiple windows)
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()

        load()

        var changed = false
        for i in locations.indices {
            let location = locations[i]

            // Resolve bookmark data
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: location.bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                let name = location.name
                Self.logger.warning("Failed to resolve bookmark for: \(name)")
                continue
            }

            locations[i].isStale = stale

            // Start accessing — if this fails, leave resolvedURL nil so it gets pruned
            guard url.startAccessingSecurityScopedResource() else {
                let name = location.name
                Self.logger.warning("Failed to access security-scoped resource for: \(name)")
                continue
            }
            locations[i].resolvedURL = url
            accessedURLs[location.id] = url

            // Recreate symlink if missing
            let symlinkPath = documentsURL.appendingPathComponent(location.name).path
            if !fileManager.fileExists(atPath: symlinkPath) {
                do {
                    try fileManager.createSymbolicLink(
                        atPath: symlinkPath,
                        withDestinationPath: url.path
                    )
                    let name = location.name
                    Self.logger.info("Recreated symlink for: \(name)")
                } catch {
                    let name = location.name
                    Self.logger.error("Failed to recreate symlink for \(name): \(error.localizedDescription)")
                }
            }

            // Re-create bookmark if stale
            if stale {
                if let newData = try? url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    locations[i].bookmarkData = newData
                    locations[i].isStale = false
                    changed = true
                    let name = location.name
                    Self.logger.info("Refreshed stale bookmark for: \(name)")
                }
            }
        }

        // Prune locations that couldn't be resolved at all
        let beforeCount = locations.count
        locations.removeAll { location in location.resolvedURL == nil }
        if locations.count < beforeCount {
            changed = true
            let prunedCount = beforeCount - locations.count
            Self.logger.info("Pruned \(prunedCount) broken bookmarks")
        }

        if changed {
            save()
        }

        updateIOSSystemConfig()

        let count = locations.count
        Self.logger.info("Synced \(count) bookmarked locations on launch")
    }

    func configureIOSSystem() {
        let paths = locations.compactMap { $0.resolvedURL?.path }

        // Always call ios_setAllowedPaths — passing empty clears previous config
        ios_setAllowedPaths(paths)

        // Set up the UserDefaults dictionary for tilde expansion
        var bookmarkDict: [String: String] = [:]
        for location in locations {
            if let resolvedPath = location.resolvedURL?.path {
                bookmarkDict[location.name] = resolvedPath
            }
        }
        UserDefaults.standard.set(bookmarkDict, forKey: "ghosttyBookmarkNames")
        ios_setBookmarkDictionaryName("ghosttyBookmarkNames")
    }

    // MARK: - Path Resolution for File Access

    /// Returns a security-scoped URL for the given path if it matches or is under
    /// a bookmarked location. RF and other file browsers need this to access
    /// bookmarked directories through FileManager, since security-scoped access
    /// is tied to the resolved bookmark URL, not arbitrary symlink paths.
    func accessibleURL(for path: String) -> URL? {
        let standardized = (path as NSString).standardizingPath
        let docs = (documentsURL.path as NSString).standardizingPath

        for location in locations {
            guard let resolvedURL = location.resolvedURL else { continue }
            let resolvedPath = (resolvedURL.path as NSString).standardizingPath

            // Check if path is the bookmark symlink in Documents (~/BookmarkName)
            let symlinkPath = (docs as NSString).appendingPathComponent(location.name)
            if standardized == symlinkPath {
                return resolvedURL
            }
            if standardized.hasPrefix(symlinkPath + "/") {
                let relative = String(standardized.dropFirst(symlinkPath.count))
                return URL(fileURLWithPath: resolvedPath + relative)
            }

            // Check if path matches the resolved external path directly
            if standardized == resolvedPath {
                return resolvedURL
            }
            if standardized.hasPrefix(resolvedPath + "/") {
                let relative = String(standardized.dropFirst(resolvedPath.count))
                return URL(fileURLWithPath: resolvedPath + relative)
            }
        }
        return nil
    }

    /// True if `path` is reachable by the local shell sandbox: inside the app's
    /// Documents directory, or inside (or equal to) a bookmarked external
    /// location. Mirrors the access boundary enforced by `ios_setMiniRoot` +
    /// `ios_setAllowedPaths`, so callers (e.g. SFTP `lcd`) stay consistent with
    /// the shell's own `cd`.
    func isAccessiblePath(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let docs = (documentsURL.path as NSString).standardizingPath
        if standardized == docs || standardized.hasPrefix(docs + "/") { return true }
        return accessibleURL(for: standardized) != nil
    }

    /// Returns the bookmark name for a path if it matches a bookmarked location,
    /// for display purposes (e.g., showing `~BookmarkName/subdir` in the header).
    func bookmarkName(for path: String) -> (name: String, relativePath: String)? {
        let standardized = (path as NSString).standardizingPath
        let docs = (documentsURL.path as NSString).standardizingPath

        for location in locations {
            guard let resolvedURL = location.resolvedURL else { continue }
            let resolvedPath = (resolvedURL.path as NSString).standardizingPath

            // Match against the resolved external path
            if standardized == resolvedPath {
                return (location.name, "")
            }
            if standardized.hasPrefix(resolvedPath + "/") {
                let relative = String(standardized.dropFirst(resolvedPath.count + 1))
                return (location.name, relative)
            }

            // Match against the symlink path in Documents
            let symlinkPath = (docs as NSString).appendingPathComponent(location.name)
            if standardized == symlinkPath {
                return (location.name, "")
            }
            if standardized.hasPrefix(symlinkPath + "/") {
                let relative = String(standardized.dropFirst(symlinkPath.count + 1))
                return (location.name, relative)
            }
        }
        return nil
    }

    /// Returns true if the given entry name in Documents is a bookmark symlink.
    func isBookmarkSymlink(named name: String) -> Bool {
        locations.contains { $0.name == name }
    }

    // MARK: - Name Validation

    func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            throw BookmarkedLocationError.emptyName
        }

        if trimmed.count > 64 {
            throw BookmarkedLocationError.nameTooLong
        }

        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains(" ") || trimmed.contains("\t") {
            throw BookmarkedLocationError.invalidCharacters
        }

        if trimmed == "." || trimmed == ".." || trimmed.hasPrefix(".") {
            throw BookmarkedLocationError.reservedName
        }

        if locations.contains(where: { $0.name == trimmed }) {
            throw BookmarkedLocationError.duplicateName
        }

        // Check for existing files/folders in Documents (but not our own symlinks)
        let targetPath = documentsURL.appendingPathComponent(trimmed).path
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: targetPath, isDirectory: &isDir) {
            // Check if it's one of our existing symlinks
            let attrs = try? fileManager.attributesOfItem(atPath: targetPath)
            let fileType = attrs?[.type] as? FileAttributeType
            if fileType != .typeSymbolicLink {
                throw BookmarkedLocationError.nameConflictsWithExistingFile
            }
        }
    }

    // MARK: - Private

    private func updateIOSSystemConfig() {
        let paths = locations.compactMap { $0.resolvedURL?.path }

        // Always call even when empty to clear stale config after last-bookmark removal
        ios_setAllowedPaths(paths)

        var bookmarkDict: [String: String] = [:]
        for location in locations {
            if let resolvedPath = location.resolvedURL?.path {
                bookmarkDict[location.name] = resolvedPath
            }
        }
        UserDefaults.standard.set(bookmarkDict, forKey: "ghosttyBookmarkNames")
        ios_setBookmarkDictionaryName("ghosttyBookmarkNames")
    }

    private func save() {
        do {
            // Ensure config directory exists
            if !fileManager.fileExists(atPath: configDir.path) {
                try fileManager.createDirectory(at: configDir, withIntermediateDirectories: true)
            }

            let data = try JSONEncoder().encode(locations)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save bookmarked locations: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            locations = []
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            locations = try JSONDecoder().decode([BookmarkedLocation].self, from: data)
        } catch {
            Self.logger.error("Failed to load bookmarked locations: \(error.localizedDescription)")
            locations = []
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
