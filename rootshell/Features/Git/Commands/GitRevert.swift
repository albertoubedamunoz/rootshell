#if !targetEnvironment(macCatalyst)

import Foundation

/// `git revert` — create a new commit that undoes a previous commit.
enum GitRevert: GitSubcommand {
    static var helpText: String {
        "usage: git revert [<options>] <commit>...\r\n\r\n    Revert some existing commits\r\n\r\nOptions:\r\n    -n, --no-commit      Apply changes to working tree without creating a commit\r\n    -m, --mainline <n>   Select parent for merge commits (1 or 2)\r\n    --continue           Continue after conflict resolution\r\n    --abort              Abort the current revert\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var noCommit = false
        var mainline: UInt32 = 0
        var revision: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-n", "--no-commit": noCommit = true
            case "--continue":
                return try continueRevert(repo: repo, output: output)
            case "--abort":
                return try abortRevert(repo: repo, output: output)
            case "-m", "--mainline":
                if i + 1 < args.count, let n = UInt32(args[i + 1]) {
                    mainline = n
                    i += 1
                }
            default:
                if args[i].hasPrefix("--mainline="), let n = UInt32(String(args[i].dropFirst(11))) {
                    mainline = n
                } else if !args[i].hasPrefix("-") && revision == nil {
                    revision = args[i]
                }
            }
            i += 1
        }

        guard let revision else {
            output(GitStyle.fg(GitStyle.errorColor, "usage: git revert [--no-commit] [-m <n>] <commit>\r\n"))
            return 1
        }

        // Resolve the commit to revert
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, revision), "unknown revision '\(revision)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        var commit: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit, repo, git_object_id(obj)), "not a commit")
        guard let commit else { return 1 }
        defer { git_commit_free(commit) }

        // Check if this is a merge commit and mainline is needed
        let parentCount = git_commit_parentcount(commit)
        if parentCount > 1 && mainline == 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: commit \(revision) is a merge but no -m option was given\r\n"))
            return 1
        }

        // Perform the revert (applies inverse changes to index and workdir)
        var revertOpts = git_revert_options()
        git_revert_options_init(&revertOpts, UInt32(GIT_REVERT_OPTIONS_VERSION))
        revertOpts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        revertOpts.mainline = mainline

        try lg2Check(git_revert(repo, commit, &revertOpts), "failed to revert commit")

        // Check for conflicts
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            output(GitStyle.fg(GitStyle.warning, "Revert conflict(s) detected.\r\n"))
            output("After resolving the conflicts, use \"git revert --continue\".\r\n")
            output("To abort: \"git revert --abort\"\r\n")
            return 1
        }

        let shortHash = oidShortString(UnsafeMutablePointer(mutating: git_commit_id(commit)))
        let commitMsg = git_commit_message(commit).map { String(cString: $0) }?
            .components(separatedBy: "\n").first ?? ""

        if noCommit {
            output("Reverted \(GitStyle.fg(GitStyle.hash, shortHash)) (\(commitMsg)) — changes staged but not committed\r\n")
            // Remove REVERT_HEAD but preserve MERGE_MSG for a potential later commit
            let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
            try? FileManager.default.removeItem(atPath: gitDir + "REVERT_HEAD")
            return 0
        }

        // Auto-commit the revert
        let revertMessage = "Revert \"\(commitMsg)\"\n\nThis reverts commit \(oidString(UnsafeMutablePointer(mutating: git_commit_id(commit))))."

        // Write tree from index
        var treeOid = git_oid()
        try lg2Check(git_index_write_tree(&treeOid, index), "failed to write tree")

        var tree: OpaquePointer?
        try lg2Check(git_tree_lookup(&tree, repo, &treeOid), "failed to lookup tree")
        guard let tree else { return 1 }
        defer { git_tree_free(tree) }

        // Get signature
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        guard let sig else { return 1 }
        defer { git_signature_free(sig) }

        // Get HEAD commit as parent
        var headRef: OpaquePointer?
        var parentCommit: OpaquePointer?
        if git_repository_head(&headRef, repo) == 0, let headRef {
            defer { git_reference_free(headRef) }
            var parentOid = git_oid()
            if git_reference_name_to_id(&parentOid, repo, git_reference_name(headRef)) == 0 {
                git_commit_lookup(&parentCommit, repo, &parentOid)
            }
        }
        defer { if let parentCommit { git_commit_free(parentCommit) } }

        // Create commit
        var commitOid = git_oid()
        var parents: [OpaquePointer?] = parentCommit != nil ? [parentCommit] : []

        let result: Int32
        if parents.isEmpty {
            result = git_commit_create(
                &commitOid, repo, "HEAD",
                sig, sig, nil, revertMessage,
                tree, 0, nil
            )
        } else {
            result = parents.withUnsafeMutableBufferPointer { buf in
                git_commit_create(
                    &commitOid, repo, "HEAD",
                    sig, sig, nil, revertMessage,
                    tree, 1, buf.baseAddress
                )
            }
        }
        try lg2Check(result, "failed to create revert commit")
        try lg2Check(git_repository_state_cleanup(repo), "failed to clean up revert state")

        let newShortHash = oidShortString(&commitOid)
        output("[\(GitStyle.fg(GitStyle.hash, newShortHash))] Revert \"\(commitMsg)\"\r\n")

        return 0
    }

    // MARK: - Continue revert

    private static func continueRevert(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_REVERT.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no revert in progress\r\n"))
            return 1
        }

        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: unresolved conflicts remain\r\n"))
            return 1
        }

        // Write tree
        var treeOid = git_oid()
        try lg2Check(git_index_write_tree(&treeOid, index), "failed to write tree")
        try lg2Check(git_index_write(index), "failed to write index")

        var tree: OpaquePointer?
        try lg2Check(git_tree_lookup(&tree, repo, &treeOid), "failed to lookup tree")
        guard let tree else { return 1 }
        defer { git_tree_free(tree) }

        // Get signature
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        guard let sig else { return 1 }
        defer { git_signature_free(sig) }

        // Get HEAD as parent
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else { return 1 }
        defer { git_reference_free(headRef) }

        var parentOid = git_oid()
        git_reference_name_to_id(&parentOid, repo, git_reference_name(headRef))
        var parentCommit: OpaquePointer?
        git_commit_lookup(&parentCommit, repo, &parentOid)
        guard let parentCommit else { return 1 }
        defer { git_commit_free(parentCommit) }

        var commitOid = git_oid()
        var parents: [OpaquePointer?] = [parentCommit]

        // Read prepared message from MERGE_MSG (preserves conflict annotations, user edits)
        let message: String
        let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
        let mergeMsgPath = gitDir + "MERGE_MSG"
        if let msgData = FileManager.default.contents(atPath: mergeMsgPath),
           let msg = String(data: msgData, encoding: .utf8),
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Fall back to reconstructing from REVERT_HEAD
            var revertHeadOid = git_oid()
            if git_reference_name_to_id(&revertHeadOid, repo, "REVERT_HEAD") == 0 {
                var revertCommit: OpaquePointer?
                if git_commit_lookup(&revertCommit, repo, &revertHeadOid) == 0, let revertCommit {
                    defer { git_commit_free(revertCommit) }
                    let commitMsg = git_commit_message(revertCommit).map { String(cString: $0) }?
                        .components(separatedBy: "\n").first ?? ""
                    let fullHash = oidString(UnsafeMutablePointer(mutating: git_commit_id(revertCommit)))
                    message = "Revert \"\(commitMsg)\"\n\nThis reverts commit \(fullHash)."
                } else {
                    message = "Revert commit"
                }
            } else {
                message = "Revert commit"
            }
        }

        let commitResult = parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &commitOid, repo, "HEAD",
                sig, sig, nil, message,
                tree, 1, buf.baseAddress
            )
        }
        try lg2Check(commitResult, "failed to create commit")

        git_repository_state_cleanup(repo)

        let shortHash = oidShortString(&commitOid)
        output("[\(GitStyle.fg(GitStyle.hash, shortHash))] \(message)\r\n")
        return 0
    }

    // MARK: - Abort revert

    private static func abortRevert(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_REVERT.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no revert in progress\r\n"))
            return 1
        }

        // Reset to HEAD
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to resolve HEAD\r\n"))
            return 128
        }
        defer { git_reference_free(headRef) }

        var headCommit: OpaquePointer?
        try lg2Check(git_reference_peel(&headCommit, headRef, GIT_OBJECT_COMMIT), "failed to peel HEAD")
        guard let headCommit else { return 1 }
        defer { git_object_free(headCommit) }

        // Reset index to HEAD tree
        var headCommitObj: OpaquePointer?
        git_commit_lookup(&headCommitObj, repo, git_object_id(headCommit))
        if let headCommitObj {
            defer { git_commit_free(headCommitObj) }
            var headTree: OpaquePointer?
            if git_commit_tree(&headTree, headCommitObj) == 0, let headTree {
                defer { git_tree_free(headTree) }
                var index: OpaquePointer?
                if git_repository_index(&index, repo) == 0, let index {
                    defer { git_index_free(index) }
                    git_index_read_tree(index, headTree)
                    git_index_write(index)
                }
            }
        }

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue

        try lg2Check(git_checkout_tree(repo, headCommit, &checkoutOpts), "failed to checkout HEAD")

        git_repository_state_cleanup(repo)
        output("Revert aborted.\r\n")
        return 0
    }

    private static func oidString(_ oid: UnsafeMutablePointer<git_oid>) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
        defer { buf.deallocate() }
        git_oid_tostr(buf, 41, oid)
        return String(cString: buf)
    }
}

#endif
