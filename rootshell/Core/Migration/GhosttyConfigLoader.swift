//
//  GhosttyConfigLoader.swift
//  rootshell
//
//  Reads a ghostty-format config file and resolves `config-file = path`
//  includes (depth-limited, cycle-safe). Shared by the one-shot importer
//  and the live config overlay.
//

import Foundation

nonisolated enum GhosttyConfigLoader {
    static let maxIncludeDepth = 3
    static let maxFileBytes = 256 * 1024

    struct Result: Sendable {
        var entries: [ParsedConfigEntry] = []
        var warnings: [String] = []
        /// Every file that contributed entries, root first.
        var files: [URL] = []
    }

    enum LoadError: Error {
        case readFailed(String)
        case tooLarge(Int)
    }

    /// Load `url` and its includes. Throws only for the root file.
    static func load(_ url: URL) throws -> Result {
        var result = Result()
        var seen: Set<URL> = []
        try collect(from: url, depth: 0, into: &result, seen: &seen)
        return result
    }

    private static func collect(from url: URL, depth: Int, into result: inout Result, seen: inout Set<URL>) throws {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if seen.contains(canonical) {
            result.warnings.append(String(localized: "Skipped duplicate include: \(url.lastPathComponent)",
                                          comment: "Config warning: duplicate include"))
            return
        }
        seen.insert(canonical)

        let contents: String
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= maxFileBytes else { throw LoadError.tooLarge(data.count) }
            guard let text = String(data: data, encoding: .utf8) else {
                throw LoadError.readFailed("not UTF-8")
            }
            contents = text
        } catch {
            if depth == 0 { throw LoadError.readFailed(error.localizedDescription) }
            result.warnings.append(String(localized: "Could not read include \(url.lastPathComponent): \(error.localizedDescription)",
                                          comment: "Config warning: include read failed"))
            return
        }

        let parsed = GhosttyConfigParser.parse(contents, sourceFile: url)
        result.entries.append(contentsOf: parsed)
        result.files.append(url)

        guard depth < maxIncludeDepth else {
            if parsed.contains(where: { $0.key == "config-file" }) {
                result.warnings.append(String(localized: "Reached maximum include depth (\(maxIncludeDepth)); deeper config-file entries skipped.",
                                              comment: "Config warning: include depth"))
            }
            return
        }

        let parentDir = url.deletingLastPathComponent()
        for include in parsed where include.key == "config-file" {
            let (path, optional) = parseIncludeValue(include.value)
            guard !path.isEmpty else { continue }
            let resolved = resolveIncludePath(path, relativeTo: parentDir)
            if !FileManager.default.fileExists(atPath: resolved.path) {
                if !optional {
                    result.warnings.append(String(localized: "Include not found: \(path)",
                                                  comment: "Config warning: missing include"))
                }
                continue
            }
            do {
                try collect(from: resolved, depth: depth + 1, into: &result, seen: &seen)
            } catch {
                result.warnings.append(String(localized: "Include failed: \(path) (\(error.localizedDescription))",
                                              comment: "Config warning: include failed"))
            }
        }
    }

    static func parseIncludeValue(_ raw: String) -> (path: String, optional: Bool) {
        var v = raw
        var optional = false
        if v.hasPrefix("?") {
            optional = true
            v.removeFirst()
        }
        return (v.trimmingCharacters(in: .whitespaces), optional)
    }

    static func resolveIncludePath(_ path: String, relativeTo dir: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return dir.appendingPathComponent(expanded)
    }
}
