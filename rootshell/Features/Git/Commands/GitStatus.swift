#if !targetEnvironment(macCatalyst)

import Foundation

/// `git status` — shows working tree status with styled output.
enum GitStatus: GitSubcommand {
    static var helpText: String {
        "usage: git status [<options>]\r\n\r\n    Show the working tree status\r\n\r\nOptions:\r\n    -s, --short          Give output in short format\r\n    --porcelain          Give output in machine-readable format\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var short = false
        var porcelain = false
        for arg in args {
            switch arg {
            case "-s", "--short": short = true
            case "--porcelain": porcelain = true
            default: break
            }
        }

        if porcelain {
            return try runPorcelain(repo: repo, output: output)
        }

        if short {
            return try runShort(repo: repo, output: output)
        }

        return try runLong(repo: repo, output: output)
    }

    // MARK: - Long format (default)

    private static func runLong(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        // Branch info
        try writeBranchHeader(repo: repo, output: &out)

        // Status entries
        var opts = makeStatusOptions()
        var statusList: OpaquePointer?
        try lg2Check(git_status_list_new(&statusList, repo, &opts), "failed to get status")
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)

        var staged: [(String, String, GitStyle.Color)] = []
        var unstaged: [(String, String, GitStyle.Color)] = []
        var untracked: [String] = []

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let status = entry.pointee.status

