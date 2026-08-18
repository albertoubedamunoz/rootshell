#if !targetEnvironment(macCatalyst)

import Foundation

/// `git cherry-pick <commit>` — apply changes from an existing commit.
enum GitCherryPick: GitSubcommand {
    static var helpText: String {
        "usage: git cherry-pick [<options>] <commit>\r\n\r\n    Apply the changes introduced by some existing commits\r\n\r\nOptions:\r\n    -n, --no-commit      Apply changes without committing\r\n    -x                   Append \"(cherry picked from commit ...)\" to message\r\n    -m, --mainline <n>   Select parent number for merge commits\r\n    --continue           Continue after conflict resolution\r\n    --abort              Abort the current cherry-pick\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var noCommit = false
        var appendPickedFrom = false
        var mainline: UInt32 = 0
        var revision: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-n", "--no-commit":
                noCommit = true
            case "-x":
                appendPickedFrom = true
            case "-m", "--mainline":
                if i + 1 < args.count, let n = UInt32(args[i + 1]) {
                    mainline = n
                    i += 1
                }
            case "--continue":
                return try continueCherryPick(repo: repo, output: output)
            case "--abort":
                return try abortCherryPick(repo: repo, output: output)
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
            output(GitStyle.fg(GitStyle.errorColor, "usage: git cherry-pick <commit>\r\n"))
            return 1
        }

