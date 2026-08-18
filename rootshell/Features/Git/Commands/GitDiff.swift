#if !targetEnvironment(macCatalyst)

import Foundation

/// `git diff` — shows changes with syntax-colored hunks.
enum GitDiff: GitSubcommand {
    static var helpText: String {
        "usage: git diff [<options>] [<commit>..<commit>] [-- <path>...]\r\n       git diff --cached [<path>...]\r\n\r\n    Show changes between the index and the working tree\r\n\r\nOptions:\r\n    --cached, --staged     Show changes staged for commit\r\n    --stat                 Show diffstat instead of full diff\r\n    --name-only            Show only names of changed files\r\n    --name-status          Show names and status of changed files\r\n    -w, --ignore-all-space Ignore all whitespace\r\n    -b, --ignore-space-change  Ignore changes in amount of whitespace\r\n    -U<n>, --unified=<n>   Number of context lines (default 3)\r\n    --diff-filter=<filter> Filter by type (A/D/M/R)\r\n    <commit>               Diff commit against working tree\r\n    <commit>..<commit>     Diff between two commits\r\n"
    }

    // MARK: - Options

    private struct DiffOptions {
        var cached = false
        var stat = false
        var nameOnly = false
        var nameStatus = false
        var ignoreAllSpace = false
        var ignoreSpaceChange = false
        var contextLines: UInt32 = 3
        var contextLinesSet = false
        var diffFilter: String?
        var positionals: [String] = []
        var paths: [String] = []
        var commit1: String?
        var commit2: String?
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var opts = parseOptions(args: args)

        // Resolve positionals: try as revision first, fall back to path
        if opts.commit1 == nil && opts.commit2 == nil {
            for positional in opts.positionals {
                var obj: OpaquePointer?
                if opts.commit1 == nil && git_revparse_single(&obj, repo, positional) == 0, let obj {
                    git_object_free(obj)
                    opts.commit1 = positional
                } else {
                    opts.paths.append(positional)
                }
            }
        } else {
            opts.paths.append(contentsOf: opts.positionals)
        }

        var diff: OpaquePointer?

        // Build diff options when needed
        var diffOpts = git_diff_options()
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var ptrs: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var oldPfx: UnsafeMutablePointer<CChar>?
        var newPfx: UnsafeMutablePointer<CChar>?

        let needsOpts = !opts.paths.isEmpty || opts.ignoreAllSpace || opts.ignoreSpaceChange || opts.contextLinesSet

        if needsOpts {
            git_diff_options_init(&diffOpts, UInt32(GIT_DIFF_OPTIONS_VERSION))

            oldPfx = strdup("a")
            newPfx = strdup("b")
            diffOpts.old_prefix = UnsafePointer(oldPfx)
            diffOpts.new_prefix = UnsafePointer(newPfx)

            if opts.ignoreAllSpace {
                diffOpts.flags |= GIT_DIFF_IGNORE_WHITESPACE.rawValue
            }
            if opts.ignoreSpaceChange {
                diffOpts.flags |= GIT_DIFF_IGNORE_WHITESPACE_CHANGE.rawValue
            }
            if opts.contextLinesSet {
                diffOpts.context_lines = opts.contextLines
            }

            if !opts.paths.isEmpty {
                cStrings = opts.paths.map { strdup($0)! }
                ptrs = .allocate(capacity: opts.paths.count)
                for (i, cs) in cStrings.enumerated() {
                    ptrs![i] = cs
                }
                diffOpts.pathspec.strings = ptrs
                diffOpts.pathspec.count = opts.paths.count
            }
        }
        defer {
            free(oldPfx); free(newPfx)
            cStrings.forEach { free($0) }
            ptrs?.deallocate()
        }

