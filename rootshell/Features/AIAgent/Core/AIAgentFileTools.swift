#if !CHINA_BUILD
//
//  AIAgentFileTools.swift
//  rootshell
//
//  File operation tool handlers for the AI Agent (read_file, write_file, edit_file)
//  Available on all platforms
//

import Foundation
import os.log

/// Handles file operation tools for the AI Agent
struct AIAgentFileToolHandler {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "AIAgentFileTools")

    /// Maximum output length for file contents
    private static let maxOutputLength = 100_000

    // MARK: - read_file

    /// Read the contents of a file with optional offset and line limit
    ///
    /// When `sandboxRoot` is provided, access is strictly constrained to that
    /// directory (after symlink resolution) and the broader `isPathAllowed`
    /// sandbox is bypassed. This is used by the AI git commit flow, which has
    /// no per-call approval UI and must not be able to read files outside the
    /// repository.
    static func readFile(
        path: String,
        offset: Int?,
        limit: Int?,
        workingDirectory: String,
        sandboxRoot: String? = nil
    ) -> CommandExecutionResult {
        let startTime = Date()

        // Resolve path
        let resolvedPath: String
        if let sandboxRoot {
            guard let sandboxed = resolvePathInSandbox(path, sandboxRoot: sandboxRoot) else {
                Self.logger.error("read_file DENIED (outside sandbox): path=\(path, privacy: .public) sandboxRoot=\(sandboxRoot, privacy: .public)")
                return CommandExecutionResult(
                    output: "Error: Access denied. Path is outside the repository: \(path)",
                    exitCode: 1,
                    duration: Date().timeIntervalSince(startTime)
                )
            }
            resolvedPath = sandboxed
        } else {
            resolvedPath = resolvePath(path, workingDirectory: workingDirectory)
            guard isPathAllowed(resolvedPath) else {
                Self.logger.error("read_file DENIED (outside allowed dirs): path=\(path, privacy: .public) resolved=\(resolvedPath, privacy: .public)")
                return CommandExecutionResult(
                    output: "Error: Access denied. Path is outside the allowed directories: \(path) (resolved: \(resolvedPath))",
                    exitCode: 1,
                    duration: Date().timeIntervalSince(startTime)
                )
            }
        }

        let fileManager = FileManager.default

        // Check file exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return CommandExecutionResult(
                output: "Error: File not found: \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        guard !isDirectory.boolValue else {
            return CommandExecutionResult(
                output: "Error: Path is a directory, not a file: \(path). Use execute_command with 'ls' to list directory contents.",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Check for binary file
        if isBinaryFile(resolvedPath) {
            return CommandExecutionResult(
                output: "Error: File appears to be binary and cannot be displayed as text: \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Read file
        guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            return CommandExecutionResult(
                output: "Error: Could not read file (may not be UTF-8 encoded): \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        let allLines = content.components(separatedBy: "\n")
        let totalLines = allLines.count

        // Apply offset and limit
        let startLine = max(0, (offset ?? 1) - 1) // Convert 1-indexed to 0-indexed
        let endLine: Int
        if let limit = limit {
            endLine = min(startLine + limit, totalLines)
        } else {
            endLine = totalLines
        }

        guard startLine < totalLines else {
            return CommandExecutionResult(
                output: "Error: Offset \(startLine + 1) is beyond end of file (\(totalLines) lines)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Format with line numbers
        let selectedLines = allLines[startLine..<endLine]
        let lineNumberWidth = String(endLine).count
        var output = ""
        for (index, line) in selectedLines.enumerated() {
            let lineNumber = startLine + index + 1
            let paddedNumber = String(lineNumber).leftPadded(toLength: lineNumberWidth)
            output += "\(paddedNumber)\t\(line)\n"
        }

        // Add metadata header if partial read
        if startLine > 0 || endLine < totalLines {
            let header = "[Showing lines \(startLine + 1)-\(endLine) of \(totalLines) total]\n"
            output = header + output
        }

        // Truncate if too long
        if output.count > maxOutputLength {
            output = String(output.prefix(maxOutputLength)) + "\n... (truncated, \(totalLines) total lines)"
        }

        return CommandExecutionResult(
            output: output,
            exitCode: 0,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - write_file

    /// Create or overwrite a file with the given content
    static func writeFile(
        path: String,
        content: String,
        workingDirectory: String
    ) -> CommandExecutionResult {
        let startTime = Date()

        // Resolve path
        let resolvedPath = resolvePath(path, workingDirectory: workingDirectory)

        // Validate path is within sandbox
        guard isPathAllowed(resolvedPath) else {
            return CommandExecutionResult(
                output: "Error: Access denied. Path is outside the allowed directories: \(path) (resolved: \(resolvedPath))",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Create parent directories if needed
        let parentDir = (resolvedPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        } catch {
            return CommandExecutionResult(
                output: "Error: Could not create parent directory: \(error.localizedDescription)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Write file atomically
        do {
            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        } catch {
            return CommandExecutionResult(
                output: "Error: Could not write file: \(error.localizedDescription)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        let byteCount = content.utf8.count
        let lineCount = content.components(separatedBy: "\n").count

        return CommandExecutionResult(
            output: "Successfully wrote \(byteCount) bytes (\(lineCount) lines) to \(path)",
            exitCode: 0,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - edit_file

    /// Make a targeted edit by replacing an exact string match
    static func editFile(
        path: String,
        oldString: String,
        newString: String,
        workingDirectory: String
    ) -> CommandExecutionResult {
        let startTime = Date()

        // Resolve path
        let resolvedPath = resolvePath(path, workingDirectory: workingDirectory)

        // Validate path is within sandbox
        guard isPathAllowed(resolvedPath) else {
            return CommandExecutionResult(
                output: "Error: Access denied. Path is outside the allowed directories: \(path) (resolved: \(resolvedPath))",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Read existing file
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return CommandExecutionResult(
                output: "Error: File not found: \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            return CommandExecutionResult(
                output: "Error: Could not read file (may not be UTF-8 encoded): \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Find exact match
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 0 {
            // Not found - provide helpful context
            let preview = String(content.prefix(500))
            return CommandExecutionResult(
                output: "Error: old_string not found in file. The exact string must match including whitespace and line breaks.\n\nFile preview (first 500 chars):\n\(preview)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        if occurrences > 1 {
            return CommandExecutionResult(
                output: "Error: old_string matches \(occurrences) locations in the file. Provide more surrounding context in old_string to uniquely identify the edit location.",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        // Exactly one match - find the line number
        let matchRange = content.range(of: oldString)!
        let beforeMatch = content[content.startIndex..<matchRange.lowerBound]
        let lineNumber = beforeMatch.components(separatedBy: "\n").count

        // Perform replacement
        let newContent = content.replacingOccurrences(of: oldString, with: newString)

        // Write back
        do {
            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        } catch {
            return CommandExecutionResult(
                output: "Error: Could not write file: \(error.localizedDescription)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        let oldLineCount = oldString.components(separatedBy: "\n").count
        let newLineCount = newString.components(separatedBy: "\n").count

        return CommandExecutionResult(
            output: "Successfully edited \(path): replaced \(oldLineCount) line(s) with \(newLineCount) line(s) at line \(lineNumber)",
            exitCode: 0,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - list_files

    /// List files and directories at a path
    ///
    /// When `sandboxRoot` is provided, access is strictly constrained to that
    /// directory (after symlink resolution) — see `readFile` for rationale.
    static func listFiles(
        path: String,
        workingDirectory: String,
        sandboxRoot: String? = nil
    ) -> CommandExecutionResult {
        let startTime = Date()

        let resolvedPath: String
        if let sandboxRoot {
            guard let sandboxed = resolvePathInSandbox(path, sandboxRoot: sandboxRoot) else {
                logger.error("list_files DENIED (outside sandbox): path=\(path, privacy: .public) sandboxRoot=\(sandboxRoot, privacy: .public)")
                return CommandExecutionResult(
                    output: "Error: Access denied. Path is outside the repository: \(path)",
                    exitCode: 1,
                    duration: Date().timeIntervalSince(startTime)
                )
            }
            resolvedPath = sandboxed
        } else {
            resolvedPath = resolvePath(path, workingDirectory: workingDirectory)
            guard isPathAllowed(resolvedPath) else {
                logger.error("list_files DENIED (outside allowed dirs): path=\(path, privacy: .public) resolved=\(resolvedPath, privacy: .public)")
                return CommandExecutionResult(
                    output: "Error: Access denied. Path is outside the allowed directories: \(path)",
                    exitCode: 1,
                    duration: Date().timeIntervalSince(startTime)
                )
            }
        }

        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return CommandExecutionResult(
                output: "Error: Not a directory: \(path)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: resolvedPath)
            let listing = contents.sorted().map { name -> String in
                var isDir: ObjCBool = false
                let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
                if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    return name + "/"
                }
                return name
            }
            return CommandExecutionResult(
                output: listing.joined(separator: "\n"),
                exitCode: 0,
                duration: Date().timeIntervalSince(startTime)
            )
        } catch {
            return CommandExecutionResult(
                output: "Error: \(error.localizedDescription)",
                exitCode: 1,
                duration: Date().timeIntervalSince(startTime)
            )
        }
    }

    // MARK: - Path Helpers

    /// Resolve a potentially relative path against the working directory
    static func resolvePath(_ path: String, workingDirectory: String) -> String {
        if path.hasPrefix("/") {
            return path
        }
        if path.hasPrefix("~/") {
            let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
            return home + String(path.dropFirst(1))
        }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    /// Canonicalize a path for sandbox comparison: collapse `.`/`..`, then
    /// resolve symlinks when the path exists on disk. For non-existent paths
    /// `resolvingSymlinksInPath()` is a best-effort no-op, which is acceptable
    /// because each tool handler checks existence independently.
    static func canonicalizePath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
    }

    /// Resolve `path` strictly within `sandboxRoot`. Returns nil if the
    /// resolved path escapes the sandbox (after symlink resolution) or uses a
    /// disallowed form such as `~/`, which would otherwise expand to Documents
    /// and is meaningless in a repo-scoped context.
    static func resolvePathInSandbox(_ path: String, sandboxRoot: String) -> String? {
        if path.hasPrefix("~") { return nil }

        let joined: String
        if path.hasPrefix("/") {
            joined = path
        } else {
            joined = (sandboxRoot as NSString).appendingPathComponent(path)
        }

        let resolved = canonicalizePath(joined)
        let rootCanonical = canonicalizePath(sandboxRoot)

        // Strict prefix check with a trailing separator so a sibling like
        // "/repoEVIL" cannot match "/repo" as a prefix.
        let rootWithSlash = rootCanonical.hasSuffix("/") ? rootCanonical : rootCanonical + "/"
        if resolved == rootCanonical { return resolved }
        if resolved.hasPrefix(rootWithSlash) { return resolved }
        return nil
    }

    /// Check whether a resolved path is within the allowed sandbox
    static func isPathAllowed(_ resolvedPath: String) -> Bool {
        // Resolve symlinks on the Documents URL (which always exists) to get the
        // canonical prefix.  On iOS /var → /private/var, so the Documents URL from
        // FileManager may use either form depending on API.  Resolving symlinks on
        // the URL gives us the canonical /private/var/… form.
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath()
        let documentsCanonical = documentsURL.path

        // For the input path we can't call resolvingSymlinksInPath() because the
        // file may not exist yet (write_file creating a new file).  Instead,
        // collapse "." and ".." with standardizingPath, then check both the raw
        // and /private-prefixed forms against the canonical documents path.
        let collapsed = (resolvedPath as NSString).standardizingPath

        if collapsed.hasPrefix(documentsCanonical) { return true }

        // Also try adding /private prefix if the collapsed path starts with /var
        // (or stripping it if canonical doesn't have it)
        if collapsed.hasPrefix("/var/") {
            let withPrivate = "/private" + collapsed
            if withPrivate.hasPrefix(documentsCanonical) { return true }
        }
        if collapsed.hasPrefix("/private/var/") {
            let withoutPrivate = String(collapsed.dropFirst("/private".count))
            if withoutPrivate.hasPrefix(documentsCanonical) { return true }
        }

        #if !targetEnvironment(macCatalyst)
        // Check bookmarked locations (iOS only)
        for location in BookmarkedLocationsManager.shared.locations {
            if let url = location.resolvedURL {
                let locationCanonical = url.resolvingSymlinksInPath().path
                if collapsed.hasPrefix(locationCanonical) { return true }
                if collapsed.hasPrefix("/var/") {
                    if ("/private" + collapsed).hasPrefix(locationCanonical) { return true }
                }
            }
        }
        #endif

        #if targetEnvironment(macCatalyst)
        let homeDir = NSHomeDirectory()
        if collapsed.hasPrefix(homeDir) { return true }
        #endif

        return false
    }

    /// Detect binary files by scanning for null bytes in the first 8KB
    private static func isBinaryFile(_ path: String) -> Bool {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return false }
        defer { fileHandle.closeFile() }

        let data = fileHandle.readData(ofLength: 8192)
        return data.contains(0x00)
    }
}

// MARK: - String Helpers

private extension String {
    func leftPadded(toLength length: Int, withPad pad: Character = " ") -> String {
        if self.count >= length { return self }
        return String(repeating: pad, count: length - self.count) + self
    }
}
#endif
