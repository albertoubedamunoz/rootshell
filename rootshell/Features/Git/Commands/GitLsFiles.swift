#if !targetEnvironment(macCatalyst)

import Foundation

/// `git ls-files [--cached] [--deleted] [--modified] [--others] [--error-unmatch] [<pathspec>...]`
enum GitLsFiles: GitSubcommand {
    static var helpText: String {
        "usage: git ls-files [<options>] [<file>...]\r\n\r\n    Show information about files in the index and working tree\r\n\r\nOptions:\r\n    -c, --cached         Show cached files (default)\r\n    -d, --deleted        Show deleted files\r\n    -m, --modified       Show modified files\r\n    -o, --others         Show untracked files\r\n    --error-unmatch      Error if any <file> does not appear in the index\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var showCached = false
        var showDeleted = false
        var showModified = false
        var showOthers = false
        var errorUnmatch = false
        var pathspecs: [String] = []

        for arg in args {
            switch arg {
            case "--cached", "-c": showCached = true
            case "--deleted", "-d": showDeleted = true
            case "--modified", "-m": showModified = true
            case "--others", "-o": showOthers = true
            case "--error-unmatch": errorUnmatch = true
            default:
                if !arg.hasPrefix("-") {
                    pathspecs.append(arg)
                }
            }
        }

        // Default to --cached if no mode specified
        if !showCached && !showDeleted && !showModified && !showOthers {
            showCached = true
        }

        var out = GitOutput(write: output)
        var matchedPathspecs = Set<String>()

        // --cached: list tracked files from the index
        if showCached {
            try listCached(repo: repo, pathspecs: pathspecs, matchedPathspecs: &matchedPathspecs, output: &out)
        }

        // --deleted, --modified, --others: use status list
        if showDeleted || showModified || showOthers {
            try listStatus(repo: repo, showDeleted: showDeleted, showModified: showModified,
                          showOthers: showOthers, pathspecs: pathspecs,
                          matchedPathspecs: &matchedPathspecs, output: &out)
        }

        out.flush()

        // Check error-unmatch
        if errorUnmatch && !pathspecs.isEmpty {
            for spec in pathspecs {
                if !matchedPathspecs.contains(spec) {
                    output(GitStyle.fg(GitStyle.errorColor, "error: pathspec '\(spec)' did not match any file(s) known to git\r\n"))
                    return 1
                }
            }
        }

        return 0
    }

    // MARK: - Cached files (from index)

    private static func listCached(repo: OpaquePointer, pathspecs: [String],
                                   matchedPathspecs: inout Set<String>,
                                   output: inout GitOutput) throws {
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return }
        defer { git_index_free(index) }

        let entryCount = git_index_entrycount(index)

        for i in 0..<entryCount {
            guard let entry = git_index_get_byindex(index, i) else { continue }
            let path = String(cString: entry.pointee.path)

            if !pathspecs.isEmpty {
                let matched = pathspecs.contains { spec in
                    pathMatchesSpec(path: path, spec: spec)
                }
                if !matched { continue }
                for spec in pathspecs where pathMatchesSpec(path: path, spec: spec) {
                    matchedPathspecs.insert(spec)
                }
            }

            output.line(path)
        }
    }

    // MARK: - Status-based listing

    private static func listStatus(repo: OpaquePointer, showDeleted: Bool,
                                   showModified: Bool, showOthers: Bool,
                                   pathspecs: [String],
                                   matchedPathspecs: inout Set<String>,
                                   output: inout GitOutput) throws {
        let opts = UnsafeMutablePointer<git_status_options>.allocate(capacity: 1)
        defer { opts.deallocate() }
        git_status_options_init(opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.pointee.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR

        var flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue |
                    GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue |
                    GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue
        if !showOthers {
            flags &= ~GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
        }
        opts.pointee.flags = flags

        var statusList: OpaquePointer?
        try lg2Check(git_status_list_new(&statusList, repo, opts), "failed to get status")
        guard let statusList else { return }
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let status = entry.pointee.status

            // Deleted files
            if showDeleted && (status.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0) {
                let path = diffDeltaOldPath(entry.pointee.index_to_workdir)
                if matchesPathspecs(path: path, pathspecs: pathspecs, matched: &matchedPathspecs) {
                    output.line(path)
                }
            }

            // Modified files
            if showModified && (status.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0) {
                let path = diffDeltaNewPath(entry.pointee.index_to_workdir)
                if matchesPathspecs(path: path, pathspecs: pathspecs, matched: &matchedPathspecs) {
                    output.line(path)
                }
            }

            // Untracked (others)
            if showOthers && (status.rawValue & GIT_STATUS_WT_NEW.rawValue != 0) {
                let path = diffDeltaNewPath(entry.pointee.index_to_workdir)
                if matchesPathspecs(path: path, pathspecs: pathspecs, matched: &matchedPathspecs) {
                    output.line(path)
                }
            }
        }
    }

    // MARK: - Pathspec matching

    private static func matchesPathspecs(path: String, pathspecs: [String],
                                         matched: inout Set<String>) -> Bool {
        if pathspecs.isEmpty { return true }

        for spec in pathspecs {
            if pathMatchesSpec(path: path, spec: spec) {
                matched.insert(spec)
                return true
            }
        }
        return false
    }

    private static func pathMatchesSpec(path: String, spec: String) -> Bool {
        // Exact match
        if path == spec { return true }
        // Directory prefix
        if path.hasPrefix(spec + "/") { return true }
        // File name match
        if (path as NSString).lastPathComponent == spec { return true }
        return false
    }
}

#endif
