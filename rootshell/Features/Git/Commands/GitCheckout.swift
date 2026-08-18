#if !targetEnvironment(macCatalyst)

import Foundation

/// `git checkout` — switch branches or restore files.
enum GitCheckout: GitSubcommand {
    static var helpText: String {
        "usage: git checkout [<options>] <branch>\r\n       git checkout -b|-B <new-branch>\r\n       git checkout [--] <pathspec>...\r\n\r\n    Switch branches or restore working tree files\r\n\r\nOptions:\r\n    -b <branch>          Create and checkout a new branch\r\n    -B <branch>          Create or reset and checkout a branch\r\n    -f, --force          Force checkout (discard local changes)\r\n    --track              Set up tracking for new branch\r\n    --ours               Resolve conflicts using our version\r\n    --theirs             Resolve conflicts using their version\r\n    --                   Separate paths from branch names\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var force = false
        var createBranch = false
        var createOrReset = false
        var track = false
        var useOurs = false
        var useTheirs = false
        var positional: [String] = []
        var paths: [String] = []
        var afterDashDash = false

        var i = 0
        while i < args.count {
            if afterDashDash {
                paths.append(args[i])
            } else {
                switch args[i] {
                case "--": afterDashDash = true
                case "-f", "--force": force = true
                case "-b": createBranch = true
                case "-B": createOrReset = true
                case "--track": track = true
                case "--ours": useOurs = true
                case "--theirs": useTheirs = true
                default:
                    if !args[i].hasPrefix("-") {
                        positional.append(args[i])
                    }
                }
            }
            i += 1
        }

        // Conflict resolution checkout
        if useOurs || useTheirs {
            let conflictPaths = !paths.isEmpty ? paths : positional
            if !conflictPaths.isEmpty {
                return try checkoutConflict(repo: repo, paths: conflictPaths, useOurs: useOurs, output: output)
            }
        }

        if !paths.isEmpty || afterDashDash {
            let treeish = positional.first
            return try checkoutPaths(repo: repo, treeish: treeish, paths: paths, output: output)
        }

        guard let target = positional.first else {
            output("error: you must specify a branch or commit\r\n")
            return 1
        }

        // Create and checkout new branch (or reset)
        if createBranch || createOrReset {
            let startPoint = positional.count > 1 ? positional[1] : nil
            return try createAndCheckout(repo: repo, branchName: target, startPoint: startPoint,
                                          force: force, resetIfExists: createOrReset, track: track, output: output)
        }

        // Try to checkout as branch first
        var ref: OpaquePointer?
        let branchRef = "refs/heads/\(target)"

        if git_reference_lookup(&ref, repo, branchRef) == 0, let ref {
            defer { git_reference_free(ref) }
            return try checkoutBranch(repo: repo, ref: ref, name: target, force: force, output: output)
        }

        // Try as a commit/tag
        var obj: OpaquePointer?
        if git_revparse_single(&obj, repo, target) == 0, let obj {
            defer { git_object_free(obj) }
            return try checkoutDetached(repo: repo, object: obj, target: target, force: force, output: output)
        }

        // Fall back to path checkout (e.g. `git checkout foo.txt`)
        return try checkoutPaths(repo: repo, treeish: nil, paths: positional, output: output)
    }

    // MARK: - Branch checkout

    private static func checkoutBranch(repo: OpaquePointer, ref: OpaquePointer, name: String, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Peel to commit/tree
        var treeObj: OpaquePointer?
        try lg2Check(git_reference_peel(&treeObj, ref, GIT_OBJECT_TREE), "failed to peel reference")
        guard let treeObj else { return 1 }
        defer { git_object_free(treeObj) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force
            ? GIT_CHECKOUT_FORCE.rawValue
            : GIT_CHECKOUT_SAFE.rawValue

        try lg2Check(git_checkout_tree(repo, treeObj, &opts), "failed to checkout")

        // Update HEAD
        let refName = "refs/heads/\(name)"
        try lg2Check(git_repository_set_head(repo, refName), "failed to set HEAD")

        output("Switched to branch '\(GitStyle.fg(GitStyle.branch, name))'\r\n")
        return 0
    }

    // MARK: - Detached checkout

    private static func checkoutDetached(repo: OpaquePointer, object: OpaquePointer, target: String, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Peel to commit
        var commit: OpaquePointer?
        try lg2Check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT), "failed to peel to commit")
        guard let commit else { return 1 }
        defer { git_object_free(commit) }

        // Get tree
        var treeObj: OpaquePointer?
        try lg2Check(git_object_peel(&treeObj, commit, GIT_OBJECT_TREE), "failed to get tree")
        guard let treeObj else { return 1 }
        defer { git_object_free(treeObj) }

        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = force
            ? GIT_CHECKOUT_FORCE.rawValue
            : GIT_CHECKOUT_SAFE.rawValue

        try lg2Check(git_checkout_tree(repo, treeObj, &opts), "failed to checkout")

        let oid = git_object_id(commit)!
        try lg2Check(git_repository_set_head_detached(repo, oid), "failed to detach HEAD")

        let shortHash = oidShortString(oid)
        output("HEAD is now at \(GitStyle.fg(GitStyle.hash, shortHash))\r\n")
        return 0
    }

    // MARK: - Create branch and checkout

    private static func createAndCheckout(
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
        let forceCreate: Int32 = resetIfExists ? 1 : 0
        let createResult = git_branch_create(&newRef, repo, branchName, commit, forceCreate)
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

        // Set up tracking if requested and start point looks like a remote branch
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

    // MARK: - Conflict resolution checkout

    private static func checkoutConflict(repo: OpaquePointer, paths: [String], useOurs: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))

        if useOurs {
            opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_USE_OURS.rawValue
        } else {
            opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_USE_THEIRS.rawValue
        }

        // Set pathspec
        let cStrings = paths.map { strdup($0)! }
        defer { cStrings.forEach { free($0) } }

        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: paths.count)
        defer { ptrs.deallocate() }
        for (idx, cs) in cStrings.enumerated() {
            ptrs[idx] = cs
        }
        opts.paths.strings = ptrs
        opts.paths.count = paths.count

        try lg2Check(git_checkout_head(repo, &opts), "failed to checkout conflict resolution")

        let side = useOurs ? "ours" : "theirs"
        for path in paths {
            output("Resolved '\(path)' using \(side)\r\n")
        }
        return 0
    }

    // MARK: - Path checkout (restore files)

    private static func checkoutPaths(repo: OpaquePointer, treeish: String?, paths: [String], output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue

        // Set pathspec
        let cStrings = paths.map { strdup($0)! }
        defer { cStrings.forEach { free($0) } }

        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: paths.count)
        defer { ptrs.deallocate() }
        for (idx, cs) in cStrings.enumerated() {
            ptrs[idx] = cs
        }
        opts.paths.strings = ptrs
        opts.paths.count = paths.count

        var obj: OpaquePointer?
        defer {
            if let obj {
                git_object_free(obj)
            }
        }

        if let treeish {
            try lg2Check(git_revparse_single(&obj, repo, treeish), "failed to parse '\(treeish)'")
        }

        try lg2Check(git_checkout_tree(repo, obj, &opts), "failed to checkout paths")

        return 0
    }
}

#endif
