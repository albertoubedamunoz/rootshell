#if !targetEnvironment(macCatalyst)

import Foundation

/// `git log` — shows commit history with styled output.
enum GitLog: GitSubcommand {
    static var helpText: String {
        "usage: git log [<options>] [<revision-range>] [-- <path>...]\r\n\r\n    Show commit logs\r\n\r\nOptions:\r\n    --oneline              Show each commit on a single line\r\n    -n, --max-count <n>    Limit the number of commits to show\r\n    --author <pattern>     Limit commits to those by a matching author\r\n    --all                  Show all refs, not just HEAD\r\n    --graph                Draw ASCII commit graph\r\n    --since=<date>         Show commits after date\r\n    --until=<date>         Show commits before date\r\n    --grep=<pattern>       Filter by commit message\r\n    --no-merges            Skip merge commits\r\n    --first-parent         Follow only first parent\r\n    --format=<format>      Custom format (%H %h %an %ae %ad %s %b %d)\r\n    --pretty=<format>      Alias for --format\r\n    --stat                 Show diffstat per commit\r\n    -p, --patch            Show full diff per commit\r\n"
    }

    // MARK: - Options

    private struct LogOptions {
        var oneline = false
        var maxCount = 20
        var authorFilter: String?
        var all = false
        var graph = false
        var sinceDate: Date?
        var untilDate: Date?
        var grepPattern: String?
        var noMerges = false
        var firstParent = false
        var format: String?
        var showStat = false
        var showPatch = false
        var positionals: [String] = []
        var paths: [String] = []
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var opts = parseOptions(args: args)
        var out = GitOutput(write: output)

        // Start revision walk
        var walk: OpaquePointer?
        try lg2Check(git_revwalk_new(&walk, repo), "failed to create revwalk")
        defer { git_revwalk_free(walk) }

        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)

        if opts.firstParent {
            git_revwalk_simplify_first_parent(walk)
        }

        var pushedRevision = false

        if opts.all {
            git_revwalk_push_glob(walk, "*")
            pushedRevision = true
        }

        // Resolve positionals as revisions or paths
        for positional in opts.positionals {
            if positional.contains("..") {
                // Range syntax: A..B means hide A, push B
                let parts = positional.components(separatedBy: "..")
                if parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty {
                    var hideObj: OpaquePointer?
                    if git_revparse_single(&hideObj, repo, parts[0]) == 0, let hideObj {
                        defer { git_object_free(hideObj) }
                        var hideOid = git_object_id(hideObj)!.pointee
                        git_revwalk_hide(walk, &hideOid)
                    }
                    var pushObj: OpaquePointer?
                    if git_revparse_single(&pushObj, repo, parts[1]) == 0, let pushObj {
                        defer { git_object_free(pushObj) }
                        var pushOid = git_object_id(pushObj)!.pointee
                        git_revwalk_push(walk, &pushOid)
                        pushedRevision = true
                    }
                }
            } else {
                // Try as revision first, fall back to path
                var revObj: OpaquePointer?
                if git_revparse_single(&revObj, repo, positional) == 0, let revObj {
                    defer { git_object_free(revObj) }
                    var revOid = git_object_id(revObj)!.pointee
                    git_revwalk_push(walk, &revOid)
                    pushedRevision = true
                } else {
                    opts.paths.append(positional)
                }
            }
        }

        if !pushedRevision {
            // Default: push HEAD
            var headOid = git_oid()
            let headResult = git_reference_name_to_id(&headOid, repo, "HEAD")
            if headResult != 0 {
                out.line(GitStyle.fg(GitStyle.warning, "No commits yet"))
                out.flush()
                return 0
            }
            git_revwalk_push(walk, &headOid)
        }

        var oid = git_oid()
        var shown = 0

        // For graph mode, collect commits first
        if opts.graph {
            return try renderGraph(repo: repo, walk: walk!, opts: opts, output: &out)
        }

        while git_revwalk_next(&oid, walk) == 0 && shown < opts.maxCount {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }

            if shouldSkipCommit(commit: commit, opts: opts) { continue }

            // Path filtering
            if !opts.paths.isEmpty {
                if !commitTouchesPath(commit: commit, repo: repo, paths: opts.paths) {
                    continue
                }
            }

