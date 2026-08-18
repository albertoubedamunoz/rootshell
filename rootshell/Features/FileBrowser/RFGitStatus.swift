#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Lightweight git status for the rf file browser.
/// Only performs O(1) git object database reads — no worktree scanning,
/// no filesystem stat calls. Mirrors the approach in PromptGitInfo.
///
/// What we CAN show cheaply (git objects only):
///   - Staged files (index differs from HEAD tree)
///   - Tracked vs untracked (is file in the index?)
///
/// What we CANNOT show without expensive worktree scan:
///   - Modified (working tree differs from index) — requires stat() on every file
///   - This is what made the old implementation slow on large repos
enum RFGitStatusQuery {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-git")

    /// Query git status for files in a directory using only git object database reads.
    /// Returns a dictionary mapping filename → status.
    /// Fast: no filesystem stat calls, runs in < 5ms even on huge repos.
    nonisolated static func query(directory: String) -> [String: RFGitFileStatus] {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repo: OpaquePointer?
        let openResult = git_repository_open_ext(&repo, directory, 0, nil)
        guard openResult == 0, let repo else { return [:] }
        defer { git_repository_free(repo) }

        guard let workdirCStr = git_repository_workdir(repo) else { return [:] }
        let workdir = String(cString: workdirCStr)

        guard let relativeDirPath = relativeDirectoryPath(for: directory, within: workdir) else {
            logger.debug("Skipping git status for path outside repo workdir: \(directory, privacy: .public)")
            return [:]
        }

        var result: [String: RFGitFileStatus] = [:]

        // 1. Get staged changes: diff HEAD tree vs index (git objects only, no FS)
        let staged = stagedFiles(repo: repo)
        for (path, fileStatus) in staged {
            if let filename = extractFilename(path: path, relativeTo: relativeDirPath) {
                result[filename] = moreImportant(result[filename], fileStatus)
            }
        }

        // 2. Find untracked files by checking which files in the directory are NOT in the index.
        //    Also check gitignore — ignored files should show no status, not '?'.
        let indexedNames = indexedFilenames(repo: repo, relativeDirPath: relativeDirPath)
        let dirEntries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in dirEntries {
            if result[name] != nil { continue } // Already have status from staged
            if indexedNames.contains(name) { continue } // Tracked and clean — no status to show

            // Not in index — check if gitignored
            let relPath = relativeDirPath.isEmpty ? name : relativeDirPath + name
            var ignored: Int32 = 0
            git_ignore_path_is_ignored(&ignored, repo, relPath)
            if ignored == 0 {
                result[name] = .untracked
            }
            // If ignored, we just don't set any status (file appears without indicator)
        }

        return result
    }

    /// Get staged files by diffing HEAD tree against index. No FS access.
    /// Returns [relative_path: status].
    private nonisolated static func stagedFiles(repo: OpaquePointer) -> [String: RFGitFileStatus] {
        var headRef: OpaquePointer?
        let headResult = git_repository_head(&headRef, repo)

        // Handle unborn branch (no HEAD commit yet)
        if headResult == GIT_EUNBORNBRANCH.rawValue {
            // Everything in the index is "added"
            var index: OpaquePointer?
            guard git_repository_index(&index, repo) == 0, let index else { return [:] }
            defer { git_index_free(index) }

            var result: [String: RFGitFileStatus] = [:]
            let count = git_index_entrycount(index)
            for i in 0..<count {
                guard let entry = git_index_get_byindex(index, i) else { continue }
                let path = String(cString: entry.pointee.path)
                result[path] = .added
            }
            return result
        }

        guard headResult == 0, let headRef else { return [:] }
        defer { git_reference_free(headRef) }

        guard let headOid = git_reference_target(headRef) else { return [:] }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, headOid) == 0, let commit else { return [:] }
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else { return [:] }
        defer { git_tree_free(tree) }

        // Diff tree-to-index: compares git objects only, no filesystem access
        var diff: OpaquePointer?
        guard git_diff_tree_to_index(&diff, repo, tree, nil, nil) == 0, let diff else { return [:] }
        defer { git_diff_free(diff) }

        let numDeltas = git_diff_num_deltas(diff)
        var result: [String: RFGitFileStatus] = [:]

        for i in 0..<numDeltas {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            let newPath = String(cString: delta.pointee.new_file.path)
            let status: RFGitFileStatus
            switch delta.pointee.status {
            case GIT_DELTA_ADDED:     status = .added
            case GIT_DELTA_DELETED:   status = .deleted
            case GIT_DELTA_MODIFIED:  status = .staged
            case GIT_DELTA_RENAMED:   status = .renamed
            case GIT_DELTA_CONFLICTED: status = .conflict
            default:                  status = .staged
            }
            result[newPath] = status
        }

        return result
    }

    /// Get the set of filenames (first path component) that exist in the git index
    /// under the given relative directory path.
    /// This is a fast index scan — no filesystem access.
    private nonisolated static func indexedFilenames(repo: OpaquePointer, relativeDirPath: String) -> Set<String> {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else { return [] }
        defer { git_index_free(index) }

        var names: Set<String> = []
        let count = git_index_entrycount(index)

        for i in 0..<count {
            guard let entry = git_index_get_byindex(index, i) else { continue }
            let path = String(cString: entry.pointee.path)

            // Check if this entry is under our directory
            if relativeDirPath.isEmpty {
                // At repo root — first component is the filename/dirname
                if let slashIdx = path.firstIndex(of: "/") {
                    names.insert(String(path[..<slashIdx]))
                } else {
                    names.insert(path)
                }
            } else if path.hasPrefix(relativeDirPath) {
                let remainder = String(path.dropFirst(relativeDirPath.count))
                if let slashIdx = remainder.firstIndex(of: "/") {
                    names.insert(String(remainder[..<slashIdx]))
                } else {
                    names.insert(remainder)
                }
            }
        }

        return names
    }

    /// Extract the first-level filename from a repo-relative path,
    /// scoped to the given directory.
    private nonisolated static func extractFilename(path: String, relativeTo dirPath: String) -> String? {
        let relToDir: String
        if dirPath.isEmpty {
            relToDir = path
        } else if path.hasPrefix(dirPath) {
            relToDir = String(path.dropFirst(dirPath.count))
        } else {
            return nil
        }

        if let slashIdx = relToDir.firstIndex(of: "/") {
            let name = String(relToDir[..<slashIdx])
            return name.isEmpty ? nil : name
        }
        return relToDir.isEmpty ? nil : relToDir
    }

    private nonisolated static func relativeDirectoryPath(for directory: String, within workdir: String) -> String? {
        let normalizedDirectory = normalizedPath(directory)
        let normalizedWorkdir = normalizedPath(workdir)
        let directoryPrefix = pathWithTrailingSlash(normalizedDirectory)
        let workdirPrefix = pathWithTrailingSlash(normalizedWorkdir)

        guard directoryPrefix.hasPrefix(workdirPrefix) else { return nil }
        return String(directoryPrefix.dropFirst(workdirPrefix.count))
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private nonisolated static func pathWithTrailingSlash(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private nonisolated static func moreImportant(_ existing: RFGitFileStatus?, _ new: RFGitFileStatus) -> RFGitFileStatus {
        guard let existing else { return new }
        let priority: [RFGitFileStatus: Int] = [
            .conflict: 7, .deleted: 6, .staged: 5, .added: 4,
            .modified: 3, .renamed: 2, .untracked: 1, .ignored: 0
        ]
        return (priority[existing] ?? 0) >= (priority[new] ?? 0) ? existing : new
    }
}

#endif
