#if !targetEnvironment(macCatalyst)

import Foundation

/// `git branch` — list, create, or delete branches.
enum GitBranch: GitSubcommand {
    static var helpText: String {
        "usage: git branch [<options>] [<branch-name>]\r\n\r\n    List, create, or delete branches\r\n\r\nOptions:\r\n    -d, --delete           Delete a branch\r\n    -D                     Force delete a branch\r\n    -m, --move             Rename a branch\r\n    -a, --all              List both local and remote branches\r\n    -r, --remotes          List remote-tracking branches\r\n    -v, --verbose          Show hash and subject for each branch\r\n    -vv                    Show tracking and ahead/behind\r\n    --show-current         Print current branch name\r\n    -u, --set-upstream-to  Set tracking branch\r\n    --unset-upstream       Remove tracking branch\r\n    --merged [<commit>]    List branches merged into HEAD\r\n    --no-merged [<commit>] List branches not merged into HEAD\r\n    --sort=<key>           Sort by committerdate, authordate, refname\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var delete = false
        var forceDelete = false
        var rename = false
        var showAll = false
        var showRemotes = false
        var verbose = false
        var doubleVerbose = false
        var showCurrent = false
        var setUpstreamTo: String?
        var unsetUpstream = false
        var mergedFilter: Bool?
        var mergedRef: String?
        var sortKey: String?
        var positional: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-d", "--delete": delete = true
            case "-D": forceDelete = true; delete = true
            case "-m", "--move": rename = true
            case "-a", "--all": showAll = true
            case "-r", "--remotes": showRemotes = true
            case "-v", "--verbose": verbose = true
            case "-vv": verbose = true; doubleVerbose = true
            case "--show-current": showCurrent = true
            case "-u", "--set-upstream-to":
                if i + 1 < args.count {
                    setUpstreamTo = args[i + 1]
                    i += 1
                }
            case "--unset-upstream": unsetUpstream = true
            case "--merged":
                mergedFilter = true
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    mergedRef = args[i + 1]
                    i += 1
                }
            case "--no-merged":
                mergedFilter = false
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    mergedRef = args[i + 1]
                    i += 1
                }
            default:
                if args[i].hasPrefix("--set-upstream-to=") {
                    setUpstreamTo = String(args[i].dropFirst(18))
                } else if args[i].hasPrefix("--sort=") {
                    sortKey = String(args[i].dropFirst(7))
                } else if !args[i].hasPrefix("-") {
                    positional.append(args[i])
                }
            }
            i += 1
        }

        if showCurrent {
            return try showCurrentBranch(repo: repo, output: output)
        }

        if let upstream = setUpstreamTo {
            let branch = positional.first
            return try setUpstream(repo: repo, branchName: branch, upstream: upstream, output: output)
        }

        if unsetUpstream {
            let branch = positional.first
            return try clearUpstream(repo: repo, branchName: branch, output: output)
        }

        if delete {
            return try deleteBranch(repo: repo, names: positional, force: forceDelete, output: output)
        }

        if rename {
            return try renameBranch(repo: repo, names: positional, output: output)
        }

        if !positional.isEmpty && mergedFilter == nil {
            return try createBranch(repo: repo, name: positional[0],
                                    startPoint: positional.count > 1 ? positional[1] : nil,
                                    output: output)
        }

        // List branches
        return try listBranches(repo: repo, showAll: showAll, showRemotes: showRemotes,
                                verbose: verbose, doubleVerbose: doubleVerbose,
                                mergedFilter: mergedFilter, mergedRef: mergedRef,
                                sortKey: sortKey, output: output)
    }

    // MARK: - Show current

    private static func showCurrentBranch(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var headRef: OpaquePointer?
        if git_repository_head(&headRef, repo) == 0, let headRef {
            defer { git_reference_free(headRef) }
            if git_reference_is_branch(headRef) != 0 {
                let name = git_reference_shorthand(headRef).map { String(cString: $0) } ?? ""
                output("\(name)\r\n")
            }
            // Detached HEAD — print nothing (matches git behavior)
        }
        return 0
    }

    // MARK: - Set upstream

    private static func setUpstream(repo: OpaquePointer, branchName: String?, upstream: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let name: String
        if let branchName {
            name = branchName
        } else {
            var headRef: OpaquePointer?
            guard git_repository_head(&headRef, repo) == 0, let headRef else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not on any branch\r\n"))
                return 128
            }
            defer { git_reference_free(headRef) }
            name = git_reference_shorthand(headRef).map { String(cString: $0) } ?? ""
        }

        var ref: OpaquePointer?
        try lg2Check(git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL), "branch '\(name)' not found")
        guard let ref else { return 1 }
        defer { git_reference_free(ref) }

        try lg2Check(git_branch_set_upstream(ref, upstream), "failed to set upstream to '\(upstream)'")
        output("Branch '\(GitStyle.fg(GitStyle.branch, name))' set up to track '\(GitStyle.fg(GitStyle.remote, upstream))'\r\n")
        return 0
    }

    // MARK: - Unset upstream

    private static func clearUpstream(repo: OpaquePointer, branchName: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let name: String
        if let branchName {
            name = branchName
        } else {
            var headRef: OpaquePointer?
            guard git_repository_head(&headRef, repo) == 0, let headRef else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not on any branch\r\n"))
                return 128
            }
            defer { git_reference_free(headRef) }
            name = git_reference_shorthand(headRef).map { String(cString: $0) } ?? ""
        }

        var ref: OpaquePointer?
        try lg2Check(git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL), "branch '\(name)' not found")
        guard let ref else { return 1 }
        defer { git_reference_free(ref) }

        try lg2Check(git_branch_set_upstream(ref, nil), "failed to unset upstream")
        output("Branch '\(GitStyle.fg(GitStyle.branch, name))' no longer tracks a remote branch\r\n")
        return 0
    }

    // MARK: - List

    private static func listBranches(repo: OpaquePointer, showAll: Bool, showRemotes: Bool, verbose: Bool, doubleVerbose: Bool, mergedFilter: Bool?, mergedRef: String?, sortKey: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let filter: git_branch_t
        if showAll {
            filter = git_branch_t(rawValue: GIT_BRANCH_LOCAL.rawValue | GIT_BRANCH_REMOTE.rawValue)
        } else if showRemotes {
            filter = GIT_BRANCH_REMOTE
        } else {
            filter = GIT_BRANCH_LOCAL
        }

        var iter: OpaquePointer?
        try lg2Check(git_branch_iterator_new(&iter, repo, filter), "failed to create branch iterator")
        guard let iter else { return 1 }
        defer { git_branch_iterator_free(iter) }

        // Get current branch for highlighting
        var headRef: OpaquePointer?
        let currentBranch: String?
        if git_repository_head(&headRef, repo) == 0, let headRef {
            currentBranch = git_reference_shorthand(headRef).map { String(cString: $0) }
            git_reference_free(headRef)
        } else {
            currentBranch = nil
        }

        // Resolve merge filter base
        var mergeBaseOid = git_oid()
        var hasMergeBase = false
        if mergedFilter != nil {
            let baseRef = mergedRef ?? "HEAD"
            var obj: OpaquePointer?
            let parseResult = git_revparse_single(&obj, repo, baseRef)
            if parseResult != 0 {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not a valid object name: '\(baseRef)'\r\n"))
                return 128
            }
            guard let obj else { return 1 }
            defer { git_object_free(obj) }
            if let oid = git_object_id(obj) {
                mergeBaseOid = oid.pointee
                hasMergeBase = true
            }
        }

        struct BranchInfo {
            let name: String
            let isRemote: Bool
            let isCurrent: Bool
            let oid: git_oid
            let commitTime: git_time_t
            let commitMessage: String
        }

        var branches: [BranchInfo] = []
        var ref: OpaquePointer?
        var btype = GIT_BRANCH_LOCAL

        while git_branch_next(&ref, &btype, iter) == 0, let ref {
            defer { git_reference_free(ref) }

            guard let namePtr = git_reference_shorthand(ref) else { continue }
            let name = String(cString: namePtr)
            let isRemote = btype == GIT_BRANCH_REMOTE
            let isCurrent = !isRemote && name == currentBranch

            var oid = git_oid()
            guard git_reference_name_to_id(&oid, repo, git_reference_name(ref)) == 0 else { continue }

            // Apply merged/no-merged filter
            if let wantMerged = mergedFilter, hasMergeBase {
                let isMerged = git_oid_equal(&oid, &mergeBaseOid) != 0 ||
                    git_graph_descendant_of(repo, &mergeBaseOid, &oid) == 1
                if wantMerged && !isMerged { continue }
                if !wantMerged && isMerged { continue }
            }

            var commitTime: git_time_t = 0
            var commitMessage = ""
            var commit: OpaquePointer?
            if git_commit_lookup(&commit, repo, &oid) == 0, let commit {
                let sig = git_commit_author(commit)
                commitTime = sig?.pointee.when.time ?? 0
                commitMessage = git_commit_message(commit).map { String(cString: $0) }?
                    .components(separatedBy: "\n").first ?? ""
                git_commit_free(commit)
            }

            branches.append(BranchInfo(name: name, isRemote: isRemote, isCurrent: isCurrent,
                                        oid: oid, commitTime: commitTime, commitMessage: commitMessage))
        }

        // Sort
        if let sortKey {
            switch sortKey {
            case "committerdate", "authordate":
                branches.sort { $0.commitTime > $1.commitTime }
            case "-committerdate", "-authordate":
                branches.sort { $0.commitTime < $1.commitTime }
            case "refname":
                branches.sort { $0.name < $1.name }
            case "-refname":
                branches.sort { $0.name > $1.name }
            default:
                break
            }
        }

        var out = GitOutput(write: output)

        for branch in branches {
            var line = ""
            if branch.isCurrent {
                line += GitStyle.fg(GitStyle.success, "* ")
                line += GitStyle.fg(GitStyle.branch, branch.name)
            } else {
                line += "  "
                if branch.isRemote {
                    line += GitStyle.fg(GitStyle.remote, branch.name)
                } else {
                    line += branch.name
                }
            }

            if verbose {
                var oid = branch.oid
                let shortHash = oidShortString(&oid)
                line += " \(GitStyle.fg(GitStyle.hash, shortHash))"

                if doubleVerbose && !branch.isRemote {
                    // Show tracking info
                    var localRef: OpaquePointer?
                    if git_branch_lookup(&localRef, repo, branch.name, GIT_BRANCH_LOCAL) == 0, let localRef {
                        defer { git_reference_free(localRef) }
                        var upstreamRef: OpaquePointer?
                        if git_branch_upstream(&upstreamRef, localRef) == 0, let upstreamRef {
                            defer { git_reference_free(upstreamRef) }
                            let upstreamName = git_reference_shorthand(upstreamRef).map { String(cString: $0) } ?? ""

                            var upstreamOid = git_oid()
                            if git_reference_name_to_id(&upstreamOid, repo, git_reference_name(upstreamRef)) == 0 {
                                var ahead: Int = 0
                                var behind: Int = 0
                                git_graph_ahead_behind(&ahead, &behind, repo, &oid, &upstreamOid)

                                var tracking = "[\(GitStyle.fg(GitStyle.remote, upstreamName))"
                                if ahead > 0 && behind > 0 {
                                    tracking += ": ahead \(ahead), behind \(behind)"
                                } else if ahead > 0 {
                                    tracking += ": ahead \(ahead)"
                                } else if behind > 0 {
                                    tracking += ": behind \(behind)"
                                }
                                tracking += "]"
                                line += " \(tracking)"
                            }
                        }
                    }
                }

                let truncated = branch.commitMessage.count > 50
                    ? String(branch.commitMessage.prefix(47)) + "..."
                    : branch.commitMessage
                line += " \(truncated)"
            }

            out.line(line)
        }

        out.flush()
        return 0
    }

    // MARK: - Create

    private static func createBranch(repo: OpaquePointer, name: String, startPoint: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Resolve start point (default: HEAD)
        var targetCommit: OpaquePointer?

        if let startPoint {
            var obj: OpaquePointer?
            try lg2Check(git_revparse_single(&obj, repo, startPoint), "invalid start point '\(startPoint)'")
            guard let obj else { return 1 }
            defer { git_object_free(obj) }

            try lg2Check(git_commit_lookup(&targetCommit, repo, git_object_id(obj)), "failed to lookup commit")
        } else {
            var headRef: OpaquePointer?
            try lg2Check(git_repository_head(&headRef, repo), "HEAD not found")
            guard let headRef else { return 1 }
            defer { git_reference_free(headRef) }

            var oid = git_oid()
            try lg2Check(git_reference_name_to_id(&oid, repo, git_reference_name(headRef)), "failed to resolve HEAD")
            try lg2Check(git_commit_lookup(&targetCommit, repo, &oid), "failed to lookup HEAD commit")
        }

        guard let targetCommit else { return 1 }
        defer { git_commit_free(targetCommit) }

        var newRef: OpaquePointer?
        let result = git_branch_create(&newRef, repo, name, targetCommit, 0)
        if result < 0 {
            let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
            output(GitStyle.fg(GitStyle.errorColor, "fatal: \(err)\r\n"))
            return 128
        }
        if let newRef { git_reference_free(newRef) }

        return 0
    }

    // MARK: - Delete

    private static func deleteBranch(repo: OpaquePointer, names: [String], force: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard !names.isEmpty else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: branch name required\r\n"))
            return 128
        }

        for name in names {
            var ref: OpaquePointer?
            let lookupResult = git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL)
            if lookupResult != 0 {
                output(GitStyle.fg(GitStyle.errorColor, "error: branch '\(name)' not found\r\n"))
                return 1
            }
            guard let ref else { continue }
            defer { git_reference_free(ref) }

            // Check if it's the current branch
            if git_branch_is_head(ref) != 0 {
                output(GitStyle.fg(GitStyle.errorColor, "error: Cannot delete branch '\(name)' checked out at current HEAD\r\n"))
                return 1
            }

            // Check if fully merged (unless force delete)
            if !force {
                var branchOid = git_oid()
                try lg2Check(
                    git_reference_name_to_id(&branchOid, repo, git_reference_name(ref)),
                    "failed to resolve branch '\(name)'"
                )

                var headOid = git_oid()
                try lg2Check(
                    git_reference_name_to_id(&headOid, repo, "HEAD"),
                    "failed to resolve HEAD"
                )

                let isMerged = git_oid_equal(&branchOid, &headOid) != 0 ||
                    git_graph_descendant_of(repo, &headOid, &branchOid) == 1

                if !isMerged {
                    output(GitStyle.fg(GitStyle.errorColor, "error: branch '\(name)' is not fully merged\r\n"))
                    output("hint: use -D to delete anyway\r\n")
                    return 1
                }
            }

            let deleteResult = git_branch_delete(ref)
            if deleteResult < 0 {
                let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
                output(GitStyle.fg(GitStyle.errorColor, "error: failed to delete branch '\(name)': \(err)\r\n"))
                return 1
            }

            output("Deleted branch \(GitStyle.fg(GitStyle.branch, name))\r\n")
        }

        return 0
    }

    // MARK: - Rename

    private static func renameBranch(repo: OpaquePointer, names: [String], output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let oldName: String
        let newName: String

        if names.count == 1 {
            // Rename current branch
            var headRef: OpaquePointer?
            guard git_repository_head(&headRef, repo) == 0, let headRef else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not on any branch\r\n"))
                return 128
            }
            defer { git_reference_free(headRef) }

            guard let shorthand = git_reference_shorthand(headRef) else { return 1 }
            oldName = String(cString: shorthand)
            newName = names[0]
        } else if names.count >= 2 {
            oldName = names[0]
            newName = names[1]
        } else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: branch name required\r\n"))
            return 128
        }

        var ref: OpaquePointer?
        try lg2Check(git_branch_lookup(&ref, repo, oldName, GIT_BRANCH_LOCAL), "branch '\(oldName)' not found")
        guard let ref else { return 1 }
        defer { git_reference_free(ref) }

        var newRef: OpaquePointer?
        try lg2Check(git_branch_move(&newRef, ref, newName, 0), "failed to rename branch")
        if let newRef { git_reference_free(newRef) }

        return 0
    }
}

#endif
