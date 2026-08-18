#if !targetEnvironment(macCatalyst)

import Foundation

/// `git rebase` — reapply commits on top of another base tip.
enum GitRebase: GitSubcommand {
    static var helpText: String {
        "usage: git rebase [<options>] [<upstream>]\r\n       git rebase --onto <newbase> [<upstream>]\r\n       git rebase --continue | --abort | --skip\r\n\r\n    Reapply commits on top of another base tip\r\n\r\nOptions:\r\n    --onto <newbase>     Rebase onto a specific base\r\n    --continue           Continue after conflict resolution\r\n    --abort              Abort the current rebase\r\n    --skip               Skip the current patch\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var upstream: String?
        var onto: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--continue":
                return try continueRebase(repo: repo, output: output)
            case "--abort":
                return try abortRebase(repo: repo, output: output)
            case "--skip":
                return try skipRebase(repo: repo, output: output)
            case "--onto":
                if i + 1 < args.count {
                    onto = args[i + 1]
                    i += 1
                }
            default:
                if args[i].hasPrefix("--onto=") {
                    onto = String(args[i].dropFirst(7))
                } else if !args[i].hasPrefix("-") && upstream == nil {
                    upstream = args[i]
                }
            }
            i += 1
        }

        // Resolve upstream: explicit argument, or fall back to tracking branch
        let upstreamRef: String
        if let upstream {
            upstreamRef = upstream
        } else {
            var resolvedUpstream: String?
            var headRef: OpaquePointer?
            if git_repository_head(&headRef, repo) == 0, let headRef {
                defer { git_reference_free(headRef) }
                var trackingRef: OpaquePointer?
                if git_branch_upstream(&trackingRef, headRef) == 0, let trackingRef {
                    defer { git_reference_free(trackingRef) }
                    if let name = git_reference_shorthand(trackingRef) {
                        resolvedUpstream = String(cString: name)
                    }
                }
            }
            guard let resolved = resolvedUpstream else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: no upstream configured for the current branch\r\n"))
                output("Use: git rebase <upstream>\r\n")
                return 128
            }
            upstreamRef = resolved
        }

        return try startRebase(repo: repo, upstream: upstreamRef, onto: onto, output: output)
    }

    // MARK: - Start rebase

    private static func startRebase(repo: OpaquePointer, upstream: String, onto: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Resolve upstream
        var upstreamAnnotated: OpaquePointer?
        var upstreamObj: OpaquePointer?
        try lg2Check(git_revparse_single(&upstreamObj, repo, upstream), "unknown revision '\(upstream)'")
        guard let upstreamObj else { return 1 }
        defer { git_object_free(upstreamObj) }

        var upstreamOid = git_object_id(upstreamObj)!.pointee
        try lg2Check(
            git_annotated_commit_lookup(&upstreamAnnotated, repo, &upstreamOid),
            "failed to lookup upstream commit"
        )
        defer { if let upstreamAnnotated { git_annotated_commit_free(upstreamAnnotated) } }

        // Resolve onto (if provided)
        var ontoAnnotated: OpaquePointer?
        if let onto {
            var ontoObj: OpaquePointer?
            try lg2Check(git_revparse_single(&ontoObj, repo, onto), "unknown revision '\(onto)'")
            guard let ontoObj else { return 1 }
            defer { git_object_free(ontoObj) }

            var ontoOid = git_object_id(ontoObj)!.pointee
            try lg2Check(
                git_annotated_commit_lookup(&ontoAnnotated, repo, &ontoOid),
                "failed to lookup onto commit"
            )
        }
        defer { if let ontoAnnotated { git_annotated_commit_free(ontoAnnotated) } }

        // Init rebase
        var rebase: OpaquePointer?
        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))

        try lg2Check(
            git_rebase_init(&rebase, repo, nil, upstreamAnnotated, ontoAnnotated, &rebaseOpts),
            "failed to init rebase"
        )
        guard let rebase else { return 1 }
        defer { git_rebase_free(rebase) }

        return try performRebaseOperations(repo: repo, rebase: rebase, output: output)
    }

    // MARK: - Perform operations

    private static func performRebaseOperations(repo: OpaquePointer, rebase: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var operation: UnsafeMutablePointer<git_rebase_operation>?
        var applied = 0

        while git_rebase_next(&operation, rebase) == 0 {
            guard operation != nil else { continue }

            // Check for conflicts
            var index: OpaquePointer?
            try lg2Check(git_repository_index(&index, repo), "failed to open index")
            guard let index else { return 1 }
            defer { git_index_free(index) }

            if git_index_has_conflicts(index) != 0 {
                output(GitStyle.fg(GitStyle.warning, "Conflict while applying commit.\r\n"))
                output("Resolve conflicts and run \"git rebase --continue\".\r\n")
                output("To skip this commit: \"git rebase --skip\"\r\n")
                output("To abort: \"git rebase --abort\"\r\n")
                return 1
            }

            // Commit the operation
            var sig: UnsafeMutablePointer<git_signature>?
            if git_signature_default(&sig, repo) != 0 {
                git_signature_now(&sig, "User", "user@localhost")
            }
            defer { git_signature_free(sig) }

            var commitOid = git_oid()
            let commitResult = git_rebase_commit(&commitOid, rebase, nil, sig, nil, nil)
            if commitResult != 0 {
                // May fail if nothing to commit (empty patch)
                let errCode = commitResult
                if errCode == GIT_EAPPLIED.rawValue {
                    output(GitStyle.fg(GitStyle.dimColor, "Skipping empty commit\r\n"))
                    continue
                }
                try lg2Check(commitResult, "failed to commit rebase operation")
            }

            applied += 1
        }

        // Finish rebase
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        defer { git_signature_free(sig) }

        try lg2Check(git_rebase_finish(rebase, sig), "failed to finish rebase")

        output("Successfully rebased and updated refs/heads.\r\n")
        if applied > 0 {
            output("Applied \(applied) commit\(applied == 1 ? "" : "s").\r\n")
        }
        return 0
    }

    // MARK: - Continue

    private static func continueRebase(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var rebase: OpaquePointer?
        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))

        let openResult = git_rebase_open(&rebase, repo, &rebaseOpts)
        if openResult != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: no rebase in progress\r\n"))
            return 1
        }
        guard let rebase else { return 1 }
        defer { git_rebase_free(rebase) }

        // Check for remaining conflicts
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: unresolved conflicts remain\r\n"))
            return 1
        }

        // Commit current operation
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        defer { git_signature_free(sig) }

        var commitOid = git_oid()
        let commitResult = git_rebase_commit(&commitOid, rebase, nil, sig, nil, nil)
        if commitResult != 0 && commitResult != GIT_EAPPLIED.rawValue {
            try lg2Check(commitResult, "failed to commit rebase step")
        }

        // Continue with remaining operations
        return try performRebaseOperations(repo: repo, rebase: rebase, output: output)
    }

    // MARK: - Abort

    private static func abortRebase(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var rebase: OpaquePointer?
        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))

        let openResult = git_rebase_open(&rebase, repo, &rebaseOpts)
        if openResult != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: no rebase in progress\r\n"))
            return 1
        }
        guard let rebase else { return 1 }
        defer { git_rebase_free(rebase) }

        try lg2Check(git_rebase_abort(rebase), "failed to abort rebase")
        output("Rebase aborted.\r\n")
        return 0
    }

    // MARK: - Skip

    private static func skipRebase(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var rebase: OpaquePointer?
        var rebaseOpts = git_rebase_options()
        git_rebase_options_init(&rebaseOpts, UInt32(GIT_REBASE_OPTIONS_VERSION))

        let openResult = git_rebase_open(&rebase, repo, &rebaseOpts)
        if openResult != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: no rebase in progress\r\n"))
            return 1
        }
        guard let rebase else { return 1 }
        defer { git_rebase_free(rebase) }

        // Reset index to HEAD tree to clear conflict/unmerged entries
        var headRef: OpaquePointer?
        try lg2Check(git_repository_head(&headRef, repo), "failed to resolve HEAD")
        guard let headRef else { return 1 }
        defer { git_reference_free(headRef) }

        var headCommit: OpaquePointer?
        try lg2Check(git_reference_peel(&headCommit, headRef, GIT_OBJECT_COMMIT), "failed to peel HEAD")
        guard let headCommit else { return 1 }
        defer { git_object_free(headCommit) }

        var headCommitObj: OpaquePointer?
        try lg2Check(git_commit_lookup(&headCommitObj, repo, git_object_id(headCommit)), "failed to lookup HEAD commit")
        guard let headCommitObj else { return 1 }
        defer { git_commit_free(headCommitObj) }

        var headTree: OpaquePointer?
        try lg2Check(git_commit_tree(&headTree, headCommitObj), "failed to get HEAD tree")
        guard let headTree else { return 1 }
        defer { git_tree_free(headTree) }

        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        try lg2Check(git_index_read_tree(index, headTree), "failed to reset index")
        try lg2Check(git_index_write(index), "failed to write index")

        // Reset workdir to match
        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        try lg2Check(git_checkout_head(repo, &checkoutOpts), "failed to reset working tree")

        return try performRebaseOperations(repo: repo, rebase: rebase, output: output)
    }
}

#endif