            // Index (staged) changes
            if status.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.head_to_index)
                staged.append(("\(GitStyle.addedIcon) new file:", path, GitStyle.added))
            }
            if status.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.head_to_index)
                staged.append(("\(GitStyle.modifiedIcon) modified:", path, GitStyle.modified))
            }
            if status.rawValue & GIT_STATUS_INDEX_DELETED.rawValue != 0 {
                let path = diffDeltaOldPath(entry.pointee.head_to_index)
                staged.append(("\(GitStyle.deletedIcon) deleted:", path, GitStyle.deleted))
            }
            if status.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue != 0 {
                let oldPath = diffDeltaOldPath(entry.pointee.head_to_index)
                let newPath = diffDeltaNewPath(entry.pointee.head_to_index)
                staged.append(("\(GitStyle.renamedIcon) renamed:", "\(oldPath) -> \(newPath)", GitStyle.renamed))
            }
            if status.rawValue & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.head_to_index)
                staged.append(("\(GitStyle.modifiedIcon) typechange:", path, GitStyle.modified))
            }

            // Worktree (unstaged) changes
            if status.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.index_to_workdir)
                unstaged.append(("\(GitStyle.modifiedIcon) modified:", path, GitStyle.modified))
            }
            if status.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 {
                let path = diffDeltaOldPath(entry.pointee.index_to_workdir)
                unstaged.append(("\(GitStyle.deletedIcon) deleted:", path, GitStyle.deleted))
            }
            if status.rawValue & GIT_STATUS_WT_RENAMED.rawValue != 0 {
                let oldPath = diffDeltaOldPath(entry.pointee.index_to_workdir)
                let newPath = diffDeltaNewPath(entry.pointee.index_to_workdir)
                unstaged.append(("\(GitStyle.renamedIcon) renamed:", "\(oldPath) -> \(newPath)", GitStyle.renamed))
            }
            if status.rawValue & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.index_to_workdir)
                unstaged.append(("\(GitStyle.modifiedIcon) typechange:", path, GitStyle.modified))
            }

            // Untracked
            if status.rawValue & GIT_STATUS_WT_NEW.rawValue != 0 {
                let path = diffDeltaNewPath(entry.pointee.index_to_workdir)
                untracked.append(path)
            }
        }

        // Output sections
        if !staged.isEmpty {
            out.line()
            out.line("  \(GitStyle.bold("Changes to be committed:"))")
            for (label, path, color) in staged {
                out.line("    \(GitStyle.fg(color, label))   \(path)")
            }
        }

        if !unstaged.isEmpty {
            out.line()
            out.line("  \(GitStyle.bold("Changes not staged for commit:"))")
            for (label, path, color) in unstaged {
                out.line("    \(GitStyle.fg(color, label))   \(path)")
            }
        }

        if !untracked.isEmpty {
            out.line()
            out.line("  \(GitStyle.bold("Untracked files:"))")
            for path in untracked {
                out.line("    \(GitStyle.fg(GitStyle.errorColor, GitStyle.untrackedIcon))   \(path)")
            }
        }

        if staged.isEmpty && unstaged.isEmpty && untracked.isEmpty {
            out.line()
            out.line("nothing to commit, working tree clean")
        }

        out.line()
        out.flush()
        return 0
    }

    // MARK: - Short format

    private static func runShort(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)
        var opts = makeStatusOptions()

        var statusList: OpaquePointer?
        try lg2Check(git_status_list_new(&statusList, repo, &opts), "failed to get status")
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let status = entry.pointee.status

            let indexChar = statusChar(forIndex: status)
            let wtChar = statusChar(forWorktree: status)
            let path = entryPath(entry.pointee)

            let indexColor = statusColor(forIndex: status)
            let wtColor = statusColor(forWorktree: status)

            out.raw(GitStyle.fg(indexColor, String(indexChar)))
            out.raw(GitStyle.fg(wtColor, String(wtChar)))
            out.line(" \(path)")
        }

        out.flush()
        return 0
    }

    // MARK: - Porcelain format

    private static func runPorcelain(repo: OpaquePointer, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)
        var opts = makeStatusOptions()

        var statusList: OpaquePointer?
        try lg2Check(git_status_list_new(&statusList, repo, &opts), "failed to get status")
        defer { git_status_list_free(statusList) }

        let count = git_status_list_entrycount(statusList)

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }
            let status = entry.pointee.status

            let indexChar = statusChar(forIndex: status)
            let wtChar = statusChar(forWorktree: status)
            let path = entryPath(entry.pointee)

            out.line("\(indexChar)\(wtChar) \(path)")
        }

        out.flush()
        return 0
    }

    // MARK: - Helpers

    private static func writeBranchHeader(repo: OpaquePointer, output: inout GitOutput) throws {
        var head: OpaquePointer?
        let headResult = git_repository_head(&head, repo)

        if headResult == GIT_EUNBORNBRANCH.rawValue {
            output.line("\(GitStyle.fg(GitStyle.branch, "\(GitStyle.branchIcon) No commits yet"))")
            return
        }

        if headResult == 0, let head {
            defer { git_reference_free(head) }

            if git_reference_is_branch(head) != 0 {
                let name = git_reference_shorthand(head).map { String(cString: $0) } ?? "HEAD"
                output.line("\(GitStyle.fg(GitStyle.branch, "\(GitStyle.branchIcon) \(name)"))")

                // Check ahead/behind upstream
                var upstream: OpaquePointer?
                if git_branch_upstream(&upstream, head) == 0, let upstream {
                    defer { git_reference_free(upstream) }

                    var localOid = git_oid()
                    var upstreamOid = git_oid()

                    if git_reference_name_to_id(&localOid, repo, git_reference_name(head)) == 0 &&
                       git_reference_name_to_id(&upstreamOid, repo, git_reference_name(upstream)) == 0 {
                        var ahead: Int = 0
                        var behind: Int = 0
                        if git_graph_ahead_behind(&ahead, &behind, repo, &localOid, &upstreamOid) == 0 {
                            if ahead > 0 && behind > 0 {
                                output.raw("  \(GitStyle.fg(GitStyle.info, "\(GitStyle.arrowUp)\(ahead) \(GitStyle.arrowDown)\(behind)"))")
                                output.line()
                            } else if ahead > 0 {
                                output.raw("  \(GitStyle.fg(GitStyle.info, "\(GitStyle.arrowUp)\(ahead)"))")
                                output.line()
                            } else if behind > 0 {
                                output.raw("  \(GitStyle.fg(GitStyle.info, "\(GitStyle.arrowDown)\(behind)"))")
                                output.line()
                            }
                        }
                    }
                }
            } else {
                // Detached HEAD
                var oid = git_oid()
                if git_reference_name_to_id(&oid, repo, "HEAD") == 0 {
                    let shortHash = oidShortString(&oid)
                    output.line("\(GitStyle.fg(GitStyle.hash, "\(GitStyle.starIcon) HEAD detached at \(shortHash)"))")
                }
            }
        }
    }

    private static func makeStatusOptions() -> git_status_options {
        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue |
            GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue |
            GIT_STATUS_OPT_SORT_CASE_SENSITIVELY.rawValue |
            GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        return opts
    }

    private static func statusChar(forIndex status: git_status_t) -> Character {
        if status.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0 { return "A" }
        if status.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { return "M" }
        if status.rawValue & GIT_STATUS_INDEX_DELETED.rawValue != 0 { return "D" }
        if status.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { return "R" }
        if status.rawValue & GIT_STATUS_INDEX_TYPECHANGE.rawValue != 0 { return "T" }
        return " "
    }

    private static func statusChar(forWorktree status: git_status_t) -> Character {
        if status.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 { return "M" }
        if status.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 { return "D" }
        if status.rawValue & GIT_STATUS_WT_RENAMED.rawValue != 0 { return "R" }
        if status.rawValue & GIT_STATUS_WT_TYPECHANGE.rawValue != 0 { return "T" }
        if status.rawValue & GIT_STATUS_WT_NEW.rawValue != 0 { return "?" }
        return " "
    }

    private static func statusColor(forIndex status: git_status_t) -> GitStyle.Color {
        if status.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0 { return GitStyle.added }
        if status.rawValue & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { return GitStyle.modified }
        if status.rawValue & GIT_STATUS_INDEX_DELETED.rawValue != 0 { return GitStyle.deleted }
        if status.rawValue & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { return GitStyle.renamed }
        return GitStyle.dimColor
    }

    private static func statusColor(forWorktree status: git_status_t) -> GitStyle.Color {
        if status.rawValue & GIT_STATUS_WT_MODIFIED.rawValue != 0 { return GitStyle.modified }
        if status.rawValue & GIT_STATUS_WT_DELETED.rawValue != 0 { return GitStyle.deleted }
        if status.rawValue & GIT_STATUS_WT_NEW.rawValue != 0 { return GitStyle.errorColor }
        return GitStyle.dimColor
    }

    private static func entryPath(_ entry: git_status_entry) -> String {
        if let delta = entry.index_to_workdir {
            return diffDeltaNewPath(delta)
        }
        if let delta = entry.head_to_index {
            return diffDeltaNewPath(delta)
        }
        return ""
    }
}

// MARK: - Shared helpers for diff deltas and OIDs

func diffDeltaNewPath(_ delta: UnsafePointer<git_diff_delta>?) -> String {
    guard let delta, let path = delta.pointee.new_file.path else { return "" }
    return String(cString: path)
}

func diffDeltaOldPath(_ delta: UnsafePointer<git_diff_delta>?) -> String {
    guard let delta, let path = delta.pointee.old_file.path else { return "" }
    return String(cString: path)
}

func oidShortString(_ oid: UnsafePointer<git_oid>, length: Int = 7) -> String {
    let hexSize = Int(GIT_OID_MAX_HEXSIZE)
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: hexSize + 1)
    defer { buf.deallocate() }
    git_oid_tostr(buf, hexSize + 1, oid)
    let full = String(cString: buf)
    return String(full.prefix(length))
}

func oidFullString(_ oid: UnsafePointer<git_oid>) -> String {
    let hexSize = Int(GIT_OID_MAX_HEXSIZE)
    let buf = UnsafeMutablePointer<Int8>.allocate(capacity: hexSize + 1)
    defer { buf.deallocate() }
    git_oid_tostr(buf, hexSize + 1, oid)
    return String(cString: buf)
}

#endif
