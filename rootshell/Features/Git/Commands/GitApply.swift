#if !targetEnvironment(macCatalyst)

import Foundation

/// `git apply` — apply a patch to files and/or the index.
enum GitApply: GitSubcommand {
    static var helpText: String {
        "usage: git apply [<options>] <patch>\r\n\r\n    Apply a patch to files and/or to the index\r\n\r\nOptions:\r\n    --cached             Apply to index only\r\n    --check              Check if patch applies cleanly (dry run)\r\n    --stat               Show diffstat instead of applying\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var cached = false
        var check = false
        var stat = false
        var patchFile: String?

        for arg in args {
            switch arg {
            case "--cached": cached = true
            case "--check": check = true
            case "--stat": stat = true
            default:
                if !arg.hasPrefix("-") {
                    patchFile = arg
                }
            }
        }

        guard let patchFile else {
            output(GitStyle.fg(GitStyle.errorColor, "usage: git apply <patch>\r\n"))
            return 1
        }

        // Read patch file
        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let fullPath: String
        if patchFile.hasPrefix("/") {
            fullPath = patchFile
        } else {
            fullPath = workdir + patchFile
        }

        guard let patchData = FileManager.default.contents(atPath: fullPath),
              let patchContent = String(data: patchData, encoding: .utf8) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot read patch file '\(patchFile)'\r\n"))
            return 1
        }

        // Parse the diff
        var diff: OpaquePointer?
        try patchContent.withCString { cStr in
            try lg2Check(
                git_diff_from_buffer(&diff, cStr, patchContent.utf8.count),
                "failed to parse patch"
            )
        }
        guard let diff else { return 1 }
        defer { git_diff_free(diff) }

        if stat {
            // Show diffstat
            var stats: OpaquePointer?
            try lg2Check(git_diff_get_stats(&stats, diff), "failed to get diff stats")
            defer { git_diff_stats_free(stats) }

            var buf = git_buf()
            let statsFormat = git_diff_stats_format_t(rawValue: GIT_DIFF_STATS_FULL.rawValue | GIT_DIFF_STATS_SHORT.rawValue)
            try lg2Check(
                git_diff_stats_to_buf(&buf, stats, statsFormat, 80),
                "failed to format diff stats"
            )
            defer { git_buf_dispose(&buf) }

            if let ptr = buf.ptr {
                let statStr = String(cString: ptr)
                let lines = statStr.components(separatedBy: "\n")
                var out = GitOutput(write: output)
                for line in lines where !line.isEmpty {
                    out.line(line)
                }
                out.flush()
            }
            return 0
        }

        // Determine location (--cached applies to index, default is workdir)
        let location: git_apply_location_t
        if cached {
            location = GIT_APPLY_LOCATION_INDEX
        } else {
            location = GIT_APPLY_LOCATION_WORKDIR
        }

        var applyOpts = git_apply_options()
        git_apply_options_init(&applyOpts, UInt32(GIT_APPLY_OPTIONS_VERSION))

        if check {
            applyOpts.flags = GIT_APPLY_CHECK.rawValue
        }

        let result = git_apply(repo, diff, location, &applyOpts)

        if result != 0 {
            let lg2err = git_error_last()
            let detail = lg2err?.pointee.message.map { String(cString: $0) } ?? "unknown error"
            output(GitStyle.fg(GitStyle.errorColor, "error: patch does not apply: \(detail)\r\n"))
            return 1
        }

        if check {
            output("Patch applies cleanly.\r\n")
        } else {
            output("Applied patch '\(patchFile)'\r\n")
        }

        return 0
    }
}

#endif
