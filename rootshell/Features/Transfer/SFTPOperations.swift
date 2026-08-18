//
//  SFTPOperations.swift
//  rootshell
//
//  Shared, stateless SFTP utilities used by both SFTPSession (CLI) and
//  RFSFTPDataSource (file browser). All methods are static to avoid
//  duplicating logic across consumers.
//

import Foundation
import Citadel
import NIOCore
import NIOFoundationCompat

/// Shared stateless SFTP operations.
/// Both the interactive SFTP shell (SFTPSession) and the file browser
/// SFTP backend (RFSFTPDataSource) call through to these methods.
enum SFTPOperations {

    // MARK: - Directory Listing (rf file browser only)

    #if !targetEnvironment(macCatalyst)
    /// List directory contents and map to RFEntry structs suitable for the file browser.
    static func listDirectoryEntries(
        sftp: SFTPClient,
        path: String
    ) async throws -> [RFEntry] {
        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: path)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }

        var entries: [RFEntry] = []
        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }

                let fullPath = joinPath(path, filename)
                let entry = attributesToEntry(
                    filename: filename,
                    path: fullPath,
                    attrs: component.attributes,
                    longname: component.longname
                )
                entries.append(entry)
            }
        }
        return entries
    }

    /// Map SFTPFileAttributes to an RFEntry.
    static func attributesToEntry(
        filename: String,
        path: String,
        attrs: SFTPFileAttributes,
        longname: String? = nil
    ) -> RFEntry {
        let isDir = isDirectory(attrs)
        // Longname starting with 'l' indicates symlink in ls -l output
        let isLink = longname?.first == "l"
        // Clamp to avoid trapping on a malicious/buggy server returning size > Int64.max.
        let size = Int64(clamping: attrs.size ?? 0)

        // Check execute bit for owner
        let isExec: Bool
        if let mode = attrs.permissions {
            isExec = !isDir && (mode & 0o100) != 0
        } else {
            isExec = false
        }

        return RFEntry(
            name: filename,
            path: path,
            isDirectory: isDir,
            isSymlink: isLink,
            isHidden: filename.hasPrefix("."),
            isExecutable: isExec,
            size: size,
            modifiedDate: nil,
            gitStatus: nil
        )
    }
    #endif

    // MARK: - Recursive Enumeration

    /// Recursively enumerate all files in a remote directory.
    /// Returns (path, size) pairs for files only.
    static func enumerateRemoteDirectory(
        sftp: SFTPClient,
        path: String
    ) async throws -> [(path: String, size: UInt64)] {
        var results: [(String, UInt64)] = []
        let nameMessages = try await sftp.listDirectory(atPath: path)

        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }

                let fullPath = joinPath(path, filename)
                var attrs = component.attributes
                if attrs.permissions == nil, let fetched = try? await sftp.getAttributes(at: fullPath) {
                    attrs = fetched
                }

                if isDirectory(attrs) {
                    let subResults = try await enumerateRemoteDirectory(sftp: sftp, path: fullPath)
                    results.append(contentsOf: subResults)
                } else {
                    results.append((fullPath, attrs.size ?? 0))
                }
            }
        }

        return results
    }

    // MARK: - File Reading

    /// Read the first `maxBytes` of a remote file. Returns the data read.
    /// Useful for preview (text, binary detection, etc.)
    static func readFileHead(
        sftp: SFTPClient,
        path: String,
        maxBytes: Int
    ) async throws -> Data {
        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: path, flags: .read)
        } catch {
            throw SFTPError.from(sftpError: error, path: path)
        }

        defer {
            Task { try? await file.close() }
        }

        // Read in one chunk up to maxBytes
        let chunkSize = UInt32(min(maxBytes, 1_048_576))
        let buffer = try await file.read(from: 0, length: chunkSize)
        return Data(buffer: buffer)
    }

    /// Download an entire remote file to a local path.
    /// Uses PipelinedTransfer for efficiency.
    static func downloadFile(
        sftp: SFTPClient,
        remotePath: String,
        localPath: String,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        // Ensure local directory exists
        let localDir = (localPath as NSString).deletingLastPathComponent
        if !localDir.isEmpty {
            try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)
        }

        FileManager.default.createFile(atPath: localPath, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: localPath))
        try handle.truncate(atOffset: 0)
        defer { try? handle.close() }

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: .read)
        } catch {
            throw SFTPError.from(sftpError: error, path: remotePath)
        }

        do {
            let attrs = try? await file.readAttributes()
            try await PipelinedTransfer.downloadFile(
                file: file,
                fileSize: attrs?.size,
                to: handle
            ) { bytes in
                onProgress?(bytes)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw SFTPError.from(sftpError: error, path: remotePath)
        }
    }

    /// Upload a local file to a remote path.
    /// Uses PipelinedTransfer for efficiency.
    static func uploadFile(
        sftp: SFTPClient,
        localPath: String,
        remotePath: String,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        // Ensure remote directory exists
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        if !remoteDir.isEmpty && remoteDir != "." && remoteDir != "/" {
            try await createDirectoryIfNeeded(sftp: sftp, path: remoteDir)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        } catch {
            throw SFTPError.fileNotFound(path: localPath)
        }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
        let fileSize = attrs?[.size] as? UInt64

        let file: SFTPFile
        do {
            file = try await sftp.openFile(filePath: remotePath, flags: [.create, .write, .truncate])
        } catch {
            throw SFTPError.from(sftpError: error, path: remotePath)
        }

        do {
            try await PipelinedTransfer.uploadFile(
                file: file,
                from: handle,
                fileSize: fileSize
            ) { bytes in
                onProgress?(bytes)
            }
            try await file.close()
        } catch {
            try? await file.close()
            throw SFTPError.from(sftpError: error, path: remotePath)
        }
    }

    // MARK: - Directory Operations

    /// Create a remote directory, creating parents recursively as needed.
    static func createDirectoryIfNeeded(
        sftp: SFTPClient,
        path: String
    ) async throws {
        // Try to get attributes — if it succeeds, directory exists
        do {
            _ = try await sftp.getAttributes(at: path)
            return
        } catch {
            // Directory doesn't exist, continue
        }

        // Create parent directories first
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "." && parent != "/" {
            try await createDirectoryIfNeeded(sftp: sftp, path: parent)
        }

        // Create this directory
        do {
            try await sftp.createDirectory(atPath: path)
        } catch {
            // Might already exist due to race condition
            do {
                _ = try await sftp.getAttributes(at: path)
            } catch {
                throw SFTPError.from(sftpError: error, path: path)
            }
        }
    }

    // MARK: - Path Utilities

    /// Join two POSIX path components.
    static func joinPath(_ base: String, _ component: String) -> String {
        if component.isEmpty { return base }
        let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let cleanComponent = component.hasPrefix("/") ? String(component.dropFirst()) : component
        return cleanBase + "/" + cleanComponent
    }

    /// Normalize a POSIX-style remote path lexically, collapsing `.` and `..`
    /// without requiring the path to exist on the remote server.
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return "." }

        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }

        if isAbsolute {
            return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        }

        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// Get the parent directory of a POSIX path.
    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Split path into directory and filename.
    static func splitPath(_ path: String) -> (directory: String, filename: String) {
        let nsPath = path as NSString
        return (nsPath.deletingLastPathComponent, nsPath.lastPathComponent)
    }

    /// Resolve a remote path, handling ~, ., relative, and absolute paths.
    static func resolvePath(
        _ rawPath: String,
        cwd: String,
        sftp: SFTPClient
    ) async throws -> String {
        // Turn escaped glob metacharacters back into literals for the real path.
        let path = unescapePath(rawPath)

        if path.isEmpty || path == "." {
            return cwd
        }

        if path.hasPrefix("/") {
            return path
        }

        if path.hasPrefix("~") {
            let homePath = try await sftp.getRealPath(atPath: ".")

            if path == "~" {
                return homePath
            } else if path.hasPrefix("~/") {
                let suffix = String(path.dropFirst(2))
                return joinPath(homePath, suffix)
            }
        }

        // Relative path
        return joinPath(cwd, path)
    }

    // MARK: - Attribute Checks

    /// Check if SFTP attributes indicate a directory (S_IFDIR).
    static func isDirectory(_ attrs: SFTPFileAttributes) -> Bool {
        if let mode = attrs.permissions {
            return (mode & 0o170000) == 0o040000
        }
        return false
    }

    // MARK: - Glob Utilities

    private static let globChars: Set<Character> = ["*", "?", "[", "]"]

    /// Check if a path contains a glob character.
    ///
    /// `escapeAware` selects the escaping convention of the caller's tokenizer:
    /// - `false` (default, SCP): legacy behavior — any metacharacter is a glob.
    /// - `true` (SFTP): canonical escapes, where a backslash always escapes the next
    ///   char (`\\` = literal backslash, `\*` = literal `*`), so an escaped char is
    ///   never a glob. Thus `rm foo\*` is literal while `rm foo\\*` (a literal
    ///   backslash then a `*` wildcard) is a glob.
    ///
    /// The conventions differ because SCP's tokenizer is lossy (it collapses `\\` to
    /// `\`), so its tokens cannot be interpreted as canonical escapes.
    static func containsGlob(_ path: String, escapeAware: Bool = false) -> Bool {
        guard escapeAware else {
            return path.contains(where: { globChars.contains($0) })
        }
        var escaped = false
        for ch in path {
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if globChars.contains(ch) {
                return true
            }
        }
        return false
    }

    /// Strip escapes from a tokenized path, producing the literal filesystem path.
    /// A backslash always escapes the next char (canonical token form), so `\\` →
    /// `\` and `\*` → `*`.
    static func unescapePath(_ path: String) -> String {
        guard path.contains("\\") else { return path }
        let chars = Array(path)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                result.append(chars[i + 1])
                i += 2
            } else {
                result.append(chars[i])
                i += 1
            }
        }
        return result
    }

    /// Split glob path into directory and filename pattern components.
    static func splitGlobPattern(_ path: String) -> (directory: String, pattern: String) {
        let nsPath = path as NSString
        let dir = nsPath.deletingLastPathComponent
        let pattern = nsPath.lastPathComponent
        return (dir.isEmpty ? "." : dir, pattern)
    }

    /// Check if a filename matches a glob pattern (supports *, ?, [...]).
    ///
    /// `escapeAware` must match the convention used by `containsGlob` for the same
    /// caller: `true` (SFTP) treats a backslash as escaping the next char; `false`
    /// (default, SCP) treats a backslash as a literal backslash.
    static func matchesGlob(_ name: String, pattern: String, escapeAware: Bool = false) -> Bool {
        var regex = "^"
        var i = pattern.startIndex

        while i < pattern.endIndex {
            let char = pattern[i]
            switch char {
            case "\\":
                let next = pattern.index(after: i)
                if escapeAware, next < pattern.endIndex {
                    // Canonical: backslash escapes the next char → match it literally.
                    regex += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                    i = next
                } else {
                    // Legacy (or a trailing backslash): a literal backslash.
                    regex += "\\\\"
                }
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case "[":
                if let closeIndex = pattern[i...].firstIndex(of: "]") {
                    let classContent = String(pattern[i...closeIndex])
                    regex += classContent
                    i = closeIndex
                } else {
                    regex += "\\["
                }
            case ".":
                regex += "\\."
            case "^", "$", "+", "{", "}", "|", "(", ")":
                regex += "\\\(char)"
            default:
                regex += String(char)
            }
            i = pattern.index(after: i)
        }
        regex += "$"

        do {
            let regexObj = try NSRegularExpression(pattern: regex, options: [])
            return regexObj.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        } catch {
            return name == pattern
        }
    }

    /// Expand a remote glob pattern into matching full paths.
    static func expandRemoteGlob(
        sftp: SFTPClient,
        pattern: String,
        cwd: String
    ) async throws -> [String] {
        let (directory, filePattern) = splitGlobPattern(pattern)
        let includeDotfiles = filePattern.hasPrefix(".")

        let nameMessages: [SFTPMessage.Name]
        do {
            nameMessages = try await sftp.listDirectory(atPath: directory)
        } catch {
            throw SFTPError.from(sftpError: error, path: pattern)
        }

        var matchingPaths: [String] = []
        for nameMessage in nameMessages {
            for component in nameMessage.components {
                let filename = component.filename
                guard filename != "." && filename != ".." else { continue }
                if !includeDotfiles && filename.hasPrefix(".") { continue }
                // SFTP-only path; its patterns use the canonical (escape-aware) form.
                if matchesGlob(filename, pattern: filePattern, escapeAware: true) {
                    matchingPaths.append(joinPath(directory, filename))
                }
            }
        }

        return matchingPaths.sorted()
    }

    /// Resolve a glob pattern's directory portion while keeping the filename glob untouched.
    static func resolveRemoteGlobPattern(
        _ pattern: String,
        cwd: String,
        sftp: SFTPClient
    ) async throws -> String {
        let (dir, filePattern) = splitGlobPattern(pattern)
        // SFTP-only path; its patterns use the canonical (escape-aware) form.
        if containsGlob(dir, escapeAware: true) {
            throw SFTPError.invalidArguments("Wildcards only supported in the last path component: \(pattern)")
        }
        let resolvedDir = try await resolvePath(dir, cwd: cwd, sftp: sftp)
        let canonicalDir = try await sftp.getRealPath(atPath: resolvedDir)
        return joinPath(canonicalDir, filePattern)
    }

    // MARK: - Formatting Helpers

    /// Format file permissions as rwxrwxrwx string.
    static func formatPermissions(_ mode: UInt32) -> String {
        let userMode = (mode >> 6) & 0o7
        let groupMode = (mode >> 3) & 0o7
        let otherMode = mode & 0o7

        func modeToString(_ m: UInt32) -> String {
            let r = (m & 0o4) != 0 ? "r" : "-"
            let w = (m & 0o2) != 0 ? "w" : "-"
            let x = (m & 0o1) != 0 ? "x" : "-"
            return r + w + x
        }

        return modeToString(userMode) + modeToString(groupMode) + modeToString(otherMode)
    }

    /// Format byte count for display.
    static func formatSize(_ size: Int64) -> String {
        if size < 1024 {
            return String(format: "%5d", size)
        } else if size < 1024 * 1024 {
            return String(format: "%4.1fK", Double(size) / 1024)
        } else if size < 1024 * 1024 * 1024 {
            return String(format: "%4.1fM", Double(size) / (1024 * 1024))
        } else {
            return String(format: "%4.1fG", Double(size) / (1024 * 1024 * 1024))
        }
    }

    /// Format date in ls-style (recent = time, old = year).
    static func formatDate(_ date: Date?) -> String {
        guard let date else { return "            " }

        let formatter = DateFormatter()
        let now = Date()
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now

        if date > sixMonthsAgo {
            formatter.dateFormat = "MMM dd HH:mm"
        } else {
            formatter.dateFormat = "MMM dd  yyyy"
        }

        return formatter.string(from: date)
    }

    /// Format transfer throughput for display.
    static func formatThroughput(_ bps: Double) -> String {
        if bps < 1024 {
            return String(format: "%.0f B/s", bps)
        } else if bps < 1024 * 1024 {
            return String(format: "%.1f KB/s", bps / 1024)
        } else {
            return String(format: "%.1f MB/s", bps / (1024 * 1024))
        }
    }

    /// Format byte count for human-readable display.
    static func formatByteCount(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else if bytes < 1024 * 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        } else {
            return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
        }
    }

    /// Compute relative path from a base path.
    static func relativePath(from base: String, fullPath: String) -> String {
        let cleanBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let prefix = cleanBase + "/"
        if fullPath.hasPrefix(prefix) {
            return String(fullPath.dropFirst(prefix.count))
        }
        return (fullPath as NSString).lastPathComponent
    }
}
