#if !targetEnvironment(macCatalyst)

import Foundation

/// `git merge [<options>] <branch>` — merge a branch.
enum GitMerge: GitSubcommand {
    static var helpText: String {
        "usage: git merge [<options>] <branch>\r\n\r\n    Join two or more development histories together\r\n\r\nOptions:\r\n    --no-commit          Perform the merge but don't create a commit\r\n    --no-ff              Create a merge commit even if fast-forward\r\n    --ff-only            Fail if not fast-forwardable\r\n    --squash             Squash commits into working tree\r\n    -m <msg>             Custom merge message\r\n    -X ours              Favor our side on conflicts\r\n    -X theirs            Favor their side on conflicts\r\n    --continue           Continue after conflict resolution\r\n    --abort              Abort the current merge operation\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var noCommit = false
        var noFF = false
        var ffOnly = false
        var squash = false
        var customMessage: String?
        var fileFavor: git_merge_file_favor_t = GIT_MERGE_FILE_FAVOR_NORMAL
        var branchName: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--no-commit": noCommit = true
            case "--no-ff": noFF = true
            case "--ff-only": ffOnly = true
            case "--squash": squash = true
            case "-m":
                if i + 1 < args.count {
                    customMessage = args[i + 1]
                    i += 1
                }
            case "-X":
                if i + 1 < args.count {
                    switch args[i + 1] {
                    case "ours": fileFavor = GIT_MERGE_FILE_FAVOR_OURS
                    case "theirs": fileFavor = GIT_MERGE_FILE_FAVOR_THEIRS
                    default: break
                    }
                    i += 1
                }
            case "--abort":
                return try abortMerge(repo: repo, output: output)
            case "--continue":
                return try continueMerge(repo: repo, output: output)
            default:
                if !args[i].hasPrefix("-") {
                    branchName = args[i]
                }
            }
            i += 1
        }

        guard let branchName else {
            output("usage: git merge [--no-commit] [--no-ff] [--ff-only] [--squash] [-m <msg>] <branch>\r\n")
            return 1
        }

        // Resolve branch to annotated commit
        var annotatedCommit: OpaquePointer?
        annotatedCommit = try resolveToAnnotatedCommit(repo: repo, name: branchName)

        guard let annotatedCommit else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: '\(branchName)' does not point to a commit\r\n"))
            return 1
        }
        defer { git_annotated_commit_free(annotatedCommit) }

        // Perform merge analysis
        var preference = GIT_MERGE_PREFERENCE_NONE
        var analysis = GIT_MERGE_ANALYSIS_NONE

        var theirHeads: OpaquePointer? = annotatedCommit
        try withUnsafeMutablePointer(to: &theirHeads) { ptr in
            try lg2Check(
                git_merge_analysis(&analysis, &preference, repo, ptr, 1),
                "failed to analyze merge"
            )
        }

        // Already up to date
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            output("Already up to date.\r\n")
            return 0
        }

        // Fast-forward
        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            if noFF {
                // Force merge commit even though FF is possible
                return try normalMerge(repo: repo, annotatedCommit: annotatedCommit,
                                        branchName: branchName, noCommit: noCommit, squash: squash,
                                        customMessage: customMessage, fileFavor: fileFavor, output: output)
            }
            return try fastForward(repo: repo, annotatedCommit: annotatedCommit, branchName: branchName, output: output)
        }

        // Normal merge
        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            if ffOnly {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not possible to fast-forward, aborting.\r\n"))
                return 128
            }
            return try normalMerge(repo: repo, annotatedCommit: annotatedCommit,
                                    branchName: branchName, noCommit: noCommit, squash: squash,
                                    customMessage: customMessage, fileFavor: fileFavor, output: output)
        }

        output(GitStyle.fg(GitStyle.errorColor, "fatal: merge analysis returned unexpected result\r\n"))
        return 1
    }

    // MARK: - Resolve ref

    private static func resolveToAnnotatedCommit(repo: OpaquePointer, name: String) throws -> OpaquePointer? {
        var annotatedCommit: OpaquePointer?

        // Try as branch ref first
        var ref: OpaquePointer?
        let fullRef = "refs/heads/\(name)"
        if git_reference_lookup(&ref, repo, fullRef) == 0, let ref {
            defer { git_reference_free(ref) }
            var refOid = git_oid()
            if git_reference_name_to_id(&refOid, repo, fullRef) == 0 {
                try lg2Check(
                    git_annotated_commit_lookup(&annotatedCommit, repo, &refOid),
                    "failed to lookup commit for '\(name)'"
                )
                return annotatedCommit
            }
        }

        // Try as remote tracking branch
        let remoteRef = "refs/remotes/origin/\(name)"
        if git_reference_lookup(&ref, repo, remoteRef) == 0, let ref {
            defer { git_reference_free(ref) }
            var refOid = git_oid()
            if git_reference_name_to_id(&refOid, repo, remoteRef) == 0 {
                try lg2Check(
                    git_annotated_commit_lookup(&annotatedCommit, repo, &refOid),
                    "failed to lookup commit for '\(name)'"
                )
                return annotatedCommit
            }
        }

        // Try as arbitrary revision
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, name), "failed to resolve '\(name)'")
        guard let obj else { return nil }
        defer { git_object_free(obj) }

        let oid = git_object_id(obj)!
        var mutableOid = oid.pointee
        try lg2Check(
            git_annotated_commit_lookup(&annotatedCommit, repo, &mutableOid),
            "failed to lookup annotated commit"
        )
        return annotatedCommit
    }

    // MARK: - Fast-forward merge

    private static func fastForward(repo: OpaquePointer, annotatedCommit: OpaquePointer, branchName: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let targetOid = git_annotated_commit_id(annotatedCommit)!

        // Get current HEAD for display
        var headOid = git_oid()
        git_reference_name_to_id(&headOid, repo, "HEAD")
        let oldHash = oidShortString(&headOid)

        var mutableTargetOid = targetOid.pointee
        let newHash = oidShortString(&mutableTargetOid)

        // Checkout the target tree
        var targetCommit: OpaquePointer?
        try lg2Check(git_commit_lookup(&targetCommit, repo, targetOid), "failed to lookup commit")
        guard let targetCommit else { return 1 }
        defer { git_commit_free(targetCommit) }

        var tree: OpaquePointer?
        try lg2Check(git_commit_tree(&tree, targetCommit), "failed to get tree")
        guard let tree else { return 1 }
        defer { git_tree_free(tree) }

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try lg2Check(git_checkout_tree(repo, tree, &checkoutOpts), "failed to checkout")

        // Update HEAD
        var headRef: OpaquePointer?
        if git_repository_head(&headRef, repo) == 0, let headRef {
            defer { git_reference_free(headRef) }
            var newRef: OpaquePointer?
            var oid = targetOid.pointee
            try lg2Check(
                git_reference_set_target(&newRef, headRef, &oid, "merge: fast-forward"),
                "failed to update HEAD"
            )
            if let newRef { git_reference_free(newRef) }
        }

        output("Fast-forward\r\n")
        output("  \(GitStyle.fg(GitStyle.hash, oldHash))..\(GitStyle.fg(GitStyle.hash, newHash))\r\n")
        return 0
    }

    // MARK: - Normal merge

    private static func normalMerge(repo: OpaquePointer, annotatedCommit: OpaquePointer, branchName: String, noCommit: Bool, squash: Bool, customMessage: String?, fileFavor: git_merge_file_favor_t, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Perform merge
        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION))
        mergeOpts.file_favor = fileFavor

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue

        var theirHeads: OpaquePointer? = annotatedCommit
        let result = withUnsafeMutablePointer(to: &theirHeads) { ptr -> Int32 in
            return git_merge(repo, ptr, 1, &mergeOpts, &checkoutOpts)
        }

        try lg2Check(result, "merge failed")

        // Check for conflicts
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            output(GitStyle.fg(GitStyle.warning, "Merge conflict(s) detected:\r\n"))

            // List conflicted files
            var conflictIter: OpaquePointer?
            if git_index_conflict_iterator_new(&conflictIter, index) == 0, let conflictIter {
                defer { git_index_conflict_iterator_free(conflictIter) }

                var ancestor: UnsafePointer<git_index_entry>?
                var ours: UnsafePointer<git_index_entry>?
                var theirs: UnsafePointer<git_index_entry>?

                while git_index_conflict_next(&ancestor, &ours, &theirs, conflictIter) == 0 {
                    let path: String
                    if let ours, let p = ours.pointee.path {
                        path = String(cString: p)
                    } else if let theirs, let p = theirs.pointee.path {
                        path = String(cString: p)
                    } else {
                        path = "(unknown)"
                    }
                    output("  \(GitStyle.fg(GitStyle.errorColor, "\(GitStyle.conflictIcon) \(path)"))\r\n")
                }
            }

            output("\r\nFix conflicts and then commit the result.\r\n")
            return 1
        }

        if squash {
            output("Squash commit -- not updating HEAD\r\n")
            git_repository_state_cleanup(repo)
            return 0
        }

        if noCommit {
            output("Automatic merge went well; stopped before committing as requested\r\n")
            return 0
        }

        // Create merge commit
        return try createMergeCommit(repo: repo, index: index, annotatedCommit: annotatedCommit,
                                      branchName: branchName, customMessage: customMessage, output: output)
    }

    // MARK: - Create merge commit

    private static func createMergeCommit(repo: OpaquePointer, index: OpaquePointer, annotatedCommit: OpaquePointer, branchName: String, customMessage: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
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

        // Get both parent commits
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else { return 1 }
        defer { git_reference_free(headRef) }

        var headCommit: OpaquePointer?
        var headOid = git_oid()
        git_reference_name_to_id(&headOid, repo, git_reference_name(headRef))
        git_commit_lookup(&headCommit, repo, &headOid)
        guard let headCommit else { return 1 }
        defer { git_commit_free(headCommit) }

        let theirOid = git_annotated_commit_id(annotatedCommit)!
        var theirCommit: OpaquePointer?
        git_commit_lookup(&theirCommit, repo, theirOid)
        guard let theirCommit else { return 1 }
        defer { git_commit_free(theirCommit) }

        let mergeMessage = customMessage ?? "Merge branch '\(branchName)'"
        var commitOid = git_oid()

        // Create commit with two parents
        var parents: [OpaquePointer?] = [headCommit, theirCommit]

        let commitResult = parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &commitOid, repo, "HEAD",
                sig, sig,
                nil, mergeMessage,
                tree,
                2, buf.baseAddress
            )
        }

        try lg2Check(commitResult, "failed to create merge commit")

        // Clean up merge state
        git_repository_state_cleanup(repo)

        let shortHash = oidShortString(&commitOid)
        output("Merge made by the 'ort' strategy.\r\n")
        output("  \(GitStyle.fg(GitStyle.hash, shortHash)) \(mergeMessage)\r\n")

        return 0
    }

    // MARK: - Continue merge

    private static func continueMerge(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_MERGE.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no merge in progress\r\n"))
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

        var headOid = git_oid()
        git_reference_name_to_id(&headOid, repo, git_reference_name(headRef))
        var headCommit: OpaquePointer?
        git_commit_lookup(&headCommit, repo, &headOid)
        guard let headCommit else { return 1 }
        defer { git_commit_free(headCommit) }

        // Read MERGE_HEAD
        var mergeOid = git_oid()
        try lg2Check(
            git_reference_name_to_id(&mergeOid, repo, "MERGE_HEAD"),
            "failed to read MERGE_HEAD"
        )
        var mergeCommit: OpaquePointer?
        git_commit_lookup(&mergeCommit, repo, &mergeOid)
        guard let mergeCommit else { return 1 }
        defer { git_commit_free(mergeCommit) }

        var commitOid = git_oid()
        var parents: [OpaquePointer?] = [headCommit, mergeCommit]

        // Read prepared merge message from .git/MERGE_MSG
        let message: String
        let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
        let mergeMsgPath = gitDir + "MERGE_MSG"
        if let msgData = FileManager.default.contents(atPath: mergeMsgPath),
           let msg = String(data: msgData, encoding: .utf8),
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = "Merge commit"
        }

        let commitResult = parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &commitOid, repo, "HEAD",
                sig, sig, nil, message,
                tree, 2, buf.baseAddress
            )
        }
        try lg2Check(commitResult, "failed to create merge commit")

        git_repository_state_cleanup(repo)

        let shortHash = oidShortString(&commitOid)
        output("[\(GitStyle.fg(GitStyle.hash, shortHash))] \(message)\r\n")
        return 0
    }

    // MARK: - Abort merge

    private static func abortMerge(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_MERGE.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no merge in progress\r\n"))
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

        // Clean up merge state
        git_repository_state_cleanup(repo)

        output("Merge aborted.\r\n")
        return 0
    }
}

#endif
