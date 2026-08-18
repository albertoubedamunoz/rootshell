#if !targetEnvironment(macCatalyst)

import Foundation

/// `git rm` — remove files from the working tree and index.
enum GitRm: GitSubcommand {
    static var helpText: String {
        "usage: git rm [<options>] [--] <file>...\r\n\r\n    Remove files from the working tree and from the index\r\n\r\nOptions:\r\n    --cached             Only remove from the index\r\n    -f, --force          Override the up-to-date check\r\n    -r                   Allow recursive removal\r\n    -n, --dry-run        Dry run\r\n    -q, --quiet          Suppress output\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var cached = false
        var force = false
        var recursive = false
        var dryRun = false
        var quiet = false
        var paths: [String] = []

        for arg in args {
            switch arg {
            case "--cached": cached = true
            case "-f", "--force": force = true
            case "-r": recursive = true
            case "-n", "--dry-run": dryRun = true
            case "-q", "--quiet": quiet = true
            default:
                if arg == "--" { continue }
                if !arg.hasPrefix("-") {
                    paths.append(arg)
                }
            }
        }

        if paths.isEmpty {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: No pathspec was given. Which files should I remove?\r\n"))
            return 128
        }

        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { throw GitError.libgit2(code: -1, message: "index is nil", detail: "", extra: nil) }
        defer { git_index_free(index) }

        let workdirC = git_repository_workdir(repo)
        let workdir = workdirC.map { String(cString: $0) } ?? ""
        let fm = FileManager.default

        for path in paths {
            let fullPath = workdir + path
            var isDir: ObjCBool = false
            let isDirectory = fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue

            if isDirectory && !recursive {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: not removing '\(path)' recursively without -r\r\n"))
                return 128
            }

            if isDirectory {
                if !quiet && !dryRun {
                    output("rm '\(path)'\r\n")
                }

                if !dryRun {
                    try lg2Check(git_index_remove_directory(index, path, 0), "unable to remove '\(path)' from index")
                    if !cached {
                        do {
                            try fm.removeItem(atPath: fullPath)
                        } catch {
                            output(GitStyle.fg(GitStyle.errorColor, "warning: failed to remove '\(path)' from disk: \(error.localizedDescription)\r\n"))
                        }
                    }
                }
                continue
            }

            // Check if path exists in the index
            let entryIdx = git_index_find(nil, index, path)
            if entryIdx < 0 {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: pathspec '\(path)' did not match any files\r\n"))
                return 128
            }

            // Check if file has local modifications (unless --force or --cached)
            if !force && !cached {
                let entry = git_index_get_bypath(index, path, 0)
                if let entry {
                    let fullPath = workdir + String(cString: entry.pointee.path)
                    if fm.fileExists(atPath: fullPath) {
                        // Check if working tree version differs from index
                        var workdirDiff: OpaquePointer?
                        var diffOpts = git_diff_options()
                        git_diff_options_init(&diffOpts, UInt32(GIT_DIFF_OPTIONS_VERSION))
                        let oldPfx = strdup("a")
                        let newPfx = strdup("b")
                        defer { free(oldPfx); free(newPfx) }
                        diffOpts.old_prefix = UnsafePointer(oldPfx)
                        diffOpts.new_prefix = UnsafePointer(newPfx)

                        let pathCopy = strdup(path)!
                        defer { free(pathCopy) }
                        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
                        ptrs[0] = pathCopy
                        defer { ptrs.deallocate() }
                        diffOpts.pathspec.strings = ptrs
                        diffOpts.pathspec.count = 1

                        git_diff_index_to_workdir(&workdirDiff, repo, index, &diffOpts)
                        let numDeltas = workdirDiff.map { git_diff_num_deltas($0) } ?? 0
                        if let workdirDiff { git_diff_free(workdirDiff) }

                        if numDeltas > 0 {
                            output(GitStyle.fg(GitStyle.errorColor, "error: the following file has local modifications:\r\n"))
                            output("    \(path)\r\n")
                            output("(use --cached to keep the file, or -f to force removal)\r\n")
                            return 1
                        }
                    }
                }
            }

            if !quiet && !dryRun {
                output("rm '\(path)'\r\n")
            }

            if !dryRun {
                // Remove from index
                let removeResult = git_index_remove_bypath(index, path)
                if removeResult < 0 {
                    let errMsg = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
                    output(GitStyle.fg(GitStyle.errorColor, "fatal: unable to remove '\(path)' from index: \(errMsg)\r\n"))
                    return 128
                }

                // Remove from working tree (unless --cached)
                if !cached {
                    if fm.fileExists(atPath: fullPath) {
                        do {
                            try fm.removeItem(atPath: fullPath)
                        } catch {
                            output(GitStyle.fg(GitStyle.errorColor, "warning: failed to remove '\(path)' from disk: \(error.localizedDescription)\r\n"))
                        }
                    }
                }
            }
        }

        if !dryRun {
            try lg2Check(git_index_write(index), "failed to write index")
        }

        return 0
    }
}

#endif
