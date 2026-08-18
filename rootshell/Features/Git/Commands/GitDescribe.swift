#if !targetEnvironment(macCatalyst)

import Foundation

/// `git describe [--all] [--tags] [--long] [--match <pattern>]` — describe a commit using tags.
enum GitDescribe: GitSubcommand {
    static var helpText: String {
        "usage: git describe [<options>] [<commit-ish>]\r\n\r\n    Give an object a human-readable name based on an available ref\r\n\r\nOptions:\r\n    --all                Use any ref, not just annotated tags\r\n    --tags               Use any tag, including lightweight\r\n    --long               Always use long format\r\n    --always             Show abbreviated object ID as fallback\r\n    --match <pattern>    Only consider tags matching the pattern\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var showAll = false
        var tagsOnly = false
        var long = false
        var always = false
        var matchPattern: String?
        var commitRef: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--all": showAll = true
            case "--tags": tagsOnly = true
            case "--long": long = true
            case "--always": always = true
            case "--match":
                if i + 1 < args.count {
                    matchPattern = args[i + 1]
                    i += 1
                }
            default:
                if args[i].hasPrefix("--match=") {
                    matchPattern = String(args[i].dropFirst(8))
                } else if !args[i].hasPrefix("-") {
                    commitRef = args[i]
                }
            }
            i += 1
        }

        // Resolve the commit to describe
        var commit: OpaquePointer?
        if let commitRef {
            try lg2Check(git_revparse_single(&commit, repo, commitRef), "failed to resolve '\(commitRef)'")
        } else {
            try lg2Check(git_revparse_single(&commit, repo, "HEAD"), "failed to resolve HEAD")
        }
        guard let commit else { return 1 }
        defer { git_object_free(commit) }

        // Set up describe options
        var descOpts = git_describe_options()
        git_describe_options_init(&descOpts, UInt32(GIT_DESCRIBE_OPTIONS_VERSION))

        if showAll {
            descOpts.describe_strategy = GIT_DESCRIBE_ALL.rawValue
        } else if tagsOnly {
            descOpts.describe_strategy = GIT_DESCRIBE_TAGS.rawValue
        } else {
            descOpts.describe_strategy = GIT_DESCRIBE_DEFAULT.rawValue
        }

        descOpts.show_commit_oid_as_fallback = always ? 1 : 0

        // Set up format options
        var fmtOpts = git_describe_format_options()
        git_describe_format_options_init(&fmtOpts, UInt32(GIT_DESCRIBE_FORMAT_OPTIONS_VERSION))

        if long {
            fmtOpts.always_use_long_format = 1
        }

        if let matchPattern {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: --match '\(matchPattern)' is not supported by this implementation\r\n"))
            return 1
        }

        // Perform describe
        var descResult: OpaquePointer?
        let descErr = git_describe_commit(&descResult, commit, &descOpts)

        if descErr == GIT_ENOTFOUND.rawValue {
            if always {
                // Fall back to showing abbreviated commit hash
                let oid = git_object_id(commit)!
                let shortHash = oidShortString(oid)
                output(GitStyle.fg(GitStyle.hash, shortHash) + "\r\n")
                return 0
            }
            output(GitStyle.fg(GitStyle.errorColor, "fatal: no tag exactly matches '\(commitRef ?? "HEAD")'\r\n"))
            output("hint: try --always to show abbreviated commit hash\r\n")
            return 128
        }

        try lg2Check(descErr, "failed to describe commit")
        guard let descResult else { return 1 }
        defer { git_describe_result_free(descResult) }

        // Format result
        var buf = git_buf()
        try lg2Check(
            git_describe_format(&buf, descResult, &fmtOpts),
            "failed to format describe result"
        )
        defer { git_buf_dispose(&buf) }

        guard let ptr = buf.ptr else { return 1 }
        let description = String(cString: ptr)

        // Color the output: tag-hash-g{hash}
        let colored = colorizeDescription(description)
        output(colored + "\r\n")

        return 0
    }

    /// Colorize a describe string like "v1.2.3-4-gabcdef0".
    /// Format: <tag>-<distance>-g<hash>
    private static func colorizeDescription(_ desc: String) -> String {
        // Try to split on the pattern: tag-N-gHASH
        // Find the last "-g" which precedes the commit hash
        guard let gRange = desc.range(of: "-g", options: .backwards) else {
            // No distance info — it's an exact tag match
            return GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(desc)")
        }

        let beforeG = desc[desc.startIndex..<gRange.lowerBound]

        // Find the distance number before -g
        guard let dashRange = beforeG.range(of: "-", options: .backwards) else {
            return GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(desc)")
        }

        let tagPart = String(beforeG[beforeG.startIndex..<dashRange.lowerBound])
        let distancePart = String(beforeG[beforeG.index(after: dashRange.lowerBound)...])
        let hashPart = String(desc[gRange.upperBound...])

        return "\(GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(tagPart)"))" +
               "\(GitStyle.fg(GitStyle.dimColor, "-\(distancePart)-g"))" +
               "\(GitStyle.fg(GitStyle.hash, hashPart))"
    }
}

#endif
