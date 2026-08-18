#if !targetEnvironment(macCatalyst)

import Foundation

/// `git blame <file>` — show file blame with colored annotations.
enum GitBlame: GitSubcommand {
    static var helpText: String {
        "usage: git blame [<options>] <file>\r\n\r\n    Show what revision and author last modified each line of a file\r\n\r\nOptions:\r\n    -C                   Detect lines moved or copied from other files\r\n    -M                   Detect moved or copied lines within a file\r\n    -L <start>,<end>     Restrict blame to line range\r\n    -w                   Ignore whitespace when comparing\r\n    --date=<format>      Date format: relative, iso, short (default)\r\n    <commit>             Blame from specific commit\r\n"
    }

    /// Cycling author colors for visual distinction.
    private static let authorColors: [GitStyle.Color] = [
        GitStyle.Color(r: 100, g: 200, b: 200),   // cyan
        GitStyle.Color(r: 200, g: 150, b: 255),   // purple
        GitStyle.Color(r: 255, g: 180, b: 100),   // orange
        GitStyle.Color(r: 100, g: 220, b: 140),   // green
        GitStyle.Color(r: 255, g: 130, b: 130),   // red
        GitStyle.Color(r: 130, g: 170, b: 255),   // blue
        GitStyle.Color(r: 220, g: 220, b: 100),   // yellow
        GitStyle.Color(r: 200, g: 140, b: 180),   // pink
    ]

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse args
        var filePath: String?
        var detectCopies = false
        var detectMoves = false
        var startLine: UInt32 = 0
        var endLine: UInt32 = 0
        var ignoreWhitespace = false
        var dateFormat = "short" // short, relative, iso
        var commitRef: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-C": detectCopies = true
            case "-M": detectMoves = true
            case "-w": ignoreWhitespace = true
            case "-L":
                if i + 1 < args.count {
                    let range = args[i + 1]
                    let parts = range.components(separatedBy: ",")
                    if parts.count == 2 {
                        startLine = UInt32(parts[0]) ?? 0
                        endLine = UInt32(parts[1]) ?? 0
                    }
                    i += 1
                }
            default:
                if args[i].hasPrefix("-L") {
                    let range = String(args[i].dropFirst(2))
                    let parts = range.components(separatedBy: ",")
                    if parts.count == 2 {
                        startLine = UInt32(parts[0]) ?? 0
                        endLine = UInt32(parts[1]) ?? 0
                    }
                } else if args[i].hasPrefix("--date=") {
                    dateFormat = String(args[i].dropFirst(7))
                } else if !args[i].hasPrefix("-") {
                    if filePath == nil {
                        // Could be a commit ref or file path — if it looks like a file, use it
                        // Try as file first
                        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
                        if FileManager.default.fileExists(atPath: workdir + args[i]) {
                            filePath = args[i]
                        } else if commitRef == nil {
                            commitRef = args[i]
                        } else {
                            filePath = args[i]
                        }
                    } else {
                        // Second positional — must be commit if first was file
                        if commitRef == nil {
                            // Swap: first was file, second is also positional
                            // In git blame, it's `git blame <commit> -- <file>` or `git blame <file>`
                            commitRef = args[i]
                        }
                    }
                }
            }
            i += 1
        }

        guard let filePath else {
            output("usage: git blame [-L <start>,<end>] [-w] [<commit>] <file>\r\n")
            return 1
        }

        // Set up blame options
        var blameOpts = git_blame_options()
        git_blame_options_init(&blameOpts, UInt32(GIT_BLAME_OPTIONS_VERSION))

        var flags = blameOpts.flags
        if detectCopies {
            flags |= GIT_BLAME_TRACK_COPIES_SAME_FILE.rawValue
        }
        if detectMoves {
            flags |= GIT_BLAME_TRACK_COPIES_SAME_COMMIT_MOVES.rawValue
        }
        if ignoreWhitespace {
            flags |= GIT_BLAME_IGNORE_WHITESPACE.rawValue
        }
        blameOpts.flags = flags

        if startLine > 0 {
            blameOpts.min_line = Int(startLine)
        }
        if endLine > 0 {
            blameOpts.max_line = Int(endLine)
        }

        // Set newest_commit for blaming from a specific commit
        if let commitRef {
            var obj: OpaquePointer?
            try lg2Check(git_revparse_single(&obj, repo, commitRef), "unknown revision '\(commitRef)'")
            guard let obj else { return 1 }
            defer { git_object_free(obj) }
            if let oid = git_object_id(obj) {
                blameOpts.newest_commit = oid.pointee
            }
        }

        // Run blame
        var blame: OpaquePointer?
        try lg2Check(git_blame_file(&blame, repo, filePath, &blameOpts), "failed to blame '\(filePath)'")
        guard let blame else { return 1 }
        defer { git_blame_free(blame) }

        // Read the file to get line contents
        let fileContents: String
        if let commitRef {
            // Historical blame — read file from the blob at that commit
            var obj: OpaquePointer?
            if git_revparse_single(&obj, repo, commitRef) == 0, let obj {
                defer { git_object_free(obj) }
                var commitObj: OpaquePointer?
                if git_commit_lookup(&commitObj, repo, git_object_id(obj)) == 0, let commitObj {
                    defer { git_commit_free(commitObj) }
                    var tree: OpaquePointer?
                    if git_commit_tree(&tree, commitObj) == 0, let tree {
                        defer { git_tree_free(tree) }
                        var entry: OpaquePointer?
                        if git_tree_entry_bypath(&entry, tree, filePath) == 0, let entry {
                            defer { git_tree_entry_free(entry) }
                            var blob: OpaquePointer?
                            if git_blob_lookup(&blob, repo, git_tree_entry_id(entry)) == 0, let blob {
                                defer { git_blob_free(blob) }
                                let size = git_blob_rawsize(blob)
                                if let rawContent = git_blob_rawcontent(blob) {
                                    let data = Data(bytes: rawContent, count: Int(size))
                                    fileContents = String(data: data, encoding: .utf8) ?? ""
                                } else {
                                    fileContents = ""
                                }
                            } else {
                                output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot read file '\(filePath)' at \(commitRef)\r\n"))
                                return 1
                            }
                        } else {
                            output(GitStyle.fg(GitStyle.errorColor, "fatal: no such path '\(filePath)' in '\(commitRef)'\r\n"))
                            return 1
                        }
                    } else {
                        output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot read tree for '\(commitRef)'\r\n"))
                        return 1
                    }
                } else {
                    output(GitStyle.fg(GitStyle.errorColor, "fatal: not a commit: '\(commitRef)'\r\n"))
                    return 1
                }
            } else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: unknown revision '\(commitRef)'\r\n"))
                return 1
            }
        } else {
            // Working tree blame — read from disk
            let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
            let fullPath = workdir + filePath
            guard let fileData = FileManager.default.contents(atPath: fullPath),
                  let contents = String(data: fileData, encoding: .utf8) else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot read file '\(filePath)'\r\n"))
                return 1
            }
            fileContents = contents
        }

        let lines = fileContents.components(separatedBy: "\n")

        var out = GitOutput(write: output)

        // Track author -> color mapping
        var authorColorMap: [String: GitStyle.Color] = [:]
        var nextColorIndex = 0

        // Determine line range to display
        let displayStart = startLine > 0 ? Int(startLine) : 1
        let displayEnd = endLine > 0 ? min(Int(endLine), lines.count) : lines.count

        // Calculate max line number width for alignment
        let lineNumWidth = String(displayEnd).count

        for lineIndex in (displayStart - 1)..<displayEnd {
            let lineNum = lineIndex + 1

            guard let hunk = git_blame_get_hunk_byline(blame, lineNum) else {
                // No blame info for this line
                let paddedNum = String(lineNum).leftPadded(to: lineNumWidth)
                out.line("\(GitStyle.fg(GitStyle.dimColor, "???????? ("))\(GitStyle.fg(GitStyle.dimColor, paddedNum)) \(GitStyle.fg(GitStyle.dimColor, "|")) \(lineIndex < lines.count ? lines[lineIndex] : "")")
                continue
            }

            var oid = hunk.pointee.final_commit_id
            let shortHash = oidShortString(&oid)

            let authorName = hunk.pointee.final_signature.pointee.name.map { String(cString: $0) } ?? "unknown"
            let time = hunk.pointee.final_signature.pointee.when.time
            let dateStr = formatBlameDate(from: time, format: dateFormat)

            // Assign cycling color to author
            let authorColor: GitStyle.Color
            if let existing = authorColorMap[authorName] {
                authorColor = existing
            } else {
                authorColor = authorColors[nextColorIndex % authorColors.count]
                authorColorMap[authorName] = authorColor
                nextColorIndex += 1
            }

            let paddedNum = String(lineNum).leftPadded(to: lineNumWidth)
            let truncatedAuthor = String(authorName.prefix(16)).padding(toLength: 16, withPad: " ", startingAt: 0)

            let lineContent = lineIndex < lines.count ? lines[lineIndex] : ""

            out.raw(GitStyle.fg(GitStyle.hash, shortHash))
            out.raw(" (")
            out.raw(GitStyle.fg(authorColor, truncatedAuthor))
            out.raw(" ")
            out.raw(GitStyle.fg(GitStyle.dateColor, dateStr))
            out.raw(" ")
            out.raw(GitStyle.fg(GitStyle.dimColor, paddedNum))
            out.raw(GitStyle.fg(GitStyle.dimColor, " | "))
            out.raw(lineContent)
            out.line()
        }

        out.flush()
        return 0
    }

    private static func formatBlameDate(from epochTime: git_time_t, format: String) -> String {
        switch format {
        case "relative":
            return GitLog.relativeTime(from: epochTime)
        case "iso":
            let date = Date(timeIntervalSince1970: TimeInterval(epochTime))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            return formatter.string(from: date)
        default: // "short"
            let date = Date(timeIntervalSince1970: TimeInterval(epochTime))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
    }
}

// MARK: - String padding helper

private extension String {
    func leftPadded(to width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}

#endif
