//
//  HSSConfigManager.swift
//  rootshell
//
//  Manages HSS configuration file selection and persistence
//

import Foundation
import Combine
import os.log

/// Status of the HSS configuration
enum HSSConfigStatus: Equatable {
    case none                       // No config selected
    case loading                    // Currently loading/parsing
    case loaded(patternCount: Int)  // Successfully loaded with N patterns
    case error(String)              // Error loading/parsing
    case staleBookmark              // Bookmark needs refresh

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// Manages HSS configuration file selection and parsing
@MainActor
final class HSSConfigManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HSSConfigManager")

    static let shared = HSSConfigManager()

    // UserDefaults keys
    private static let bookmarkKey = "hss_config_bookmark"      // macOS Catalyst only
    private static let filePathKey = "hss_config_filepath"      // iOS only
    private static let fileNameKey = "hss_config_filename"

    // Published state
    @Published private(set) var status: HSSConfigStatus = .none
    @Published private(set) var fileName: String?
    @Published private(set) var lastLoadDate: Date?

    // Internal parser
    let parser: HSSParser

    // Bookmark data
    private var bookmarkData: Data?
    private var resolvedURL: URL?

    private init() {
        self.parser = HSSParser()
        loadBookmark()
    }

    // MARK: - Public Methods

    /// Import an HSS config file from a URL
    /// On macOS Catalyst: Creates a security-scoped bookmark for persistent access
    /// On iOS: Copies the file to app's Documents folder
    func importFile(from url: URL) throws {
        Self.logger.info("Importing HSS config from: \(url.path)")

        // Ensure we have security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            throw HSSError.fileAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // Read and validate YAML content first
        do {
            try parser.loadConfig(from: url)
        } catch {
            throw HSSError.configParseError(underlying: error)
        }

        #if targetEnvironment(macCatalyst)
        // macOS Catalyst: Use security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Store bookmark and metadata
            saveBookmark(bookmarkData, fileName: url.lastPathComponent)

            // Update state
            self.resolvedURL = url
            self.fileName = url.lastPathComponent
            self.lastLoadDate = Date()
            self.status = .loaded(patternCount: parser.patternCount)

            Self.logger.info("Successfully imported HSS config with \(self.parser.patternCount) patterns (bookmark)")
        } catch {
            Self.logger.error("Failed to create bookmark: \(error.localizedDescription)")
            throw HSSError.bookmarkCreationFailed
        }
        #else
        // iOS: Copy file to Documents folder
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let hssFolder = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        let destinationURL = hssFolder.appendingPathComponent("hss_config.yml")

        do {
            // Create .ghostty folder if needed
            try FileManager.default.createDirectory(at: hssFolder, withIntermediateDirectories: true)

            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            // Copy the file
            try FileManager.default.copyItem(at: url, to: destinationURL)

            // Save the file path for reload
            UserDefaults.standard.set(destinationURL.path, forKey: Self.filePathKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: Self.fileNameKey)

            // Update state
            self.resolvedURL = destinationURL
            self.fileName = url.lastPathComponent
            self.lastLoadDate = Date()
            self.status = .loaded(patternCount: parser.patternCount)

            Self.logger.info("Successfully imported HSS config with \(self.parser.patternCount) patterns (copy)")
        } catch {
            Self.logger.error("Failed to copy file: \(error.localizedDescription)")
            throw HSSError.bookmarkCreationFailed
        }
        #endif
    }

    /// Reload the config from the bookmarked/stored file
    func reload() async {
        #if targetEnvironment(macCatalyst)
        guard bookmarkData != nil else {
            Self.logger.info("No bookmark to reload")
            return
        }
        #else
        guard resolvedURL != nil else {
            Self.logger.info("No file to reload")
            return
        }
        #endif

        status = .loading
        await resolveAndLoadConfig()
    }

    /// Clear the current config
    func clearConfig() {
        Self.logger.info("Clearing HSS config")

        parser.clearConfig()

        // Remove stored data
        #if targetEnvironment(macCatalyst)
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        #else
        // Delete the copied file on iOS
        if let url = resolvedURL {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: Self.filePathKey)
        #endif
        UserDefaults.standard.removeObject(forKey: Self.fileNameKey)

        // Reset state
        bookmarkData = nil
        resolvedURL = nil
        fileName = nil
        lastLoadDate = nil
        status = .none
    }

    /// Check if input is an HSS shorthand (starts with "!")
    static func isHSSShorthand(_ input: String) -> Bool {
        input.hasPrefix("!")
    }

    /// Expand an HSS shorthand (removes "!" prefix and expands)
    func expand(_ shorthand: String) throws -> String? {
        let input = shorthand.hasPrefix("!") ? String(shorthand.dropFirst()) : shorthand
        return try parser.expand(input)
    }

    /// Resolve an HSS shorthand to connection details
    func resolve(_ shorthand: String) throws -> HSSResolution? {
        guard let expanded = try expand(shorthand) else {
            return nil
        }
        return HSSSSHParser.parse(expanded)
    }

    // MARK: - Accessors

    /// Get all patterns for display
    var patterns: [HSSPattern] {
        parser.patterns
    }

    /// Check if any patterns are loaded
    var hasPatterns: Bool {
        parser.isLoaded
    }

    // MARK: - Private Methods

    private func loadBookmark() {
        #if targetEnvironment(macCatalyst)
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            Self.logger.info("No HSS config bookmark found")
            status = .none
            return
        }

        bookmarkData = data
        fileName = UserDefaults.standard.string(forKey: Self.fileNameKey)

        Self.logger.info("Found HSS config bookmark for: \(self.fileName ?? "unknown")")
        #else
        guard let filePath = UserDefaults.standard.string(forKey: Self.filePathKey) else {
            Self.logger.info("No HSS config file found")
            status = .none
            return
        }

        resolvedURL = URL(fileURLWithPath: filePath)
        fileName = UserDefaults.standard.string(forKey: Self.fileNameKey)

        Self.logger.info("Found HSS config file for: \(self.fileName ?? "unknown")")
        #endif

        // Load config asynchronously
        Task {
            await resolveAndLoadConfig()
        }
    }

    private func saveBookmark(_ data: Data, fileName: String) {
        bookmarkData = data
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(fileName, forKey: Self.fileNameKey)
    }

    private func resolveAndLoadConfig() async {
        status = .loading

        #if targetEnvironment(macCatalyst)
        guard let bookmarkData = bookmarkData else {
            status = .none
            return
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                Self.logger.warning("HSS config bookmark is stale")
                status = .staleBookmark
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                Self.logger.error("Cannot access HSS config file")
                status = .error("Cannot access file")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Load the config
            try parser.loadConfig(from: url)

            resolvedURL = url
            lastLoadDate = Date()
            status = .loaded(patternCount: parser.patternCount)

            Self.logger.info("Loaded HSS config with \(self.parser.patternCount) patterns")

        } catch {
            Self.logger.error("Failed to load HSS config: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
        #else
        // iOS: Load directly from copied file
        guard let url = resolvedURL else {
            status = .none
            return
        }

        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                Self.logger.error("HSS config file no longer exists")
                status = .error("File not found")
                return
            }

            // Load the config
            try parser.loadConfig(from: url)

            lastLoadDate = Date()
            status = .loaded(patternCount: parser.patternCount)

            Self.logger.info("Loaded HSS config with \(self.parser.patternCount) patterns")

        } catch {
            Self.logger.error("Failed to load HSS config: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
        #endif
    }
}
