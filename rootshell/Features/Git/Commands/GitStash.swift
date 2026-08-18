#if !targetEnvironment(macCatalyst)

import Foundation

/// `git stash [list|push|pop|apply|drop|clear|show]` — stash management.
enum GitStash: GitSubcommand {
    static var helpText: String {
        "usage: git stash [push [-m <message>] [-u] [-k]]\r\n       git stash list\r\n       git stash show [<stash>]\r\n       git stash pop [<stash>]\r\n       git stash apply [<stash>]\r\n       git stash drop [<stash>]\r\n       git stash clear\r\n       git stash branch <name> [<stash>]\r\n\r\n    Stash the changes in a dirty working directory away\r\n\r\nSubcommands:\r\n    push, save           Save your local modifications to a new stash\r\n    list                 List the stash entries\r\n    show                 Show stash diff\r\n    pop                  Apply and remove a single stash\r\n    apply                Apply a stash without removing it\r\n    drop                 Remove a single stash entry\r\n    clear                Remove all stash entries\r\n    branch <name>        Create a branch from a stash\r\n\r\nOptions:\r\n    -m, --message <msg>  Stash message (for push/save)\r\n    -u, --include-untracked  Include untracked files\r\n    -k, --keep-index     Keep staged changes in index\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Default (no subcommand) is push
        if args.isEmpty {
            return try stashPush(repo: repo, message: nil, includeUntracked: false, keepIndex: false, output: output)
        }

        let sub = args[0]

        switch sub {
        case "list":
            return try stashList(repo: repo, output: output)

        case "show":
            let index = parseStashIndex(args: Array(args.dropFirst()))
            return try stashShow(repo: repo, index: index, output: output)

        case "push", "save":
            var message: String?
            var includeUntracked = false
            var keepIndex = false
            var i = 1
            while i < args.count {
                switch args[i] {
                case "-m", "--message":
                    if i + 1 < args.count {
                        message = args[i + 1]
                        i += 1
                    }
                case "-u", "--include-untracked":
                    includeUntracked = true
                case "-k", "--keep-index":
                    keepIndex = true
                default:
                    if !args[i].hasPrefix("-") {
                        message = args[i]
                    }
                }
                i += 1
            }
            return try stashPush(repo: repo, message: message, includeUntracked: includeUntracked, keepIndex: keepIndex, output: output)

        case "pop":
            let index = parseStashIndex(args: Array(args.dropFirst()))
            return try stashPop(repo: repo, index: index, output: output)

        case "apply":
            let index = parseStashIndex(args: Array(args.dropFirst()))
            return try stashApply(repo: repo, index: index, output: output)

        case "drop":
            let index = parseStashIndex(args: Array(args.dropFirst()))
            return try stashDrop(repo: repo, index: index, output: output)

        case "clear":
            return try stashClear(repo: repo, output: output)

        case "branch":
            let remaining = Array(args.dropFirst())
            return try stashBranch(repo: repo, args: remaining, output: output)

        default:
            // If not a known subcommand, treat as push with message
            return try stashPush(repo: repo, message: sub, includeUntracked: false, keepIndex: false, output: output)
        }
    }

    // MARK: - List stashes

    private static func stashList(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        // withUnsafeMutablePointer rather than `&out`: GitOutput holds heap
        // references, and the implicit inout-to-raw-pointer conversion is
        // only valid for trivial types.
        withUnsafeMutablePointer(to: &out) { outPtr in
            _ = git_stash_foreach(repo, { index, message, oid, payload in
                guard let payload else { return 0 }
                let out = payload.assumingMemoryBound(to: GitOutput.self)

                let msg = message.map { String(cString: $0) } ?? "(no message)"
                var mutableOid = oid!.pointee
                let shortHash = oidShortString(&mutableOid)

                out.pointee.raw(GitStyle.fg(GitStyle.hash, "stash@{\(index)}"))
                out.pointee.raw(": ")
                out.pointee.raw(GitStyle.fg(GitStyle.dimColor, shortHash))
                out.pointee.raw(" \(msg)")
                out.pointee.line()

                return 0
            }, outPtr)
        }

        out.flush()
        return 0
    }

    // MARK: - Show stash diff

