#if !targetEnvironment(macCatalyst)

import Foundation

/// `git pull` — fetch from remote and merge into current branch.
enum GitPull: GitSubcommand {
    static var helpText: String {
        "usage: git pull [<options>] [<remote>]\r\n\r\n    Fetch from and merge with a remote repository\r\n\r\nOptions:\r\n    -p, --prune          Remove remote-tracking refs that no longer exist on the remote\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Step 1: Fetch
        let fetchResult = try GitFetch.run(repo: repo, args: args, cols: cols, output: output)
        if fetchResult != 0 {
            return fetchResult
        }

        // Step 2: Determine upstream branch
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: not on any branch, cannot pull\r\n"))
            return 128
        }
        defer { git_reference_free(headRef) }

        guard let branchNameC = git_reference_shorthand(headRef) else { return 1 }
        let branchName = String(cString: branchNameC)

        guard let mergeSource = mergeTargetFromFetchHead(repo: repo) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: no merge candidates found in FETCH_HEAD\r\n"))
            return 1
        }

        // Step 3: Resolve the remote branch's commit
        var remoteOid = mergeSource.oid

        // Check if we're already up to date
        var headOid = git_oid()
        try lg2Check(git_reference_name_to_id(&headOid, repo, "HEAD"), "failed to resolve HEAD")

        if git_oid_equal(&headOid, &remoteOid) != 0 {
            output("Already up to date.\r\n")
            return 0
        }

        // Step 4: Try fast-forward merge
        var remoteCommit: OpaquePointer?
        try lg2Check(git_commit_lookup(&remoteCommit, repo, &remoteOid), "failed to lookup remote commit")
        guard let remoteCommit else { return 1 }
        defer { git_commit_free(remoteCommit) }

        // Check merge analysis
        var analysis = GIT_MERGE_ANALYSIS_NONE
        var preference = GIT_MERGE_PREFERENCE_NONE
        var annotatedCommit: OpaquePointer?
        try lg2Check(git_annotated_commit_lookup(&annotatedCommit, repo, &remoteOid), "failed to create annotated commit")
        guard let annotatedCommit else { return 1 }
        defer { git_annotated_commit_free(annotatedCommit) }

        var commits: [OpaquePointer?] = [annotatedCommit]
        _ = commits.withUnsafeMutableBufferPointer { buf in
            git_merge_analysis(&analysis, &preference, repo, buf.baseAddress, 1)
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            output("Already up to date.\r\n")
            return 0
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            // Fast-forward
            let shortHash = oidShortString(&headOid)
            let newShortHash = oidShortString(&remoteOid)
            output("Updating \(GitStyle.fg(GitStyle.hash, shortHash))..\(GitStyle.fg(GitStyle.hash, newShortHash))\r\n")
            output("Fast-forward\r\n")

            // Checkout the target tree BEFORE updating HEAD.
            // git_checkout_tree uses HEAD's tree as the baseline for diffing.
            // If HEAD is moved first, baseline == target and no files get updated.
            var remoteTree: OpaquePointer?
            try lg2Check(git_commit_tree(&remoteTree, remoteCommit), "failed to get commit tree")
            guard let remoteTree else { return 1 }
            defer { git_tree_free(remoteTree) }

            var opts = git_checkout_options()
            git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try lg2Check(git_checkout_tree(repo, remoteTree, &opts), "failed to checkout")

            // Update HEAD to point to the remote commit.
            // If this fails, roll back the checkout so the worktree stays
            // consistent with HEAD rather than stranded ahead of it.
            var newRef: OpaquePointer?
            let refResult = git_reference_set_target(&newRef, headRef, &remoteOid, "pull: fast-forward")
            if let newRef { git_reference_free(newRef) }

            if refResult != 0 {
                var headCommit: OpaquePointer?
                git_commit_lookup(&headCommit, repo, &headOid)
                if let headCommit {
                    var oldTree: OpaquePointer?
                    if git_commit_tree(&oldTree, headCommit) == 0, let oldTree {
                        var rollbackOpts = git_checkout_options()
                        git_checkout_options_init(&rollbackOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
                        rollbackOpts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                        git_checkout_tree(repo, oldTree, &rollbackOpts)
                        git_tree_free(oldTree)
                    }
                    git_commit_free(headCommit)
                }
                try lg2Check(refResult, "failed to update HEAD")
            }

            return 0
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 {
            // Normal merge required — delegate to git merge
            let remoteBranchShort = mergeSource.displayName ?? "FETCH_HEAD"
            output("Merging \(GitStyle.fg(GitStyle.branch, remoteBranchShort)) into \(GitStyle.fg(GitStyle.branch, branchName))...\r\n")
            return try GitMerge.run(repo: repo, args: [remoteBranchShort], cols: cols, output: output)
        }

        output(GitStyle.fg(GitStyle.errorColor, "fatal: unable to determine merge strategy\r\n"))
        return 1
    }

    private static func mergeTargetFromFetchHead(repo: OpaquePointer) -> (oid: git_oid, displayName: String?)? {
        let box = FetchHeadSelection()
        let payload = Unmanaged.passUnretained(box).toOpaque()

        let result = git_repository_fetchhead_foreach(repo, { refName, _, oid, isMerge, payload in
            guard let oid, let payload else { return 0 }
            guard isMerge != 0 else { return 0 }

            let selection = Unmanaged<FetchHeadSelection>.fromOpaque(payload).takeUnretainedValue()
            selection.oid = oid.pointee
            if let refName {
                selection.displayName = String(cString: refName)
                    .replacingOccurrences(of: "refs/heads/", with: "")
                    .replacingOccurrences(of: "refs/remotes/", with: "")
            }
            return 1
        }, payload)

        if result == GIT_ENOTFOUND.rawValue {
            return nil
        }

        guard let oid = box.oid else {
            return nil
        }

        return (oid, box.displayName)
    }
}

private final class FetchHeadSelection: @unchecked Sendable {
    var oid: git_oid?
    var displayName: String?
}

#endif