        // Resolve the commit
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, revision), "unknown revision '\(revision)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        var commit: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit, repo, git_object_id(obj)), "not a commit: '\(revision)'")
        guard let commit else { return 1 }
        defer { git_commit_free(commit) }

        // Check if this is a merge commit and mainline is needed
        let parentCount = git_commit_parentcount(commit)
        if parentCount > 1 && mainline == 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: commit \(revision) is a merge but no -m option was given\r\n"))
            return 1
        }

        // Set up cherry-pick options
        var cherrypickOpts = git_cherrypick_options()
        git_cherrypick_options_init(&cherrypickOpts, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION))
        cherrypickOpts.mainline = mainline

        // Perform cherry-pick
        let result = git_cherrypick(repo, commit, &cherrypickOpts)
        try lg2Check(result, "failed to cherry-pick commit")

        // Check for conflicts
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            // If -x was requested, append the trailer to MERGE_MSG so --continue preserves it
            if appendPickedFrom {
                let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
                let mergeMsgPath = gitDir + "MERGE_MSG"
                if let msgData = FileManager.default.contents(atPath: mergeMsgPath),
                   var msg = String(data: msgData, encoding: .utf8) {
                    let commitId = git_commit_id(commit)!
                    let fullHash = oidFullString(UnsafeMutablePointer(mutating: commitId))
                    let trailer = "\n(cherry picked from commit \(fullHash))"
                    if !msg.contains(trailer) {
                        msg += trailer + "\n"
                        try? msg.write(toFile: mergeMsgPath, atomically: true, encoding: .utf8)
                    }
                }
            }

            output(GitStyle.fg(GitStyle.warning, "Cherry-pick conflict(s) detected:\r\n"))
            listConflicts(index: index, output: output)
            output("\r\nAfter resolving the conflicts, use \"git cherry-pick --continue\".\r\n")
            output("To abort: \"git cherry-pick --abort\"\r\n")
            return 1
        }

        let commitId = git_commit_id(commit)!
        let shortHash = oidShortString(commitId)
        let commitMsg = git_commit_message(commit).map { String(cString: $0) }?
            .components(separatedBy: "\n").first ?? ""

        if noCommit {
            output("Cherry-picked \(GitStyle.fg(GitStyle.hash, shortHash)) — changes staged but not committed\r\n")
            // Remove CHERRY_PICK_HEAD but preserve MERGE_MSG for a potential later commit
            let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
            try? FileManager.default.removeItem(atPath: gitDir + "CHERRY_PICK_HEAD")
            return 0
        }

        // Build commit message
        var message = git_commit_message(commit).map { String(cString: $0) } ?? commitMsg
        if appendPickedFrom {
            let fullHash = oidFullString(UnsafeMutablePointer(mutating: commitId))
            message += "\n\n(cherry picked from commit \(fullHash))"
        }

        // Write tree from index
        var treeOid = git_oid()
        try lg2Check(git_index_write_tree(&treeOid, index), "failed to write tree")
        try lg2Check(git_index_write(index), "failed to write index")

        var tree: OpaquePointer?
        try lg2Check(git_tree_lookup(&tree, repo, &treeOid), "failed to lookup tree")
        guard let tree else { return 1 }
        defer { git_tree_free(tree) }

        // Get signature — prefer commit's original author
        let origSig = git_commit_author(commit)
        var sig: UnsafeMutablePointer<git_signature>?
        if let origSig {
            let name = origSig.pointee.name.map { String(cString: $0) } ?? "User"
            let email = origSig.pointee.email.map { String(cString: $0) } ?? "user@localhost"
            git_signature_now(&sig, name, email)
        }
        if sig == nil {
            if git_signature_default(&sig, repo) != 0 {
                git_signature_now(&sig, "User", "user@localhost")
            }
        }
        guard let sig else { return 1 }
        defer { git_signature_free(sig) }

        // Committer is current user
        var committerSig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&committerSig, repo) != 0 {
            git_signature_now(&committerSig, "User", "user@localhost")
        }
        guard let committerSig else { return 1 }
        defer { git_signature_free(committerSig) }

        // Get HEAD as parent
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

        var newOid = git_oid()
        var parents: [OpaquePointer?] = parentCommit != nil ? [parentCommit] : []

        let commitResult: Int32
        if parents.isEmpty {
            commitResult = git_commit_create(
                &newOid, repo, "HEAD",
                sig, committerSig, nil, message,
                tree, 0, nil
            )
        } else {
            commitResult = parents.withUnsafeMutableBufferPointer { buf in
                git_commit_create(
                    &newOid, repo, "HEAD",
                    sig, committerSig, nil, message,
                    tree, 1, buf.baseAddress
                )
            }
        }
        try lg2Check(commitResult, "failed to create cherry-pick commit")

        git_repository_state_cleanup(repo)

        let newShortHash = oidShortString(&newOid)
        output("[\(GitStyle.fg(GitStyle.hash, newShortHash))] \(commitMsg)\r\n")
        return 0
    }

    // MARK: - Continue cherry-pick

    private static func continueCherryPick(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_CHERRYPICK.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no cherry-pick in progress\r\n"))
            return 1
        }

        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { return 1 }
        defer { git_index_free(index) }

        if git_index_has_conflicts(index) != 0 {
            output(GitStyle.fg(GitStyle.errorColor, "error: unresolved conflicts remain\r\n"))
            listConflicts(index: index, output: output)
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

        // Get committer signature (current user)
        var committerSig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&committerSig, repo) != 0 {
            git_signature_now(&committerSig, "User", "user@localhost")
        }
        guard let committerSig else { return 1 }
        defer { git_signature_free(committerSig) }

        // Read prepared message and resolve original author from CHERRY_PICK_HEAD
        let message: String
        var authorSig: UnsafeMutablePointer<git_signature>?

        let gitDir = git_repository_path(repo).map { String(cString: $0) } ?? ""
        let mergeMsgPath = gitDir + "MERGE_MSG"

        var cherrypickOid = git_oid()
        let hasCherryPickHead = git_reference_name_to_id(&cherrypickOid, repo, "CHERRY_PICK_HEAD") == 0

        // Preserve original author from the cherry-picked commit
        if hasCherryPickHead {
            var cherrypickCommit: OpaquePointer?
            if git_commit_lookup(&cherrypickCommit, repo, &cherrypickOid) == 0, let cherrypickCommit {
                defer { git_commit_free(cherrypickCommit) }
                if let origAuthor = git_commit_author(cherrypickCommit) {
                    let name = origAuthor.pointee.name.map { String(cString: $0) } ?? "User"
                    let email = origAuthor.pointee.email.map { String(cString: $0) } ?? "user@localhost"
                    git_signature_now(&authorSig, name, email)
                }

                // Read message from MERGE_MSG first, fall back to original commit message
                if let msgData = FileManager.default.contents(atPath: mergeMsgPath),
                   let msg = String(data: msgData, encoding: .utf8),
                   !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    message = git_commit_message(cherrypickCommit).map { String(cString: $0) } ?? "cherry-pick"
                }
            } else {
                message = "cherry-pick"
            }
        } else if let msgData = FileManager.default.contents(atPath: mergeMsgPath),
                  let msg = String(data: msgData, encoding: .utf8),
                  !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = "cherry-pick"
        }

        // Fall back to committer as author if we couldn't resolve the original
        if authorSig == nil {
            if git_signature_default(&authorSig, repo) != 0 {
                git_signature_now(&authorSig, "User", "user@localhost")
            }
        }
        guard let authorSig else { return 1 }
        defer { git_signature_free(authorSig) }

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

        var newOid = git_oid()
        var parents: [OpaquePointer?] = [parentCommit]
        let commitResult = parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &newOid, repo, "HEAD",
                authorSig, committerSig, nil, message,
                tree, 1, buf.baseAddress
            )
        }
        try lg2Check(commitResult, "failed to create commit")

        git_repository_state_cleanup(repo)

        let shortHash = oidShortString(&newOid)
        let firstLine = message.components(separatedBy: "\n").first ?? message
        output("[\(GitStyle.fg(GitStyle.hash, shortHash))] \(firstLine)\r\n")
        return 0
    }

    // MARK: - Abort cherry-pick

    private static func abortCherryPick(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let state = git_repository_state(repo)
        guard state == GIT_REPOSITORY_STATE_CHERRYPICK.rawValue else {
            output(GitStyle.fg(GitStyle.errorColor, "error: no cherry-pick in progress\r\n"))
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

        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue

        try lg2Check(git_checkout_tree(repo, headCommit, &checkoutOpts), "failed to checkout HEAD")

        // Reset index
        var headObjAsCommit: OpaquePointer?
        git_commit_lookup(&headObjAsCommit, repo, git_object_id(headCommit))
        if let headObjAsCommit {
            defer { git_commit_free(headObjAsCommit) }
            var index: OpaquePointer?
            if git_repository_index(&index, repo) == 0, let index {
                defer { git_index_free(index) }
                var headTree: OpaquePointer?
                if git_commit_tree(&headTree, headObjAsCommit) == 0, let headTree {
                    defer { git_tree_free(headTree) }
                    git_index_read_tree(index, headTree)
                    git_index_write(index)
                }
            }
        }

        git_repository_state_cleanup(repo)
        output("Cherry-pick aborted.\r\n")
        return 0
    }

    // MARK: - Helpers

    private static func listConflicts(index: OpaquePointer, output: @escaping @Sendable (String) -> Void) {
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
    }
}

#endif
