#if !targetEnvironment(macCatalyst)

import Foundation

/// `git add` — stages files for commit.
enum GitAdd: GitSubcommand {
    static var helpText: String {
        "usage: git add [<options>] [<pathspec>...]\r\n\r\n    Stage file contents for commit\r\n\r\nOptions:\r\n    -v, --verbose        Be verbose\r\n    -n, --dry-run        Dry run\r\n    -u, --update         Update tracked files\r\n    -A, --all            Add all changes (same as '.')\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var verbose = false
        var dryRun = false
        var update = false
        var all = false
        var paths: [String] = []

        for arg in args {
            switch arg {
            case "-v", "--verbose": verbose = true
            case "-n", "--dry-run": dryRun = true
            case "-u", "--update": update = true
            case "-A", "--all": all = true
            case ".": all = true
            default:
                if !arg.hasPrefix("-") {
                    paths.append(arg)
                }
            }
        }

        if paths.isEmpty && !all && !update {
            output("Nothing specified, nothing added.\r\n")
            output("hint: Maybe you wanted to say 'git add .'?\r\n")
            return 0
        }

        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { throw GitError.libgit2(code: -1, message: "index is nil", detail: "", extra: nil) }
        defer { git_index_free(index) }

        if all || update {
            var pathspec = git_strarray()
            let star = strdup("*")!
            defer { free(star) }
            let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
            ptrs[0] = star
            pathspec.strings = ptrs
            pathspec.count = 1
            defer { ptrs.deallocate() }

            let outputBox = OutputBox(output)
            let payload = Unmanaged.passUnretained(outputBox).toOpaque()
            let callback: git_index_matched_path_cb = { path, _, payload in
                guard let path, let payload else { return 0 }
                let pathStr = String(cString: path)
                let output = Unmanaged<OutputBox>.fromOpaque(payload).takeUnretainedValue()
                output.write("add '\(pathStr)'\r\n")
                return 0
            }

            if update {
                if dryRun || verbose {
                    try lg2Check(
                        git_index_update_all(index, &pathspec, callback, payload),
                        "failed to update files"
                    )
                } else {
                    try lg2Check(
                        git_index_update_all(index, &pathspec, nil, nil),
                        "failed to update files"
                    )
                }
            } else {
                let flags = GIT_INDEX_ADD_DEFAULT.rawValue | GIT_INDEX_ADD_CHECK_PATHSPEC.rawValue

                if dryRun || verbose {
                    try lg2Check(
                        git_index_add_all(index, &pathspec, flags, callback, payload),
                        "failed to add files"
                    )
                } else {
                    try lg2Check(
                        git_index_add_all(index, &pathspec, flags, nil, nil),
                        "failed to add files"
                    )
                }
            }
        } else {
            // Add specific paths
            for path in paths {
                if verbose || dryRun {
                    output("add '\(path)'\r\n")
                }

                if !dryRun {
                    let result = git_index_add_bypath(index, path)
                    if result < 0 {
                        let errMsg = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
                        output(GitStyle.fg(GitStyle.errorColor, "fatal: pathspec '\(path)' did not match any files: \(errMsg)\r\n"))
                        return 128
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

/// Helper to pass output closure through C callbacks via Unmanaged.
final class OutputBox: @unchecked Sendable {
    let write: @Sendable (String) -> Void
    init(_ write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }
}

#endif
