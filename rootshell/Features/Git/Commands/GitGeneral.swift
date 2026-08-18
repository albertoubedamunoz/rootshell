#if !targetEnvironment(macCatalyst)

import Foundation

/// `git general` — show libgit2 info and repo status for debugging.
enum GitGeneral: GitSubcommand {
    static var helpText: String {
        "usage: git general\r\n\r\n    Show libgit2 version info and repository diagnostics\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        // libgit2 version
        let major = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        let minor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        let rev = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { major.deallocate(); minor.deallocate(); rev.deallocate() }

        git_libgit2_version(major, minor, rev)

        out.line(GitStyle.boldFg(GitStyle.info, "libgit2 Information"))
        out.line()
        out.line("  Version: \(GitStyle.fg(GitStyle.hash, "\(major.pointee).\(minor.pointee).\(rev.pointee)"))")

        // Compiled features
        let features = git_libgit2_features()

        let hasThreads = (features & Int32(GIT_FEATURE_THREADS.rawValue)) != 0
        let hasHTTPS = (features & Int32(GIT_FEATURE_HTTPS.rawValue)) != 0
        let hasNsec = (features & Int32(GIT_FEATURE_NSEC.rawValue)) != 0

        out.line()
        out.line(GitStyle.boldFg(GitStyle.info, "Compiled Features"))
        out.line()
        out.line("  Threads:  \(featureIndicator(hasThreads))")
        out.line("  HTTPS:    \(featureIndicator(hasHTTPS))")
        out.line("  SSH:      \(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) enabled"))")
        out.line("  Nanosec:  \(featureIndicator(hasNsec))")

        // Repository info (if available)
        out.line()
        out.line(GitStyle.boldFg(GitStyle.info, "Repository"))
        out.line()

        guard let repo else {
            out.line("  \(GitStyle.fg(GitStyle.dimColor, "Not in a git repository"))")
            out.flush()
            return 0
        }

        // Repo path
        if let path = git_repository_path(repo) {
            var gitDir = String(cString: path)
            if gitDir.hasSuffix("/") { gitDir = String(gitDir.dropLast()) }
            out.line("  Git dir:  \(GitStyle.fg(GitStyle.dimColor, gitDir))")
        }

        // Work tree
        if let workdir = git_repository_workdir(repo) {
            var workDir = String(cString: workdir)
            if workDir.hasSuffix("/") { workDir = String(workDir.dropLast()) }
            out.line("  Workdir:  \(GitStyle.fg(GitStyle.dimColor, workDir))")
        }

        // Bare?
        let bare = git_repository_is_bare(repo) != 0
        out.line("  Bare:     \(bare ? GitStyle.fg(GitStyle.warning, "yes") : GitStyle.fg(GitStyle.dimColor, "no"))")

        // HEAD info
        var headRef: OpaquePointer?
        let headResult = git_repository_head(&headRef, repo)

        if headResult == GIT_EUNBORNBRANCH.rawValue {
            out.line("  HEAD:     \(GitStyle.fg(GitStyle.warning, "(unborn)"))")
        } else if headResult == 0, let headRef {
            defer { git_reference_free(headRef) }

            if git_reference_is_branch(headRef) != 0 {
                let branchName = git_reference_shorthand(headRef).map { String(cString: $0) } ?? "unknown"
                out.line("  HEAD:     \(GitStyle.fg(GitStyle.branch, "\(GitStyle.branchIcon) \(branchName)"))")
            } else {
                var oid = git_oid()
                if git_reference_name_to_id(&oid, repo, "HEAD") == 0 {
                    let shortHash = oidShortString(&oid)
                    out.line("  HEAD:     \(GitStyle.fg(GitStyle.hash, "\(GitStyle.starIcon) \(shortHash)")) \(GitStyle.fg(GitStyle.dimColor, "(detached)"))")
                }
            }

            // Show HEAD commit info
            var headOid = git_oid()
            if git_reference_name_to_id(&headOid, repo, "HEAD") == 0 {
                var commit: OpaquePointer?
                if git_commit_lookup(&commit, repo, &headOid) == 0, let commit {
                    defer { git_commit_free(commit) }

                    let message = git_commit_message(commit).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let firstLine = message.components(separatedBy: "\n").first ?? message
                    let truncated = firstLine.count > 60 ? String(firstLine.prefix(57)) + "..." : firstLine
                    out.line("  Commit:   \(GitStyle.fg(GitStyle.dimColor, truncated))")

                    if let sig = git_commit_author(commit) {
                        let name = sig.pointee.name.map { String(cString: $0) } ?? ""
                        let time = sig.pointee.when.time
                        let relTime = GitLog.relativeTime(from: time)
                        out.line("  Author:   \(GitStyle.fg(GitStyle.author, name)) \(GitStyle.fg(GitStyle.dimColor, "(\(relTime))"))")
                    }
                }
            }
        } else {
            out.line("  HEAD:     \(GitStyle.fg(GitStyle.errorColor, "(error reading HEAD)"))")
        }

        // Count local branches
        var branchCount = 0
        var branchIter: OpaquePointer?
        if git_branch_iterator_new(&branchIter, repo, GIT_BRANCH_LOCAL) == 0, let branchIter {
            defer { git_branch_iterator_free(branchIter) }
            var ref: OpaquePointer?
            var btype = GIT_BRANCH_LOCAL
            while git_branch_next(&ref, &btype, branchIter) == 0, let ref {
                git_reference_free(ref)
                branchCount += 1
            }
        }
        out.line("  Branches: \(GitStyle.fg(GitStyle.dimColor, "\(branchCount)"))")

        // Count remotes
        var remoteList = git_strarray()
        if git_remote_list(&remoteList, repo) == 0 {
            let remoteCount = remoteList.count
            git_strarray_dispose(&remoteList)
            out.line("  Remotes:  \(GitStyle.fg(GitStyle.dimColor, "\(remoteCount)"))")
        }

        // Count tags
        var tagList = git_strarray()
        if git_tag_list(&tagList, repo) == 0 {
            let tagCount = tagList.count
            git_strarray_dispose(&tagList)
            out.line("  Tags:     \(GitStyle.fg(GitStyle.dimColor, "\(tagCount)"))")
        }

        out.line()
        out.flush()
        return 0
    }

    // MARK: - Helpers

    private static func featureIndicator(_ enabled: Bool) -> String {
        if enabled {
            return GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) enabled")
        } else {
            return GitStyle.fg(GitStyle.dimColor, "\(GitStyle.crossIcon) disabled")
        }
    }
}

#endif