    private static func stashShow(repo: OpaquePointer, index: Int, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Get stash commit OID
        var stashOid = git_oid()
        let targetIndex = index

        struct StashCtx {
            var targetIndex: Int
            var oid: git_oid
            var found: Bool
        }
        var ctx = StashCtx(targetIndex: targetIndex, oid: git_oid(), found: false)

        git_stash_foreach(repo, { idx, message, oid, payload in
            guard let payload, let oid else { return 0 }
            let ctx = payload.assumingMemoryBound(to: StashCtx.self)
            if Int(idx) == ctx.pointee.targetIndex {
                ctx.pointee.oid = oid.pointee
                ctx.pointee.found = true
                return 1 // Stop iteration
            }
            return 0
        }, &ctx)

        if !ctx.found {
            output(GitStyle.fg(GitStyle.errorColor, "error: no stash entry at index \(index)\r\n"))
            return 1
        }
        stashOid = ctx.oid

        // Get the stash commit and its parent
        var stashCommit: OpaquePointer?
        guard git_commit_lookup(&stashCommit, repo, &stashOid) == 0, let stashCommit else {
            output(GitStyle.fg(GitStyle.errorColor, "error: failed to lookup stash commit\r\n"))
            return 1
        }
        defer { git_commit_free(stashCommit) }

        var stashTree: OpaquePointer?
        guard git_commit_tree(&stashTree, stashCommit) == 0, let stashTree else { return 1 }
        defer { git_tree_free(stashTree) }

        // Get parent tree (the base commit)
        var parentTree: OpaquePointer?
        if git_commit_parentcount(stashCommit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, stashCommit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, parentTree, stashTree, nil) == 0,
              let diff else {
            output("No changes in stash@{\(index)}\r\n")
            return 0
        }
        defer { git_diff_free(diff) }

        // Show diffstat
        var stats: OpaquePointer?
        guard git_diff_get_stats(&stats, diff) == 0, let stats else { return 1 }
        defer { git_diff_stats_free(stats) }

        var buf = git_buf()
        let statsFormat = git_diff_stats_format_t(rawValue: GIT_DIFF_STATS_FULL.rawValue | GIT_DIFF_STATS_SHORT.rawValue)
        guard git_diff_stats_to_buf(&buf, stats, statsFormat, 80) == 0 else { return 1 }
        defer { git_buf_dispose(&buf) }

        var out = GitOutput(write: output)
        if let ptr = buf.ptr {
            let statStr = String(cString: ptr)
            for line in statStr.components(separatedBy: "\n") where !line.isEmpty {
                out.line(line)
            }
        }
        out.flush()
        return 0
    }

    // MARK: - Push (save) stash

    private static func stashPush(repo: OpaquePointer, message: String?, includeUntracked: Bool, keepIndex: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Get signature
        var sig: UnsafeMutablePointer<git_signature>?
        let sigResult = git_signature_default(&sig, repo)
        if sigResult != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        guard let sig else {
            output(GitStyle.fg(GitStyle.errorColor, "error: unable to create signature\r\n"))
            return 1
        }
        defer { git_signature_free(sig) }

        var stashOid = git_oid()
        var flags: UInt32 = GIT_STASH_DEFAULT.rawValue
        if includeUntracked {
            flags |= GIT_STASH_INCLUDE_UNTRACKED.rawValue
        }
        if keepIndex {
            flags |= GIT_STASH_KEEP_INDEX.rawValue
        }
        let result = git_stash_save(&stashOid, repo, sig, message, flags)

        if result == GIT_ENOTFOUND.rawValue {
            output("No local changes to save\r\n")
            return 0
        }

        try lg2Check(result, "failed to stash changes")

        let shortHash = oidShortString(&stashOid)
        let msg = message ?? "WIP on current branch"
        output("Saved working directory and index state \(GitStyle.fg(GitStyle.dimColor, msg))\r\n")
        output("  \(GitStyle.fg(GitStyle.hash, shortHash))\r\n")
        return 0
    }

    // MARK: - Pop stash

    private static func stashPop(repo: OpaquePointer, index: Int, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var applyOpts = git_stash_apply_options()
        git_stash_apply_options_init(&applyOpts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))

        let result = git_stash_pop(repo, index, &applyOpts)

        if result == GIT_ENOTFOUND.rawValue {
            output(GitStyle.fg(GitStyle.errorColor, "error: no stash entry at index \(index)\r\n"))
            return 1
        }

        if result == GIT_EMERGECONFLICT.rawValue {
            output(GitStyle.fg(GitStyle.warning, "Auto-merge conflict. Fix conflicts and then commit the result.\r\n"))
            output("The stash entry is kept since conflicts prevented a clean apply.\r\n")
            return 1
        }

        try lg2Check(result, "failed to pop stash")