        // Determine diff mode
        if let c1 = opts.commit1, let c2 = opts.commit2 {
            // commit..commit
            if needsOpts {
                diff = try diffBetweenCommits(repo: repo, ref1: c1, ref2: c2, opts: &diffOpts)
            } else {
                diff = try diffBetweenCommits(repo: repo, ref1: c1, ref2: c2, opts: nil)
            }
        } else if let c1 = opts.commit1 {
            // commit vs working tree
            if needsOpts {
                diff = try diffCommitToWorkdir(repo: repo, ref: c1, opts: &diffOpts)
            } else {
                diff = try diffCommitToWorkdir(repo: repo, ref: c1, opts: nil)
            }
        } else if opts.cached {
            if needsOpts {
                diff = try diffCached(repo: repo, opts: &diffOpts)
            } else {
                diff = try diffCached(repo: repo, opts: nil)
            }
        } else {
            // index vs workdir
            if needsOpts {
                try lg2Check(git_diff_index_to_workdir(&diff, repo, nil, &diffOpts), "failed to get diff")
            } else {
                try lg2Check(git_diff_index_to_workdir(&diff, repo, nil, nil), "failed to get diff")
            }
        }

        guard let diff else {
            output("No changes\r\n")
            return 0
        }
        defer { git_diff_free(diff) }

        if opts.nameOnly {
            return printNameOnly(diff: diff, filter: opts.diffFilter, output: output)
        }
        if opts.nameStatus {
            return printNameStatus(diff: diff, filter: opts.diffFilter, output: output)
        }
        if opts.stat {
            return try printDiffStat(diff: diff, filter: opts.diffFilter, output: output)
        }

        return try printDiffFull(diff: diff, filter: opts.diffFilter, output: output)
    }

    // MARK: - Option parsing

    private static func parseOptions(args: [String]) -> DiffOptions {
        var opts = DiffOptions()
        var afterDashDash = false

        for arg in args {
            if afterDashDash {
                opts.paths.append(arg)
                continue
            }

            switch arg {
            case "--": afterDashDash = true
            case "--cached", "--staged": opts.cached = true
            case "--stat": opts.stat = true
            case "--name-only": opts.nameOnly = true
            case "--name-status": opts.nameStatus = true
            case "-w", "--ignore-all-space": opts.ignoreAllSpace = true
            case "-b", "--ignore-space-change": opts.ignoreSpaceChange = true
            default:
                if arg.hasPrefix("-U"), let n = UInt32(String(arg.dropFirst(2))) {
                    opts.contextLines = n
                    opts.contextLinesSet = true
                } else if arg.hasPrefix("--unified="), let n = UInt32(String(arg.dropFirst(10))) {
                    opts.contextLines = n
                    opts.contextLinesSet = true
                } else if arg.hasPrefix("--diff-filter=") {
                    opts.diffFilter = String(arg.dropFirst(14))
                } else if !arg.hasPrefix("-") {
                    // Check for commit..commit syntax
                    if arg.contains("..") {
                        let parts = arg.components(separatedBy: "..")
                        if parts.count == 2 {
                            opts.commit1 = parts[0]
                            opts.commit2 = parts[1]
                        }
                    } else {
                        opts.positionals.append(arg)
                    }
                }
            }
        }

        return opts
    }

    // MARK: - Diff between two commits

