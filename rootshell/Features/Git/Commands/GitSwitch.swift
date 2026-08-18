#if !targetEnvironment(macCatalyst)

import Foundation

/// `git switch` — switch branches (modern alternative to `git checkout` for branch switching).
enum GitSwitch: GitSubcommand {
    static var helpText: String {
        "usage: git switch [<options>] <branch>\r\n       git switch -c|-C <new-branch> [<start-point>]\r\n       git switch --detach <commit>\r\n\r\n    Switch branches\r\n\r\nOptions:\r\n    -c, --create <branch>    Create and switch to a new branch\r\n    -C, --force-create       Create or reset and switch to a branch\r\n    -d, --detach             Switch to a commit in detached HEAD\r\n    -f, --force              Force switch (discard local changes)\r\n    --track                  Set up tracking for new branch\r\n    --no-track               Do not set up tracking\r\n    --guess                  Try to match remote branch (default)\r\n    --no-guess               Do not try to match remote branch\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var force = false
        var createBranch = false
        var forceCreate = false
        var detach = false
        var track = false
        var noTrack = false
        var noGuess = false
        var positional: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-f", "--force": force = true
            case "-c", "--create": createBranch = true
            case "-C", "--force-create": forceCreate = true; createBranch = true
            case "-d", "--detach": detach = true
            case "--track": track = true
            case "--no-track": noTrack = true
            case "--no-guess": noGuess = true
            case "--guess": noGuess = false
            default:
                if !args[i].hasPrefix("-") {
                    positional.append(args[i])
                }
            }
            i += 1
        }

        // git switch - (switch to previous branch)
        if positional.count == 1 && positional[0] == "-" {
            return try switchToPrevious(repo: repo, force: force, output: output)
        }

        // Create and switch
        if createBranch {
            guard let branchName = positional.first else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: missing branch name\r\n"))
                return 128
            }
            let startPoint = positional.count > 1 ? positional[1] : nil
            return try createAndSwitch(repo: repo, branchName: branchName, startPoint: startPoint,
                                        force: force, resetIfExists: forceCreate,
                                        track: track && !noTrack, output: output)
        }

        guard let target = positional.first else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: missing branch or commit argument\r\n"))
            return 1
        }

        // Detached HEAD
        if detach {
            return try switchDetached(repo: repo, target: target, force: force, output: output)
        }

        // Try local branch
        let branchRef = "refs/heads/\(target)"
        var ref: OpaquePointer?
        if git_reference_lookup(&ref, repo, branchRef) == 0, let ref {
            defer { git_reference_free(ref) }
            return try switchToBranch(repo: repo, ref: ref, name: target, force: force, output: output)
        }

        // Try matching a remote branch (--guess behavior, on by default)
        if !noGuess {
            if let remoteBranch = try findRemoteBranch(repo: repo, name: target) {
                // Create local branch tracking the remote
                return try createAndSwitch(repo: repo, branchName: target, startPoint: remoteBranch,
                                            force: force, resetIfExists: false,
                                            track: true, output: output)
            }
        }

        output(GitStyle.fg(GitStyle.errorColor, "fatal: invalid reference: \(target)\r\n"))
        return 128
    }

    // MARK: - Switch to branch

    private static func switchToBranch(repo: OpaquePointer, ref: OpaquePointer, name: String, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var treeObj: OpaquePointer?
        try lg2Check(git_reference_peel(&treeObj, ref, GIT_OBJECT_TREE), "failed to peel reference")
        guard let treeObj else { return 1 }
        defer { git_object_free(treeObj) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue

        try lg2Check(git_checkout_tree(repo, treeObj, &opts), "failed to switch branches")

        let refName = "refs/heads/\(name)"
        try lg2Check(git_repository_set_head(repo, refName), "failed to set HEAD")

        output("Switched to branch '\(GitStyle.fg(GitStyle.branch, name))'\r\n")
        return 0
    }

    // MARK: - Detached switch

    private static func switchDetached(repo: OpaquePointer, target: String, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, target), "unknown revision '\(target)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        var commit: OpaquePointer?
        try lg2Check(git_object_peel(&commit, obj, GIT_OBJECT_COMMIT), "failed to peel to commit")
        guard let commit else { return 1 }
        defer { git_object_free(commit) }

        var treeObj: OpaquePointer?
        try lg2Check(git_object_peel(&treeObj, commit, GIT_OBJECT_TREE), "failed to get tree")
        guard let treeObj else { return 1 }
        defer { git_object_free(treeObj) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue

        try lg2Check(git_checkout_tree(repo, treeObj, &opts), "failed to checkout")

        let oid = git_object_id(commit)!
        try lg2Check(git_repository_set_head_detached(repo, oid), "failed to detach HEAD")

        let shortHash = oidShortString(oid)
        output("HEAD is now at \(GitStyle.fg(GitStyle.hash, shortHash))\r\n")
        return 0
    }

    // MARK: - Create and switch

    private static func createAndSwitch(
        repo: OpaquePointer,
        branchName: String,
        startPoint: String?,
        force: Bool,
        resetIfExists: Bool,
        track: Bool,
        output: @escaping @Sendable (String) -> Void
    ) throws -> Int32 {
        var targetObj: OpaquePointer?
        let revision = startPoint ?? "HEAD"
        let parseResult = git_revparse_single(&targetObj, repo, revision)
        if parseResult != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: not a valid object name: '\(revision)'\r\n"))
            return 128
        }
        guard let targetObj else { return 1 }
        defer { git_object_free(targetObj) }

        var commit: OpaquePointer?
        try lg2Check(git_object_peel(&commit, targetObj, GIT_OBJECT_COMMIT), "failed to peel '\(revision)' to a commit")
        guard let commit else { return 1 }
        defer { git_object_free(commit) }

        // Validate branch creation will succeed before modifying the worktree
        if !resetIfExists {
            var existingRef: OpaquePointer?
            if git_branch_lookup(&existingRef, repo, branchName, GIT_BRANCH_LOCAL) == 0 {
                git_reference_free(existingRef)
                output(GitStyle.fg(GitStyle.errorColor, "fatal: a branch named '\(branchName)' already exists\r\n"))
                return 128
            }
        }

        // Checkout tree — the risky operation that can fail on conflicts
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force ? GIT_CHECKOUT_FORCE.rawValue : GIT_CHECKOUT_SAFE.rawValue
        try lg2Check(git_checkout_tree(repo, targetObj, &opts), "failed to checkout '\(revision)'")

        // Create/reset branch only after checkout succeeds
        var newRef: OpaquePointer?
        let forceFlag: Int32 = resetIfExists ? 1 : 0
        let createResult = git_branch_create(&newRef, repo, branchName, commit, forceFlag)
        if createResult != 0 {
            // Capture error before rollback overwrites libgit2 error state
            let errMsg = git_error_last()?.pointee.message.map { String(cString: $0) }
                ?? "failed to create branch '\(branchName)'"

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

        // Set up tracking
        if track, let startPoint {
            var branchRef: OpaquePointer?
            if git_branch_lookup(&branchRef, repo, branchName, GIT_BRANCH_LOCAL) == 0, let branchRef {
                defer { git_reference_free(branchRef) }
                let upstreamResult = git_branch_set_upstream(branchRef, startPoint)
                if upstreamResult != 0 {
                    output(GitStyle.fg(GitStyle.warning, "warning: failed to set upstream to '\(startPoint)'\r\n"))
                }
            }
        }

        output("Switched to a new branch '\(GitStyle.fg(GitStyle.branch, branchName))'\r\n")
        return 0
    }

    // MARK: - Switch to previous branch

    private static func switchToPrevious(repo: OpaquePointer, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Read reflog to find previous branch
        var reflog: OpaquePointer?
        try lg2Check(git_reflog_read(&reflog, repo, "HEAD"), "failed to read HEAD reflog")
        guard let reflog else { return 1 }
        defer { git_reflog_free(reflog) }

        let count = git_reflog_entrycount(reflog)

        // Look for a "checkout: moving from X to Y" entry
        for idx in 0..<count {
            guard let entry = git_reflog_entry_byindex(reflog, idx) else { continue }
            guard let msgPtr = git_reflog_entry_message(entry) else { continue }
            let msg = String(cString: msgPtr)

            if msg.hasPrefix("checkout: moving from ") {
                // Extract the source branch name
                let remainder = msg.dropFirst("checkout: moving from ".count)
                if let toIdx = remainder.range(of: " to ") {
                    let prevBranch = String(remainder[remainder.startIndex..<toIdx.lowerBound])

                    // Check if that branch still exists
                    let branchRefStr = "refs/heads/\(prevBranch)"
                    var ref: OpaquePointer?
                    if git_reference_lookup(&ref, repo, branchRefStr) == 0, let ref {
                        defer { git_reference_free(ref) }
                        return try switchToBranch(repo: repo, ref: ref, name: prevBranch, force: force, output: output)
                    } else {
                        output(GitStyle.fg(GitStyle.errorColor, "error: previous branch '\(prevBranch)' no longer exists\r\n"))
                        return 1
                    }
                }
            }
        }

        output(GitStyle.fg(GitStyle.errorColor, "error: no previous branch found\r\n"))
        return 1
    }

    // MARK: - Find remote branch (--guess)

    private static func findRemoteBranch(repo: OpaquePointer, name: String) throws -> String? {
        var iter: OpaquePointer?
        let pattern = "refs/remotes/*/\(name)"
        guard git_reference_iterator_glob_new(&iter, repo, pattern) == 0, let iter else { return nil }
        defer { git_reference_iterator_free(iter) }

        var ref: OpaquePointer?
        if git_reference_next(&ref, iter) == 0, let ref {
            defer { git_reference_free(ref) }
            // Return the shorthand like "origin/main"
            if let shorthand = git_reference_shorthand(ref) {
                return String(cString: shorthand)
            }
        }

        return nil
    }
}

#endif