        output("Dropped stash@{\(index)} and applied changes\r\n")
        return 0
    }

    // MARK: - Apply stash

    private static func stashApply(repo: OpaquePointer, index: Int, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var applyOpts = git_stash_apply_options()
        git_stash_apply_options_init(&applyOpts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))

        let result = git_stash_apply(repo, index, &applyOpts)

        if result == GIT_ENOTFOUND.rawValue {
            output(GitStyle.fg(GitStyle.errorColor, "error: no stash entry at index \(index)\r\n"))
            return 1
        }

        if result == GIT_EMERGECONFLICT.rawValue {
            output(GitStyle.fg(GitStyle.warning, "Auto-merge conflict. Fix conflicts and then commit the result.\r\n"))
            return 1
        }

        try lg2Check(result, "failed to apply stash")

        output("Applied stash@{\(index)}\r\n")
        return 0
    }

    // MARK: - Drop stash

    private static func stashDrop(repo: OpaquePointer, index: Int, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let result = git_stash_drop(repo, index)

        if result == GIT_ENOTFOUND.rawValue {
            output(GitStyle.fg(GitStyle.errorColor, "error: no stash entry at index \(index)\r\n"))
            return 1
        }

        try lg2Check(result, "failed to drop stash")

        output("Dropped stash@{\(index)}\r\n")
        return 0
    }

    // MARK: - Clear all stashes

    private static func stashClear(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Drop all stashes by repeatedly dropping index 0
        var dropped = 0
        while git_stash_drop(repo, 0) == 0 {
            dropped += 1
        }

        if dropped == 0 {
            output("No stash entries to clear\r\n")
        } else {
            output("Cleared \(dropped) stash entr\(dropped == 1 ? "y" : "ies")\r\n")
        }

        return 0
    }

    // MARK: - Branch from stash

    private static func stashBranch(repo: OpaquePointer, args: [String], output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let branchName = args.first else {
            output(GitStyle.fg(GitStyle.errorColor, "error: branch name required\r\n"))
            return 1
        }

        let stashIndex = args.count > 1 ? parseStashIndex(args: [args[1]]) : 0

        // Get the stash commit OID to find the base commit
        struct StashCtx {
            var targetIndex: Int
            var oid: git_oid
            var found: Bool
        }
        var ctx = StashCtx(targetIndex: stashIndex, oid: git_oid(), found: false)

        git_stash_foreach(repo, { idx, message, oid, payload in
            guard let payload, let oid else { return 0 }
            let c = payload.assumingMemoryBound(to: StashCtx.self)
            if Int(idx) == c.pointee.targetIndex {
                c.pointee.oid = oid.pointee
                c.pointee.found = true
                return 1
            }
            return 0
        }, &ctx)

        if !ctx.found {
            output(GitStyle.fg(GitStyle.errorColor, "error: no stash entry at index \(stashIndex)\r\n"))
            return 1
        }

        // Get the stash commit's parent (base)
        var stashCommit: OpaquePointer?
        guard git_commit_lookup(&stashCommit, repo, &ctx.oid) == 0, let stashCommit else {
            return 1
        }
        defer { git_commit_free(stashCommit) }

        var baseCommit: OpaquePointer?
        guard git_commit_parent(&baseCommit, stashCommit, 0) == 0, let baseCommit else {
            return 1
        }
        defer { git_commit_free(baseCommit) }

        // Validate branch doesn't already exist before modifying worktree
        var existingRef: OpaquePointer?
        if git_branch_lookup(&existingRef, repo, branchName, GIT_BRANCH_LOCAL) == 0 {
            git_reference_free(existingRef)
            output(GitStyle.fg(GitStyle.errorColor, "fatal: a branch named '\(branchName)' already exists\r\n"))
            return 128
        }

        // Checkout the base commit's tree
        var baseTree: OpaquePointer?
        try lg2Check(git_commit_tree(&baseTree, baseCommit), "failed to get tree")
        guard let baseTree else { return 1 }
        defer { git_tree_free(baseTree) }

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try lg2Check(git_checkout_tree(repo, baseTree, &checkoutOpts), "failed to checkout base tree")

        // Create branch only after checkout succeeds
        var newRef: OpaquePointer?
        let createResult = git_branch_create(&newRef, repo, branchName, baseCommit, 0)
        if createResult < 0 {
            // Capture error before rollback overwrites libgit2 error state
            let errMsg = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"

            // Restore worktree safely — GIT_CHECKOUT_SAFE won't discard local modifications
            var restoreOpts = git_checkout_options()
            git_checkout_options_init(&restoreOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            restoreOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            let rollbackResult = git_checkout_head(repo, &restoreOpts)

            output(GitStyle.fg(GitStyle.errorColor, "fatal: \(errMsg)\r\n"))
            if rollbackResult != 0 {
                output(GitStyle.fg(GitStyle.warning, "warning: failed to restore working tree to HEAD\r\n"))
            }
            return 128
        }
        if let newRef { git_reference_free(newRef) }

        let refName = "refs/heads/\(branchName)"
        try lg2Check(git_repository_set_head(repo, refName), "failed to set HEAD")

        // Apply the stash
        var applyOpts = git_stash_apply_options()
        git_stash_apply_options_init(&applyOpts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))

        let applyResult = git_stash_pop(repo, stashIndex, &applyOpts)
        if applyResult != 0 && applyResult != GIT_EMERGECONFLICT.rawValue {
            try lg2Check(applyResult, "failed to apply stash to new branch")
        }

        output("Switched to a new branch '\(GitStyle.fg(GitStyle.branch, branchName))'\r\n")
        if applyResult == GIT_EMERGECONFLICT.rawValue {
            output(GitStyle.fg(GitStyle.warning, "Conflicts detected after applying stash\r\n"))
        }
        return 0
    }

    // MARK: - Helpers

    /// Parse stash index from args like "stash@{2}" or "2" or nothing (default 0).
    private static func parseStashIndex(args: [String]) -> Int {
        guard let arg = args.first else { return 0 }

        // Handle "stash@{N}" format
        if arg.hasPrefix("stash@{") && arg.hasSuffix("}") {
            let numStr = arg.dropFirst(7).dropLast(1)
            return Int(numStr) ?? 0
        }

        // Handle plain number
        return Int(arg) ?? 0
    }
}

#endif