    private static func diffBetweenCommits(repo: OpaquePointer, ref1: String, ref2: String, opts: UnsafeMutablePointer<git_diff_options>?) throws -> OpaquePointer? {
        var obj1: OpaquePointer?
        try lg2Check(git_revparse_single(&obj1, repo, ref1), "unknown revision '\(ref1)'")
        guard let obj1 else { return nil }
        defer { git_object_free(obj1) }

        var obj2: OpaquePointer?
        try lg2Check(git_revparse_single(&obj2, repo, ref2), "unknown revision '\(ref2)'")
        guard let obj2 else { return nil }
        defer { git_object_free(obj2) }

        var tree1: OpaquePointer?
        var tree2: OpaquePointer?

        var commit1: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit1, repo, git_object_id(obj1)), "not a commit")
        guard let commit1 else { return nil }
        defer { git_commit_free(commit1) }
        try lg2Check(git_commit_tree(&tree1, commit1), "failed to get tree")
        defer { if let tree1 { git_tree_free(tree1) } }

        var commit2: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit2, repo, git_object_id(obj2)), "not a commit")
        guard let commit2 else { return nil }
        defer { git_commit_free(commit2) }
        try lg2Check(git_commit_tree(&tree2, commit2), "failed to get tree")
        defer { if let tree2 { git_tree_free(tree2) } }

        var diff: OpaquePointer?
        try lg2Check(git_diff_tree_to_tree(&diff, repo, tree1, tree2, opts), "failed to diff trees")
        return diff
    }

    // MARK: - Diff commit to workdir

    private static func diffCommitToWorkdir(repo: OpaquePointer, ref: String, opts: UnsafeMutablePointer<git_diff_options>?) throws -> OpaquePointer? {
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, ref), "unknown revision '\(ref)'")
        guard let obj else { return nil }
        defer { git_object_free(obj) }

        var commit: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit, repo, git_object_id(obj)), "not a commit")
        guard let commit else { return nil }
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        try lg2Check(git_commit_tree(&tree, commit), "failed to get tree")
        guard let tree else { return nil }
        defer { git_tree_free(tree) }

        // Tree to index
        var diff1: OpaquePointer?
        try lg2Check(git_diff_tree_to_index(&diff1, repo, tree, nil, opts), "failed to diff tree to index")

        // Index to workdir
        var diff2: OpaquePointer?
        try lg2Check(git_diff_index_to_workdir(&diff2, repo, nil, opts), "failed to diff index to workdir")

        // Merge diffs
        if let diff1, let diff2 {
            git_diff_merge(diff1, diff2)
            git_diff_free(diff2)
            return diff1
        }

        return diff1 ?? diff2
    }

    // MARK: - Cached diff

    private static func diffCached(repo: OpaquePointer, opts: UnsafeMutablePointer<git_diff_options>?) throws -> OpaquePointer? {
        var tree: OpaquePointer?
        var head: OpaquePointer?
        let headErr = git_repository_head(&head, repo)
        if headErr == 0, let head {
            defer { git_reference_free(head) }
            var commitObj: OpaquePointer?
            try lg2Check(git_reference_peel(&commitObj, head, GIT_OBJECT_COMMIT), "failed to peel HEAD to commit")
            if let commitObj {
                defer { git_object_free(commitObj) }
                try lg2Check(git_commit_tree(&tree, commitObj), "failed to get commit tree")
            }
        } else if headErr != GIT_EUNBORNBRANCH.rawValue && headErr != GIT_ENOTFOUND.rawValue {
            try lg2Check(headErr, "failed to resolve HEAD")
        }
        defer { if let tree { git_tree_free(tree) } }

        var diff: OpaquePointer?
        try lg2Check(git_diff_tree_to_index(&diff, repo, tree, nil, opts), "failed to get cached diff")
        return diff
    }

    // MARK: - Diff filter

    private static func deltaMatchesFilter(_ delta: UnsafePointer<git_diff_delta>, filter: String) -> Bool {
        let status = delta.pointee.status
        switch status {
        case GIT_DELTA_ADDED: return filter.contains("A") || filter.contains("a")
        case GIT_DELTA_DELETED: return filter.contains("D") || filter.contains("d")
        case GIT_DELTA_MODIFIED: return filter.contains("M") || filter.contains("m")
        case GIT_DELTA_RENAMED: return filter.contains("R") || filter.contains("r")
        case GIT_DELTA_COPIED: return filter.contains("C") || filter.contains("c")
        case GIT_DELTA_TYPECHANGE: return filter.contains("T") || filter.contains("t")
        default: return true
        }
    }

    // MARK: - Name-only output

    private static func printNameOnly(diff: OpaquePointer, filter: String?, output: @escaping @Sendable (String) -> Void) -> Int32 {
        var out = GitOutput(write: output)
        let count = git_diff_num_deltas(diff)

        for i in 0..<count {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            if let filter, !deltaMatchesFilter(delta, filter: filter) { continue }
            if let path = delta.pointee.new_file.path {
                out.line(String(cString: path))
            }
        }

        out.flush()
        return 0
    }

    // MARK: - Name-status output

    private static func printNameStatus(diff: OpaquePointer, filter: String?, output: @escaping @Sendable (String) -> Void) -> Int32 {
        var out = GitOutput(write: output)
        let count = git_diff_num_deltas(diff)

        for i in 0..<count {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            if let filter, !deltaMatchesFilter(delta, filter: filter) { continue }
            let status = delta.pointee.status

            let statusChar: String
            let color: GitStyle.Color
            switch status {
            case GIT_DELTA_ADDED:
                statusChar = "A"; color = GitStyle.added
            case GIT_DELTA_DELETED:
                statusChar = "D"; color = GitStyle.deleted
            case GIT_DELTA_MODIFIED:
                statusChar = "M"; color = GitStyle.modified
            case GIT_DELTA_RENAMED:
                statusChar = "R"; color = GitStyle.renamed
            case GIT_DELTA_COPIED:
                statusChar = "C"; color = GitStyle.info
            default:
                statusChar = "?"; color = GitStyle.dimColor
            }

            out.raw(GitStyle.fg(color, statusChar))
            out.raw("\t")
            if (status == GIT_DELTA_RENAMED || status == GIT_DELTA_COPIED),
               let oldPath = delta.pointee.old_file.path,
               let newPath = delta.pointee.new_file.path {
                out.line("\(String(cString: oldPath)) -> \(String(cString: newPath))")
            } else if let path = delta.pointee.new_file.path {
                out.line(String(cString: path))
            }
        }

        out.flush()
        return 0
    }

    // MARK: - Full diff output

    private static func printDiffFull(diff: OpaquePointer, filter: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let out = GitOutput(write: output)

        let numDeltas = git_diff_num_deltas(diff)
        guard numDeltas > 0 else {
            return 0
        }

        // Use git_diff_print for proper formatting
        struct CallbackContext {
            var output: GitOutput
            var filterA: Bool  // allow Added
            var filterD: Bool  // allow Deleted
            var filterM: Bool  // allow Modified
            var filterR: Bool  // allow Renamed
            var filterC: Bool  // allow Copied
            var filterT: Bool  // allow Typechange
            var hasFilter: Bool
        }

        var ctx = CallbackContext(
            output: out,
            filterA: filter?.contains(where: { $0 == "A" || $0 == "a" }) ?? true,
            filterD: filter?.contains(where: { $0 == "D" || $0 == "d" }) ?? true,
            filterM: filter?.contains(where: { $0 == "M" || $0 == "m" }) ?? true,
            filterR: filter?.contains(where: { $0 == "R" || $0 == "r" }) ?? true,
            filterC: filter?.contains(where: { $0 == "C" || $0 == "c" }) ?? true,
            filterT: filter?.contains(where: { $0 == "T" || $0 == "t" }) ?? true,
            hasFilter: filter != nil
        )

        let printCb: git_diff_line_cb = { delta, hunk, line, payload in
            guard let payload else { return 0 }
            let ctx = payload.assumingMemoryBound(to: CallbackContext.self)

            guard let line else { return 0 }

            // Apply diff filter
            if ctx.pointee.hasFilter, let delta {
                let status = delta.pointee.status
                let allowed: Bool
                switch status {
                case GIT_DELTA_ADDED: allowed = ctx.pointee.filterA
                case GIT_DELTA_DELETED: allowed = ctx.pointee.filterD
                case GIT_DELTA_MODIFIED: allowed = ctx.pointee.filterM
                case GIT_DELTA_RENAMED: allowed = ctx.pointee.filterR
                case GIT_DELTA_COPIED: allowed = ctx.pointee.filterC
                case GIT_DELTA_TYPECHANGE: allowed = ctx.pointee.filterT
                default: allowed = true
                }
                if !allowed { return 0 }
            }

            let content: String
            if let contentPtr = line.pointee.content {
                // bytesNoCopy is deprecated on iOS 16+; the copy is bounded by one
                // diff line and keeps the old nil-on-invalid-UTF-8 behavior.
                content = String(
                    data: Data(bytes: contentPtr, count: line.pointee.content_len),
                    encoding: .utf8
                ) ?? ""
            } else {
                content = ""
            }

            let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content

            switch line.pointee.origin {
            case "+".utf8.first.map(CChar.init)!:
                ctx.pointee.output.line(GitStyle.fg(GitStyle.added, "+\(trimmed)"))
            case "-".utf8.first.map(CChar.init)!:
                ctx.pointee.output.line(GitStyle.fg(GitStyle.deleted, "-\(trimmed)"))
            case "F".utf8.first.map(CChar.init)!:
                // File header
                ctx.pointee.output.line(GitStyle.boldFg(GitStyle.headerColor, trimmed))
            case "H".utf8.first.map(CChar.init)!:
                // Hunk header
                ctx.pointee.output.line(GitStyle.fg(GitStyle.info, trimmed))
            default:
                ctx.pointee.output.line(" \(trimmed)")
            }

            return 0
        }
        // withUnsafeMutablePointer rather than `&ctx`: CallbackContext holds
        // heap references, and the implicit inout-to-raw-pointer conversion is
        // only valid for trivial types.
        withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            _ = git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, printCb, ctxPtr)
        }

        ctx.output.flush()
        return 0
    }

    // MARK: - Stat output

    private static func printDiffStat(diff: OpaquePointer, filter: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        if let filter {
            // Manual stat with filter: iterate patches, skip non-matching deltas
            let count = git_diff_num_deltas(diff)
            var totalIns = 0
            var totalDel = 0
            var totalFiles = 0

            for i in 0..<count {
                guard let delta = git_diff_get_delta(diff, i) else { continue }
                if !deltaMatchesFilter(delta, filter: filter) { continue }

                var patch: OpaquePointer?
                guard git_patch_from_diff(&patch, diff, i) == 0, let patch else { continue }
                defer { git_patch_free(patch) }

                var adds: Int = 0
                var dels: Int = 0
                git_patch_line_stats(nil, &adds, &dels, patch)
                totalIns += adds
                totalDel += dels
                totalFiles += 1

                let path = delta.pointee.new_file.path.map { String(cString: $0) } ?? "?"
                let changes = adds + dels
                let addBar = String(repeating: "+", count: min(adds, 40))
                let delBar = String(repeating: "-", count: min(dels, 40))
                out.line(" \(path) | \(changes) \(GitStyle.fg(GitStyle.added, addBar))\(GitStyle.fg(GitStyle.deleted, delBar))")
            }

            if totalFiles > 0 {
                out.line(" \(totalFiles) file\(totalFiles == 1 ? "" : "s") changed, \(totalIns) insertion\(totalIns == 1 ? "" : "s")(+), \(totalDel) deletion\(totalDel == 1 ? "" : "s")(-)")
            }

            out.flush()
            return 0
        }

        var stats: OpaquePointer?
        try lg2Check(git_diff_get_stats(&stats, diff), "failed to get diff stats")
        defer { git_diff_stats_free(stats) }

        var buf = git_buf()
        let statsFormat = git_diff_stats_format_t(rawValue: GIT_DIFF_STATS_FULL.rawValue | GIT_DIFF_STATS_SHORT.rawValue)
        try lg2Check(
            git_diff_stats_to_buf(&buf, stats, statsFormat, 80),
            "failed to format diff stats"
        )
        defer { git_buf_dispose(&buf) }

        if let ptr = buf.ptr {
            let statStr = String(cString: ptr)
            let lines = statStr.components(separatedBy: "\n")
            for line in lines {
                if !line.isEmpty {
                    out.line(line)
                }
            }
        }

        out.flush()
        return 0
    }
}

#endif
