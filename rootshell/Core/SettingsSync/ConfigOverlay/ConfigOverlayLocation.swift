//
//  ConfigOverlayLocation.swift
//  rootshell
//
//  Where the user-facing text config lives on each platform, and how it
//  reads from the shell. Distinct from the generated GhosttyKit config.
//

import Foundation

nonisolated enum ConfigOverlayLocation {
    #if STANDALONE && targetEnvironment(macCatalyst)
    /// Non-sandboxed Mac. The process sets XDG_CONFIG_HOME to Application
    /// Support for GhosttyKit, so that variable is deliberately ignored here.
    static var canonicalURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/rootshell/config")
    }

    /// Where an earlier build wrote the file by following XDG_CONFIG_HOME.
    static var legacyApplicationSupportURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("rootshell", isDirectory: true)
            .appendingPathComponent("config")
    }

    static let canonicalShellPath = "~/.config/rootshell/config"
    static let supportsDirectExternalPath = true
    #else
    /// Sandboxed builds: a visible file in Documents (Files app on iOS).
    static var canonicalURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rootshell.conf")
    }

    #if targetEnvironment(macCatalyst)
    static let canonicalShellPath = "~/Documents/rootshell.conf"
    #else
    static let canonicalShellPath = "~/rootshell.conf"
    #endif
    static let supportsDirectExternalPath = false
    static var legacyApplicationSupportURL: URL? { nil }
    #endif

    /// Resolve a user-picked external file from the stored bookmark or path.
    static func externalURL(bookmark: Data?, path: String?) -> (url: URL, isStale: Bool)? {
        if let path, supportsDirectExternalPath {
            return (URL(fileURLWithPath: (path as NSString).expandingTildeInPath), false)
        }
        guard let bookmark else { return nil }
        var stale = false
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale) else {
            return nil
        }
        return (url, stale)
    }

    static func makeBookmark(for url: URL) -> Data? {
        #if targetEnvironment(macCatalyst)
        return try? url.bookmarkData(options: [.withSecurityScope])
        #else
        return try? url.bookmarkData()
        #endif
    }

    /// Path as the user would type it in the app's shell.
    static func shellDisplayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.standardizedFileURL.path
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
