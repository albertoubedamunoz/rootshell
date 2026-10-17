#if !targetEnvironment(macCatalyst)

import Combine
import Foundation
import OSLog

// MARK: - Data Model

nonisolated struct BookmarkedLocation: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var bookmarkData: Data

    /// Resolved URL from bookmark data (transient, not encoded)
    var resolvedURL: URL?
    /// Whether the bookmark data is stale and needs re-creation
    var isStale: Bool = false

    // Decoding stays pure: bookmark resolution is a blocking FileProvider XPC
    // call and only happens off main in `syncOnLaunch`.
    enum CodingKeys: String, CodingKey {
        case id, name, bookmarkData
    }

    init(id: UUID = UUID(), name: String, bookmarkData: Data) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
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
    private var syncTask: Task<Void, Never>?

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
        let previous = syncTask
        syncTask = Task {
            await previous?.value
            await performSync()
        }
    }

    /// Waits for bookmark access to be restored. Shell setup awaits this so a
    /// bookmarked working directory or `.rootshellrc` path resolves.
    func waitUntilSynced() async {
        if syncTask == nil {
            syncOnLaunch()
        }
        await syncTask?.value
    }

    private func performSync() async {
        // Stop any previously accessed URLs to avoid leaking access counts
        // on repeated calls (e.g., scene recreation, multiple windows)
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()

        // Load before resolving so add/remove during resolution edits (and
        // saves) the full stored list.
        locations = Self.loadLocations(from: storageURL)

        let resolved = await Self.resolveLocations(locations)
        let resolvedByID = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Release access for locations removed while resolving.
        let currentIDs = Set(locations.map(\.id))
        for location in resolved where !currentIDs.contains(location.id) {
            location.resolvedURL?.stopAccessingSecurityScopedResource()
        }

        var changed = false
        var prunedCount = 0
        locations = locations.compactMap { location in
            // Added while resolving: addLocation already holds its access.
            guard let result = resolvedByID[location.id] else { return location }
            guard let url = result.resolvedURL else {
                prunedCount += 1
                return nil
            }
            accessedURLs[location.id] = url
            recreateSymlinkIfMissing(name: location.name, destination: url)
            if result.bookmarkData != location.bookmarkData {
                changed = true
            }
            return result
        }

        if prunedCount > 0 {
            changed = true
            Self.logger.info("Pruned \(prunedCount) broken bookmarks")
        }

        if changed {
            save()
        }

        updateIOSSystemConfig()

        let count = locations.count
        Self.logger.info("Synced \(count) bookmarked locations on launch")
    }

    /// Runs after reconciling with the current list so a bookmark removed while
    /// resolving doesn't get its symlink back.
    private func recreateSymlinkIfMissing(name: String, destination: URL) {
        let symlinkPath = documentsURL.appendingPathComponent(name).path
        guard !fileManager.fileExists(atPath: symlinkPath) else { return }
        do {
            try fileManager.createSymbolicLink(
                atPath: symlinkPath,
                withDestinationPath: destination.path
            )
            Self.logger.info("Recreated symlink for: \(name)")
        } catch {
            Self.logger.error("Failed to recreate symlink for \(name): \(error.localizedDescription)")
        }
    }

    /// Resolves and starts accessing bookmarks off the main actor: each resolution
    /// is a synchronous XPC to fileproviderd, which can stall for seconds right
    /// after boot or while locked. Unresolvable entries keep a nil `resolvedURL`.
    @concurrent
    private nonisolated static func resolveLocations(
        _ locations: [BookmarkedLocation]
    ) async -> [BookmarkedLocation] {
        var locations = locations

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

            // Re-create bookmark if stale
            if stale {
                if let newData = try? url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    locations[i].bookmarkData = newData
                    locations[i].isStale = false
                    let name = location.name
                    Self.logger.info("Refreshed stale bookmark for: \(name)")
                }
            }
        }

        return locations
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

    private nonisolated static func loadLocations(from storageURL: URL) -> [BookmarkedLocation] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode([BookmarkedLocation].self, from: data)
        } catch {
            logger.error("Failed to load bookmarked locations: \(error.localizedDescription)")
            return []
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
