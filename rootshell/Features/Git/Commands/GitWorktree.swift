#if !targetEnvironment(macCatalyst)

import Foundation

/// `git worktree` — manage multiple working trees.
enum GitWorktree: GitSubcommand {
    static var helpText: String {
        "usage: git worktree list\r\n       git worktree add <path> [<branch>]\r\n       git worktree remove [-f] <worktree>\r\n       git worktree lock <worktree>\r\n       git worktree unlock <worktree>\r\n\r\n    Manage multiple working trees\r\n\r\nSubcommands:\r\n    list                 List linked worktrees\r\n    add <path> [<branch>]  Create a new worktree\r\n    remove <worktree>    Remove a worktree (name or path)\r\n    lock <worktree>      Lock a worktree (name or path)\r\n    unlock <worktree>    Unlock a worktree (name or path)\r\n\r\nOptions:\r\n    -f, --force          Force removal of dirty worktree\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        guard let sub = args.first else {
            output("usage: git worktree <subcommand>\r\n")
            return 1
        }

        switch sub {
        case "list":
            return try listWorktrees(repo: repo, output: output)
        case "add":
            let remaining = Array(args.dropFirst())
            return try addWorktree(repo: repo, args: remaining, output: output)
        case "remove":
            let remaining = Array(args.dropFirst())
            var force = false
            var worktreeId: String?
            for arg in remaining {
                if arg == "--force" || arg == "-f" {
                    force = true
                } else if !arg.hasPrefix("-") && worktreeId == nil {
                    worktreeId = arg
                }
            }
            guard let worktreeId else {
                output(GitStyle.fg(GitStyle.errorColor, "error: worktree name or path required\r\n"))
                return 1
            }
            return try removeWorktree(repo: repo, nameOrPath: worktreeId, force: force, output: output)
        case "lock":
            guard args.count > 1 else {
                output(GitStyle.fg(GitStyle.errorColor, "error: worktree name or path required\r\n"))
                return 1
            }
            return try lockWorktree(repo: repo, nameOrPath: args[1], output: output)
        case "unlock":
            guard args.count > 1 else {
                output(GitStyle.fg(GitStyle.errorColor, "error: worktree name or path required\r\n"))
                return 1
            }
            return try unlockWorktree(repo: repo, nameOrPath: args[1], output: output)
        default:
            output(GitStyle.fg(GitStyle.errorColor, "error: unknown worktree subcommand '\(sub)'\r\n"))
            return 1
        }
    }

    // MARK: - Lookup by name or path

    private static func lookupWorktree(repo: OpaquePointer, nameOrPath: String) -> OpaquePointer? {
        // Try by name first
        var wt: OpaquePointer?
        if git_worktree_lookup(&wt, repo, nameOrPath) == 0 {
            return wt
        }

        // Try matching by path
        var strarray = git_strarray()
        guard git_worktree_list(&strarray, repo) == 0 else { return nil }
        defer { git_strarray_dispose(&strarray) }

        let normalizedInput = (nameOrPath as NSString).standardizingPath

        for i in 0..<strarray.count {
            guard let namePtr = strarray.strings[i] else { continue }
            let name = String(cString: namePtr)

            var candidate: OpaquePointer?
            guard git_worktree_lookup(&candidate, repo, name) == 0, let candidate else { continue }

            if let pathPtr = git_worktree_path(candidate) {
                let path = (String(cString: pathPtr) as NSString).standardizingPath
                if path == normalizedInput {
                    return candidate
                }
            }

            git_worktree_free(candidate)
        }

        return nil
    }

    // MARK: - List

    private static func listWorktrees(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var strarray = git_strarray()
        try lg2Check(git_worktree_list(&strarray, repo), "failed to list worktrees")
        defer { git_strarray_dispose(&strarray) }

        var out = GitOutput(write: output)

        // Show main worktree first
        if let workdir = git_repository_workdir(repo) {
            let path = String(cString: workdir)
            var headOid = git_oid()
            var headBranch = ""
            var headRef: OpaquePointer?
            if git_repository_head(&headRef, repo) == 0, let headRef {
                defer { git_reference_free(headRef) }
                git_reference_name_to_id(&headOid, repo, git_reference_name(headRef))
                if git_reference_is_branch(headRef) != 0 {
                    headBranch = git_reference_shorthand(headRef).map { String(cString: $0) } ?? ""
                }
            }
            let shortHash = oidShortString(&headOid)
            out.raw(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            out.raw("  \(GitStyle.fg(GitStyle.hash, shortHash))")
            if !headBranch.isEmpty {
                out.raw("  [\(GitStyle.fg(GitStyle.branch, headBranch))]")
            }
            out.line()
        }

        // Show linked worktrees
        for i in 0..<strarray.count {
            guard let namePtr = strarray.strings[i] else { continue }
            let name = String(cString: namePtr)

            var wt: OpaquePointer?
            guard git_worktree_lookup(&wt, repo, name) == 0, let wt else { continue }
            defer { git_worktree_free(wt) }

            let path = git_worktree_path(wt).map { String(cString: $0) } ?? name
            let isLocked = git_worktree_is_locked(nil, wt) != 0

            out.raw(path)
            if isLocked {
                out.raw("  \(GitStyle.fg(GitStyle.warning, "[locked]"))")
            }
            out.line()
        }

        out.flush()
        return 0
    }

    // MARK: - Add

    private static func addWorktree(repo: OpaquePointer, args: [String], output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let path = args.first else {
            output(GitStyle.fg(GitStyle.errorColor, "error: path required\r\n"))
            return 1
        }

        let branch = args.count > 1 ? args[1] : nil

        var wtOpts = git_worktree_add_options()
        git_worktree_add_options_init(&wtOpts, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))

        // If branch specified, look it up or create it from HEAD
        var ref: OpaquePointer?
        var createdBranch = false
        if let branch {
            let refName = "refs/heads/\(branch)"
            if git_reference_lookup(&ref, repo, refName) == 0 {
                wtOpts.ref = ref
            } else {
                // Branch doesn't exist — create it from HEAD
                var headRef: OpaquePointer?
                guard git_repository_head(&headRef, repo) == 0, let headRef else {
                    output(GitStyle.fg(GitStyle.errorColor, "fatal: not a valid object name: 'HEAD'\r\n"))
                    return 128
                }
                defer { git_reference_free(headRef) }

                var headOid = git_oid()
                git_reference_name_to_id(&headOid, repo, git_reference_name(headRef))

                var headCommit: OpaquePointer?
                guard git_commit_lookup(&headCommit, repo, &headOid) == 0, let headCommit else {
                    output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to resolve HEAD commit\r\n"))
                    return 128
                }
                defer { git_commit_free(headCommit) }

                var newRef: OpaquePointer?
                let createResult = git_branch_create(&newRef, repo, branch, headCommit, 0)
                guard createResult == 0, let newRef else {
                    output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot create branch '\(branch)'\r\n"))
                    return 128
                }
                ref = newRef
                wtOpts.ref = ref
                createdBranch = true
            }
        }
        defer { if let ref { git_reference_free(ref) } }

        // Derive worktree name from path
        let name = (path as NSString).lastPathComponent

        var wt: OpaquePointer?
        let addResult = git_worktree_add(&wt, repo, name, path, &wtOpts)
        if addResult != 0 {
            // Clean up the branch we created if worktree add failed
            if createdBranch, let ref {
                git_branch_delete(ref)
            }
            try lg2Check(addResult, "failed to add worktree")
        }
        if let wt { git_worktree_free(wt) }

        output("Preparing worktree (new branch '\(branch ?? name)')\r\n")
        output("HEAD is now at \(path)\r\n")
        return 0
    }

    // MARK: - Remove

    private static func removeWorktree(repo: OpaquePointer, nameOrPath: String, force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let wt = lookupWorktree(repo: repo, nameOrPath: nameOrPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: '\(nameOrPath)' is not a working tree\r\n"))
            return 128
        }
        defer { git_worktree_free(wt) }

        if git_worktree_is_locked(nil, wt) != 0 {
            let wtName = git_worktree_name(wt).map { String(cString: $0) } ?? nameOrPath
            output(GitStyle.fg(GitStyle.errorColor, "error: worktree '\(wtName)' is locked\r\n"))
            return 1
        }

        // Check for uncommitted changes unless --force
        if !force, let wtPath = git_worktree_path(wt) {
            let path = String(cString: wtPath)
            var wtRepo: OpaquePointer?
            if git_repository_open(&wtRepo, path) == 0, let wtRepo {
                defer { git_repository_free(wtRepo) }

                var statusOpts = git_status_options()
                git_status_options_init(&statusOpts, UInt32(GIT_STATUS_OPTIONS_VERSION))
                statusOpts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
                statusOpts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue

                var statusList: OpaquePointer?
                if git_status_list_new(&statusList, wtRepo, &statusOpts) == 0, let statusList {
                    defer { git_status_list_free(statusList) }
                    if git_status_list_entrycount(statusList) > 0 {
                        output(GitStyle.fg(GitStyle.errorColor, "error: '\(nameOrPath)' contains modified or untracked files, use --force to delete\r\n"))
                        return 1
                    }
                }
            }
        }

        var pruneOpts = git_worktree_prune_options()
        git_worktree_prune_options_init(&pruneOpts, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
        pruneOpts.flags = GIT_WORKTREE_PRUNE_VALID.rawValue | GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue

        try lg2Check(git_worktree_prune(wt, &pruneOpts), "failed to remove worktree '\(nameOrPath)'")

        let wtName = git_worktree_name(wt).map { String(cString: $0) } ?? nameOrPath
        output("Removed worktree '\(wtName)'\r\n")
        return 0
    }

    // MARK: - Lock

    private static func lockWorktree(repo: OpaquePointer, nameOrPath: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let wt = lookupWorktree(repo: repo, nameOrPath: nameOrPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: '\(nameOrPath)' is not a working tree\r\n"))
            return 128
        }
        defer { git_worktree_free(wt) }

        try lg2Check(git_worktree_lock(wt, nil), "failed to lock worktree '\(nameOrPath)'")
        let wtName = git_worktree_name(wt).map { String(cString: $0) } ?? nameOrPath
        output("Locked worktree '\(wtName)'\r\n")
        return 0
    }

    // MARK: - Unlock

    private static func unlockWorktree(repo: OpaquePointer, nameOrPath: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let wt = lookupWorktree(repo: repo, nameOrPath: nameOrPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: '\(nameOrPath)' is not a working tree\r\n"))
            return 128
        }
        defer { git_worktree_free(wt) }

        try lg2Check(git_worktree_unlock(wt), "failed to unlock worktree '\(nameOrPath)'")
        let wtName = git_worktree_name(wt).map { String(cString: $0) } ?? nameOrPath
        output("Unlocked worktree '\(wtName)'\r\n")
        return 0
    }
}

#endif