            if let format = opts.format {
                writeFormatted(commit: commit, oid: &oid, repo: repo, format: format, output: &out)
            } else if opts.oneline {
                writeOneline(commit: commit, oid: &oid, repo: repo, output: &out)
            } else {
                writeFull(commit: commit, oid: &oid, repo: repo, output: &out)
            }

            if opts.showStat {
                writeDiffStat(commit: commit, repo: repo, output: &out)
            }

            if opts.showPatch {
                writeDiffPatch(commit: commit, repo: repo, output: &out)
            }

            shown += 1
        }

        out.flush()
        return 0
    }

    // MARK: - Option parsing

    private static func parseOptions(args: [String]) -> LogOptions {
        var opts = LogOptions()
        var afterDashDash = false

        var i = 0
        while i < args.count {
            if afterDashDash {
                opts.paths.append(args[i])
                i += 1
                continue
            }

            switch args[i] {
            case "--": afterDashDash = true
            case "--oneline": opts.oneline = true
            case "--all": opts.all = true
            case "--graph": opts.graph = true
            case "--no-merges": opts.noMerges = true
            case "--first-parent": opts.firstParent = true
            case "--stat": opts.showStat = true
            case "-p", "--patch": opts.showPatch = true
            case "-n", "--max-count":
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    opts.maxCount = n
                    i += 1
                }
            case "--author":
                if i + 1 < args.count {
                    opts.authorFilter = args[i + 1]
                    i += 1
                }
            case "--grep":
                if i + 1 < args.count {
                    opts.grepPattern = args[i + 1]
                    i += 1
                }
            default:
                if args[i].hasPrefix("-n"), let n = Int(String(args[i].dropFirst(2))) {
                    opts.maxCount = n
                } else if args[i].hasPrefix("--max-count="), let n = Int(String(args[i].dropFirst(12))) {
                    opts.maxCount = n
                } else if args[i].hasPrefix("--author=") {
                    opts.authorFilter = String(args[i].dropFirst(9))
                } else if args[i].hasPrefix("--since=") {
                    opts.sinceDate = parseDate(String(args[i].dropFirst(8)))
                } else if args[i].hasPrefix("--after=") {
                    opts.sinceDate = parseDate(String(args[i].dropFirst(8)))
                } else if args[i].hasPrefix("--until=") {
                    opts.untilDate = parseDate(String(args[i].dropFirst(8)))
                } else if args[i].hasPrefix("--before=") {
                    opts.untilDate = parseDate(String(args[i].dropFirst(9)))
                } else if args[i].hasPrefix("--grep=") {
                    opts.grepPattern = String(args[i].dropFirst(7))
                } else if args[i].hasPrefix("--format=") {
                    let fmt = String(args[i].dropFirst(9))
                    opts.format = fmt
                } else if args[i].hasPrefix("--pretty=format:") {
                    opts.format = String(args[i].dropFirst(16))
                } else if args[i].hasPrefix("--pretty=") {
                    let preset = String(args[i].dropFirst(9))
                    if preset == "oneline" { opts.oneline = true }
                    // Other presets (short, medium, full) use default
                } else if !args[i].hasPrefix("-") {
                    opts.positionals.append(args[i])
                }
            }
            i += 1
        }

        return opts
    }

    // MARK: - Commit filtering

    private static func shouldSkipCommit(commit: OpaquePointer, opts: LogOptions) -> Bool {
        // Author filter
        if let authorFilter = opts.authorFilter {
            let sig = git_commit_author(commit)
            let authorName = sig?.pointee.name.map { String(cString: $0) } ?? ""
            let authorEmail = sig?.pointee.email.map { String(cString: $0) } ?? ""
            if !authorName.localizedCaseInsensitiveContains(authorFilter) &&
               !authorEmail.localizedCaseInsensitiveContains(authorFilter) {
                return true
            }
        }

        // No-merges filter
        if opts.noMerges && git_commit_parentcount(commit) > 1 {
            return true
        }

        // Time-based filters
        let sig = git_commit_author(commit)
        let commitTime = sig?.pointee.when.time ?? 0
        let commitDate = Date(timeIntervalSince1970: TimeInterval(commitTime))

        if let since = opts.sinceDate, commitDate < since {
            return true
        }

        if let until = opts.untilDate, commitDate > until {
            return true
        }

        // Grep filter
        if let pattern = opts.grepPattern {
            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
            if !message.localizedCaseInsensitiveContains(pattern) {
                return true
            }
        }

        return false
    }

    // MARK: - Path filtering

    private static func commitTouchesPath(commit: OpaquePointer, repo: OpaquePointer, paths: [String]) -> Bool {
        var commitTree: OpaquePointer?
        guard git_commit_tree(&commitTree, commit) == 0, let commitTree else { return false }
        defer { git_tree_free(commitTree) }

        // Get parent tree (nil for root commit)
        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        // Diff with pathspec
        var diffOpts = git_diff_options()
        git_diff_options_init(&diffOpts, UInt32(GIT_DIFF_OPTIONS_VERSION))

        let oldPfx = strdup("a")
        let newPfx = strdup("b")
        diffOpts.old_prefix = UnsafePointer(oldPfx)
        diffOpts.new_prefix = UnsafePointer(newPfx)
        defer { free(oldPfx); free(newPfx) }

        let cStrings = paths.map { strdup($0)! }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: paths.count)
        defer {
            cStrings.forEach { free($0) }
            ptrs.deallocate()
        }
        for (idx, cs) in cStrings.enumerated() {
            ptrs[idx] = cs
        }
        diffOpts.pathspec.strings = ptrs
        diffOpts.pathspec.count = paths.count

        var diff: OpaquePointer?
        let result = git_diff_tree_to_tree(&diff, repo, parentTree, commitTree, &diffOpts)
        if result != 0 { return false }
        guard let diff else { return false }
        defer { git_diff_free(diff) }

        return git_diff_num_deltas(diff) > 0
    }

    // MARK: - Oneline format

    private static func writeOneline(commit: OpaquePointer, oid: UnsafeMutablePointer<git_oid>, repo: OpaquePointer, output: inout GitOutput) {
        let shortHash = oidShortString(oid)
        let message = git_commit_message(commit).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstLine = message.components(separatedBy: "\n").first ?? message

        let sig = git_commit_author(commit)
        let authorName = sig?.pointee.name.map { String(cString: $0) } ?? "unknown"
        let time = sig?.pointee.when.time ?? 0
        let relTime = relativeTime(from: time)

        // Refs decoration
        let refs = refsForCommit(oid: oid, repo: repo)
        let refStr = refs.isEmpty ? "" : "  \(refs)"

        output.raw(GitStyle.fg(GitStyle.hash, "\(GitStyle.commitIcon) \(shortHash)"))
        output.raw("  \(firstLine)")
        output.raw("  \(GitStyle.fg(GitStyle.dimColor, "(\(authorName), \(relTime))"))")
        output.raw(refStr)
        output.line()
    }

    // MARK: - Full format

    private static func writeFull(commit: OpaquePointer, oid: UnsafeMutablePointer<git_oid>, repo: OpaquePointer, output: inout GitOutput) {
        let fullHash = oidFullString(oid)
        let message = git_commit_message(commit).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let sig = git_commit_author(commit)
        let authorName = sig?.pointee.name.map { String(cString: $0) } ?? "unknown"
        let authorEmail = sig?.pointee.email.map { String(cString: $0) } ?? ""
        let time = sig?.pointee.when.time ?? 0

        // Refs decoration
        let refs = refsForCommit(oid: oid, repo: repo)

        output.raw(GitStyle.fg(GitStyle.hash, "commit \(fullHash)"))
        if !refs.isEmpty {
            output.raw("  \(refs)")
        }
        output.line()
        output.line(GitStyle.fg(GitStyle.author, "Author: \(authorName) <\(authorEmail)>"))
        output.line(GitStyle.fg(GitStyle.dateColor, "Date:   \(formatDate(from: time))"))
        output.line()

        // Indent message
        for line in message.components(separatedBy: "\n") {
            output.line("    \(line)")
        }
        output.line()
    }

    // MARK: - Custom format

    private static func writeFormatted(commit: OpaquePointer, oid: UnsafeMutablePointer<git_oid>, repo: OpaquePointer, format: String, output: inout GitOutput) {
        let sig = git_commit_author(commit)
        let authorName = sig?.pointee.name.map { String(cString: $0) } ?? "unknown"
        let authorEmail = sig?.pointee.email.map { String(cString: $0) } ?? ""
        let time = sig?.pointee.when.time ?? 0
        let message = git_commit_message(commit).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let firstLine = message.components(separatedBy: "\n").first ?? message
        let body = message.components(separatedBy: "\n").dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let refs = refsForCommit(oid: oid, repo: repo)
        let refsStr = refs.isEmpty ? "" : " \(refs)"

        var result = format
        result = result.replacingOccurrences(of: "%H", with: oidFullString(oid))
        result = result.replacingOccurrences(of: "%h", with: oidShortString(oid))
        result = result.replacingOccurrences(of: "%an", with: authorName)
        result = result.replacingOccurrences(of: "%ae", with: authorEmail)
        result = result.replacingOccurrences(of: "%ad", with: formatDate(from: time))
        result = result.replacingOccurrences(of: "%ar", with: relativeTime(from: time))
        result = result.replacingOccurrences(of: "%s", with: firstLine)
        result = result.replacingOccurrences(of: "%b", with: body)
        result = result.replacingOccurrences(of: "%d", with: refsStr)
        result = result.replacingOccurrences(of: "%n", with: "\r\n")

        output.line(result)
    }

    // MARK: - Diffstat per commit

    private static func writeDiffStat(commit: OpaquePointer, repo: OpaquePointer, output: inout GitOutput) {
        var commitTree: OpaquePointer?
        guard git_commit_tree(&commitTree, commit) == 0, let commitTree else { return }
        defer { git_tree_free(commitTree) }

        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, parentTree, commitTree, nil) == 0,
              let diff else { return }
        defer { git_diff_free(diff) }

        var stats: OpaquePointer?
        guard git_diff_get_stats(&stats, diff) == 0, let stats else { return }
        defer { git_diff_stats_free(stats) }

        var buf = git_buf()
        let statsFormat = git_diff_stats_format_t(rawValue: GIT_DIFF_STATS_FULL.rawValue | GIT_DIFF_STATS_SHORT.rawValue)
        guard git_diff_stats_to_buf(&buf, stats, statsFormat, 80) == 0 else { return }
        defer { git_buf_dispose(&buf) }

        if let ptr = buf.ptr {
            let statStr = String(cString: ptr)
            for line in statStr.components(separatedBy: "\n") where !line.isEmpty {
                output.line(" \(line)")
            }
        }
    }

    // MARK: - Full patch per commit

    private static func writeDiffPatch(commit: OpaquePointer, repo: OpaquePointer, output: inout GitOutput) {
        var commitTree: OpaquePointer?
        guard git_commit_tree(&commitTree, commit) == 0, let commitTree else { return }
        defer { git_tree_free(commitTree) }

        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, parentTree, commitTree, nil) == 0,
              let diff else { return }
        defer { git_diff_free(diff) }

        struct PatchCtx {
            var output: GitOutput
        }
        var ctx = PatchCtx(output: output)

        let printCb: git_diff_line_cb = { delta, hunk, line, payload in
            guard let payload, let line else { return 0 }
            let ctx = payload.assumingMemoryBound(to: PatchCtx.self)

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
                ctx.pointee.output.line(GitStyle.boldFg(GitStyle.headerColor, trimmed))
            case "H".utf8.first.map(CChar.init)!:
                ctx.pointee.output.line(GitStyle.fg(GitStyle.info, trimmed))
            default:
                ctx.pointee.output.line(" \(trimmed)")
            }
            return 0
        }
        // withUnsafeMutablePointer rather than `&ctx`: PatchCtx holds heap
        // references, and the implicit inout-to-raw-pointer conversion is only
        // valid for trivial types.
        withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            _ = git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, printCb, ctxPtr)
        }

        output = ctx.output
    }

    // MARK: - Graph rendering

    private static func renderGraph(repo: OpaquePointer, walk: OpaquePointer, opts: LogOptions, output: inout GitOutput) throws -> Int32 {
        struct GraphCommit {
            var oid: git_oid
            var parentOids: [git_oid]
            var message: String
            var shortHash: String
            var authorName: String
            var relTime: String
            var refs: String
        }

        var commits: [GraphCommit] = []
        var oid = git_oid()
        var collected = 0

        while git_revwalk_next(&oid, walk) == 0 && collected < opts.maxCount {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }

            if shouldSkipCommit(commit: commit, opts: opts) { continue }

            // Path filtering
            if !opts.paths.isEmpty {
                if !commitTouchesPath(commit: commit, repo: repo, paths: opts.paths) {
                    continue
                }
            }

            let parentCount = git_commit_parentcount(commit)
            var parentOids: [git_oid] = []
            for p in 0..<parentCount {
                if let parentOid = git_commit_parent_id(commit, p) {
                    parentOids.append(parentOid.pointee)
                }
            }

            let message = git_commit_message(commit).map { String(cString: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first ?? ""

            let sig = git_commit_author(commit)
            let authorName = sig?.pointee.name.map { String(cString: $0) } ?? "unknown"
            let time = sig?.pointee.when.time ?? 0

            commits.append(GraphCommit(
                oid: oid,
                parentOids: parentOids,
                message: message,
                shortHash: oidShortString(&oid),
                authorName: authorName,
                relTime: relativeTime(from: time),
                refs: refsForCommit(oid: &oid, repo: repo)
            ))

            collected += 1
        }

        // Simple single-column graph
        for (idx, gc) in commits.enumerated() {
            let isLast = idx == commits.count - 1
            let isMerge = gc.parentOids.count > 1
            let graphPrefix: String

            if isMerge {
                graphPrefix = GitStyle.fg(GitStyle.dimColor, "*   ")
            } else {
                graphPrefix = GitStyle.fg(GitStyle.dimColor, "* ")
            }

            let refStr = gc.refs.isEmpty ? "" : "  \(gc.refs)"

            output.raw(graphPrefix)
            output.raw(GitStyle.fg(GitStyle.hash, "\(GitStyle.commitIcon) \(gc.shortHash)"))
            output.raw("  \(gc.message)")
            output.raw("  \(GitStyle.fg(GitStyle.dimColor, "(\(gc.authorName), \(gc.relTime))"))")
            output.raw(refStr)
            output.line()

            // Show stat/patch per commit if requested
            if opts.showStat || opts.showPatch {
                var commitOid = gc.oid
                var commit: OpaquePointer?
                if git_commit_lookup(&commit, repo, &commitOid) == 0, let commit {
                    defer { git_commit_free(commit) }
                    if opts.showStat {
                        writeDiffStat(commit: commit, repo: repo, output: &output)
                    }
                    if opts.showPatch {
                        writeDiffPatch(commit: commit, repo: repo, output: &output)
                    }
                }
            }

            if !isLast {
                output.line(GitStyle.fg(GitStyle.dimColor, "|"))
            }
        }

        output.flush()
        return 0
    }

    // MARK: - Ref decoration

    private static func refsForCommit(oid: UnsafeMutablePointer<git_oid>, repo: OpaquePointer) -> String {
        var parts: [String] = []

        // Check HEAD
        var headOid = git_oid()
        if git_reference_name_to_id(&headOid, repo, "HEAD") == 0 {
            if git_oid_equal(oid, &headOid) != 0 {
                // Find what HEAD points to
                var headRef: OpaquePointer?
                if git_repository_head(&headRef, repo) == 0, let headRef {
                    defer { git_reference_free(headRef) }
                    if git_reference_is_branch(headRef) != 0 {
                        let branchName = git_reference_shorthand(headRef).map { String(cString: $0) } ?? "HEAD"
                        parts.append(GitStyle.boldFg(GitStyle.branch, "HEAD -> \(branchName)"))
                    } else {
                        parts.append(GitStyle.boldFg(GitStyle.branch, "HEAD"))
                    }
                }
            }
        }

        // Check branches
        var branchIter: OpaquePointer?
        if git_branch_iterator_new(&branchIter, repo, GIT_BRANCH_LOCAL) == 0, let branchIter {
            defer { git_branch_iterator_free(branchIter) }
            var ref: OpaquePointer?
            var btype = GIT_BRANCH_LOCAL
            while git_branch_next(&ref, &btype, branchIter) == 0, let ref {
                defer { git_reference_free(ref) }
                var refOid = git_oid()
                if git_reference_name_to_id(&refOid, repo, git_reference_name(ref)) == 0 {
                    if git_oid_equal(oid, &refOid) != 0 {
                        let name = git_reference_shorthand(ref).map { String(cString: $0) } ?? ""
                        // Skip if already in HEAD -> branch
                        if !parts.contains(where: { $0.contains(name) }) {
                            parts.append(GitStyle.fg(GitStyle.branch, name))
                        }
                    }
                }
            }
        }

        // Check tags via reference iteration
        var refIter: OpaquePointer?
        if git_reference_iterator_glob_new(&refIter, repo, "refs/tags/*") == 0, let refIter {
            defer { git_reference_iterator_free(refIter) }
            var ref: OpaquePointer?
            while git_reference_next(&ref, refIter) == 0, let ref {
                defer { git_reference_free(ref) }
                var tagOid = git_oid()

                // Peel annotated tags to their target commit
                var peeled: OpaquePointer?
                if git_reference_peel(&peeled, ref, GIT_OBJECT_COMMIT) == 0, let peeled {
                    defer { git_object_free(peeled) }
                    let peeledOid = git_object_id(peeled)
                    if let peeledOid, git_oid_equal(oid, peeledOid) != 0 {
                        let name = git_reference_shorthand(ref).map { String(cString: $0) } ?? ""
                        parts.append(GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(name)"))
                    }
                } else if git_reference_name_to_id(&tagOid, repo, git_reference_name(ref)) == 0 {
                    if git_oid_equal(oid, &tagOid) != 0 {
                        let name = git_reference_shorthand(ref).map { String(cString: $0) } ?? ""
                        parts.append(GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(name)"))
                    }
                }
            }
        }

        guard !parts.isEmpty else { return "" }
        return "(\(parts.joined(separator: ", ")))"
    }

    // MARK: - Time formatting

    static func relativeTime(from epochTime: git_time_t) -> String {
        let now = time(nil)
        let diff = Int(Int64(now) - epochTime)

        if diff < 60 { return "just now" }
        if diff < 3600 {
            let mins = diff / 60
            return "\(mins) minute\(mins == 1 ? "" : "s") ago"
        }
        if diff < 86400 {
            let hours = diff / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        if diff < 2592000 {
            let days = diff / 86400
            if days == 1 { return "yesterday" }
            return "\(days) days ago"
        }
        if diff < 31536000 {
            let months = diff / 2592000
            return "\(months) month\(months == 1 ? "" : "s") ago"
        }
        let years = diff / 31536000
        return "\(years) year\(years == 1 ? "" : "s") ago"
    }

    static func formatDate(from epochTime: git_time_t) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epochTime))
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
        return formatter.string(from: date)
    }

    // MARK: - Date parsing

    private static func parseDate(_ str: String) -> Date? {
        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd"
            let iso2 = DateFormatter()
            iso2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return [iso, iso2]
        }()

        for fmt in formatters {
            if let d = fmt.date(from: str) { return d }
        }

        // Handle relative dates like "2 weeks ago", "yesterday"
        let lower = str.lowercased()
        let now = Date()
        if lower == "yesterday" {
            return Calendar.current.date(byAdding: .day, value: -1, to: now)
        }
        if lower.hasSuffix(" ago") {
            let parts = lower.replacingOccurrences(of: " ago", with: "").components(separatedBy: " ")
            if parts.count == 2, let n = Int(parts[0]) {
                let unit = parts[1]
                if unit.hasPrefix("day") { return Calendar.current.date(byAdding: .day, value: -n, to: now) }
                if unit.hasPrefix("week") { return Calendar.current.date(byAdding: .weekOfYear, value: -n, to: now) }
                if unit.hasPrefix("month") { return Calendar.current.date(byAdding: .month, value: -n, to: now) }
                if unit.hasPrefix("year") { return Calendar.current.date(byAdding: .year, value: -n, to: now) }
            }
        }

        return nil
    }
}

#endif
