#if !targetEnvironment(macCatalyst)

import Foundation

/// `git reset` — unstage files or reset HEAD.
enum GitReset: GitSubcommand {
    static var helpText: String {
        "usage: git reset [<mode>] [<commit>]\r\n       git reset [--] <pathspec>...\r\n\r\n    Reset current HEAD to the specified state\r\n\r\nOptions:\r\n    --soft               Keep changes staged\r\n    --mixed              Unstage changes (default)\r\n    --hard               Discard all changes\r\n    --                   Separate paths from options\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var mode = "mixed"  // --soft, --mixed, --hard
        var paths: [String] = []
        var target: String?
        var afterDashDash = false

        var i = 0
        while i < args.count {
            if afterDashDash {
                paths.append(args[i])
                i += 1
                continue
            }

            switch args[i] {
            case "--soft": mode = "soft"
            case "--mixed": mode = "mixed"
            case "--hard": mode = "hard"
            case "--": afterDashDash = true
            default:
                if args[i].hasPrefix("-") {
                    i += 1
                    continue
                }
                // First non-flag could be a commit ref or a path
                if target == nil && paths.isEmpty {
                    // Try to resolve as a revision first
                    var obj: OpaquePointer?
                    if git_revparse_single(&obj, repo, args[i]) == 0, let obj {
                        git_object_free(obj)
                        target = args[i]
                    } else {
                        paths.append(args[i])
                    }
                } else {
                    paths.append(args[i])
                }
            }
            i += 1
        }

        // If paths are given, this is `git reset [<commit>] -- <paths>` (unstage files)
        if !paths.isEmpty {
            return try resetPaths(repo: repo, paths: paths, target: target, output: output)
        }

        // Otherwise, reset HEAD
        return try resetHead(repo: repo, mode: mode, target: target ?? "HEAD", output: output)
    }

    // MARK: - Reset paths (unstage files)

    private static func resetPaths(repo: OpaquePointer, paths: [String], target: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Resolve the target commit (default: HEAD). A nil target removes the
        // matching entries from the index, which is the correct behavior for
        // an unborn HEAD.
        var targetObj: OpaquePointer?
        if let target {
            try lg2Check(git_revparse_single(&targetObj, repo, target), "invalid revision '\(target)'")
        } else if git_revparse_single(&targetObj, repo, "HEAD") != 0 {
            targetObj = nil
        }
        defer {
            if let targetObj {
                git_object_free(targetObj)
            }
        }

        // Build pathspec
        var pathspecs: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer { pathspecs.forEach { free($0) } }

        var strarray = git_strarray()
        pathspecs.withUnsafeMutableBufferPointer { buf in
            strarray.strings = buf.baseAddress
            strarray.count = buf.count
        }

        try lg2Check(
            git_reset_default(repo, targetObj, &strarray),
            "failed to reset paths"
        )

        output("Unstaged changes after reset:\r\n")
        for path in paths {
            output("M\t\(path)\r\n")
        }

        return 0
    }

    // MARK: - Reset HEAD

    private static func resetHead(repo: OpaquePointer, mode: String, target: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var targetObj: OpaquePointer?
        try lg2Check(git_revparse_single(&targetObj, repo, target), "invalid revision '\(target)'")
        guard let targetObj else { return 1 }
        defer { git_object_free(targetObj) }

        // Peel to commit
        var commitObj: OpaquePointer?
        try lg2Check(git_object_peel(&commitObj, targetObj, GIT_OBJECT_COMMIT), "not a commit")
        guard let commitObj else { return 1 }
        defer { git_object_free(commitObj) }

        let resetType: git_reset_t
        switch mode {
        case "soft": resetType = GIT_RESET_SOFT
        case "hard": resetType = GIT_RESET_HARD
        default: resetType = GIT_RESET_MIXED
        }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        if mode == "hard" {
            opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        }

        try lg2Check(git_reset(repo, commitObj, resetType, &opts), "failed to reset")

        let shortHash = oidShortString(UnsafeMutablePointer(mutating: git_object_id(commitObj)))
        output("HEAD is now at \(GitStyle.fg(GitStyle.hash, shortHash))")

        // Show commit message
        var commit: OpaquePointer?
        if git_commit_lookup(&commit, repo, git_object_id(commitObj)) == 0, let commit {
            defer { git_commit_free(commit) }
            if let msg = git_commit_message(commit) {
                let firstLine = String(cString: msg).components(separatedBy: "\n").first ?? ""
                output(" \(firstLine)")
            }
        }
        output("\r\n")

        return 0
    }
}

#endif
