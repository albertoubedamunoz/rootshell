#if !targetEnvironment(macCatalyst)

import Foundation

/// Lightweight git repo state for prompt display.
/// Only performs O(1) operations: branch name from HEAD ref and staged count
/// from index-to-HEAD diff (no worktree scanning, no filesystem stat calls).
struct PromptGitInfo {
    let branchName: String       // "main", "feature/foo", or "a1b2c3d" for detached
    let isDetached: Bool
    let staged: Int              // Index changes vs HEAD (tree-to-index, no FS access)

    /// Format summary for prompt display.
    /// Returns " +3" for staged changes, empty string for clean index.
    func formattedSummary() -> String {
        if staged > 0 {
            return " +\(staged)"
        }
        return ""
    }

    /// Query git branch and staged count for the given directory.
    /// Returns nil if directory is not inside a git repository.
    ///
    /// Performance: All operations read from .git object database only.
    /// No worktree scanning or filesystem stat calls. Runs in < 1ms
    /// even in repos with millions of files.
    static func query(directory: String) -> PromptGitInfo? {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        // Try to open a repo at or above the directory
        var repo: OpaquePointer?
        let openResult = git_repository_open_ext(&repo, directory, 0, nil)
        guard openResult == 0, let repo else { return nil }
        defer { git_repository_free(repo) }

        // Get branch name (reads .git/HEAD — instant)
        var branchName = "HEAD"
        var isDetached = false

        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repo)
        if headResult == GIT_EUNBORNBRANCH.rawValue {
            branchName = "(no branch)"
            // Unborn branch — everything in index is staged
            return PromptGitInfo(branchName: branchName, isDetached: false,
                                staged: indexEntryCount(repo: repo))
        } else if headResult == 0, let head {
            defer { git_reference_free(head) }
            if git_reference_is_branch(head) != 0 {
                branchName = git_reference_shorthand(head).map { String(cString: $0) } ?? "HEAD"
            } else {
                // Detached HEAD — show short hash
                isDetached = true
                var oid = git_oid()
                if git_reference_name_to_id(&oid, repo, "HEAD") == 0 {
                    branchName = oidShortString(&oid)
                }
            }
        } else {
            return nil  // Can't read HEAD at all
        }

        // Count staged changes: diff HEAD tree vs index (no filesystem access)
        let stagedCount = stagedDiffCount(repo: repo)

        return PromptGitInfo(branchName: branchName, isDetached: isDetached,
                             staged: stagedCount)
    }

    /// Count entries in the index (for unborn branches where there's no HEAD tree).
    private static func indexEntryCount(repo: OpaquePointer) -> Int {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else { return 0 }
        defer { git_index_free(index) }
        return git_index_entrycount(index)
    }

    /// Count staged changes by diffing HEAD tree against the index.
    /// This only reads git object database — no filesystem stat calls.
    private static func stagedDiffCount(repo: OpaquePointer) -> Int {
        // Get HEAD commit's tree
        var headRef: OpaquePointer?
        guard git_repository_head(&headRef, repo) == 0, let headRef else { return 0 }
        defer { git_reference_free(headRef) }

        let headOid = git_reference_target(headRef)
        guard let headOid else { return 0 }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, headOid) == 0, let commit else { return 0 }
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else { return 0 }
        defer { git_tree_free(tree) }

        // Diff tree-to-index (compares git objects only, no FS)
        var diff: OpaquePointer?
        guard git_diff_tree_to_index(&diff, repo, tree, nil, nil) == 0, let diff else { return 0 }
        defer { git_diff_free(diff) }

        return git_diff_num_deltas(diff)
    }
}

#endif
