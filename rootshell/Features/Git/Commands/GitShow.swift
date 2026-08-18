#if !targetEnvironment(macCatalyst)

import Foundation

/// `git show` — show a commit's details and diff.
enum GitShow: GitSubcommand {
    static var helpText: String {
        "usage: git show [<options>] [<object>...]\r\n\r\n    Show various types of objects\r\n\r\nOptions:\r\n    --stat               Show diffstat instead of full diff\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var stat = false
        var revision = "HEAD"

        for arg in args {
            switch arg {
            case "--stat": stat = true
            default:
                if !arg.hasPrefix("-") {
                    revision = arg
                }
            }
        }

        // Resolve revision
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, revision), "unknown revision '\(revision)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        // Peel to commit
        var commitObj: OpaquePointer?
        try lg2Check(git_object_peel(&commitObj, obj, GIT_OBJECT_COMMIT), "not a commit")
        guard let commitObj else { return 1 }
        defer { git_object_free(commitObj) }

        var commit: OpaquePointer?
        try lg2Check(git_commit_lookup(&commit, repo, git_object_id(commitObj)), "failed to lookup commit")
        guard let commit else { return 1 }
        defer { git_commit_free(commit) }

        var out = GitOutput(write: output)

        // Header
        let hash = oidString(UnsafeMutablePointer(mutating: git_commit_id(commit)))
        out.line("\(GitStyle.fg(GitStyle.hash, "commit \(hash)"))")

        // Author
        if let sig = git_commit_author(commit) {
            let name = sig.pointee.name.map { String(cString: $0) } ?? ""
            let email = sig.pointee.email.map { String(cString: $0) } ?? ""
            out.line("Author: \(GitStyle.fg(GitStyle.author, name)) <\(email)>")

            let time = sig.pointee.when.time
            let date = Date(timeIntervalSince1970: TimeInterval(time))
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy Z"
            out.line("Date:   \(formatter.string(from: date))")
        }

        // Message
        if let msg = git_commit_message(commit) {
            let message = String(cString: msg).trimmingCharacters(in: .whitespacesAndNewlines)
            out.line()
            for line in message.components(separatedBy: "\n") {
                out.line("    \(line)")
            }
        }

        out.line()

        // Diff
        var commitTree: OpaquePointer?
        try lg2Check(git_commit_tree(&commitTree, commit), "failed to get commit tree")
        guard let commitTree else { return 1 }
        defer { git_tree_free(commitTree) }

        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                defer { git_commit_free(parent) }
                git_commit_tree(&parentTree, parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }

        var diff: OpaquePointer?
        try lg2Check(git_diff_tree_to_tree(&diff, repo, parentTree, commitTree, nil), "failed to create diff")
        guard let diff else { return 1 }
        defer { git_diff_free(diff) }

        if stat {
            // --stat mode
            let numDeltas = git_diff_num_deltas(diff)
            for idx in 0..<numDeltas {
                guard let delta = git_diff_get_delta(diff, idx) else { continue }
                let filePath: String
                if let newPath = delta.pointee.new_file.path {
                    filePath = String(cString: newPath)
                } else if let oldPath = delta.pointee.old_file.path {
                    filePath = String(cString: oldPath)
                } else {
                    continue
                }

                let statusChar: String
                switch delta.pointee.status {
                case GIT_DELTA_ADDED: statusChar = GitStyle.fg(GitStyle.added, "+")
                case GIT_DELTA_DELETED: statusChar = GitStyle.fg(GitStyle.deleted, "-")
                case GIT_DELTA_MODIFIED: statusChar = GitStyle.fg(GitStyle.modified, "~")
                case GIT_DELTA_RENAMED: statusChar = GitStyle.fg(GitStyle.renamed, "→")
                default: statusChar = "?"
                }

                out.line(" \(statusChar) \(filePath)")
            }
        } else {
            // Full diff output
            let outputBox = OutputBox(output)
            let payload = Unmanaged.passUnretained(outputBox).toOpaque()

            git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, { delta, hunk, line, payload in
                guard let line, let payload else { return 0 }
                let output = Unmanaged<OutputBox>.fromOpaque(payload).takeUnretainedValue()

                let content: String
                if let contentPtr = line.pointee.content {
                    // bytesNoCopy is deprecated on iOS 16+; the copy is bounded by one
                    // diff line and keeps the old nil-on-invalid-UTF-8 behavior.
                    content = String(
                        data: Data(bytes: contentPtr, count: line.pointee.content_len),
                        encoding: .utf8
                    ) ?? ""
                } else {
                    content = ""
                }

                let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content

                let origin = Int8(line.pointee.origin)
                let plus = Int8(UInt8(ascii: "+"))
                let minus = Int8(UInt8(ascii: "-"))
                let h = Int8(UInt8(ascii: "H"))
                let f = Int8(UInt8(ascii: "F"))

                if origin == plus {
                    output.write("\(GitStyle.fg(GitStyle.added, "+\(trimmed)"))\r\n")
                } else if origin == minus {
                    output.write("\(GitStyle.fg(GitStyle.deleted, "-\(trimmed)"))\r\n")
                } else if origin == f {
                    output.write("\(GitStyle.boldFg(GitStyle.headerColor, trimmed))\r\n")
                } else if origin == h {
                    output.write("\(GitStyle.fg(GitStyle.info, trimmed))\r\n")
                } else {
                    output.write(" \(trimmed)\r\n")
                }
                return 0
            }, payload)
        }

        out.flush()
        return 0
    }

    private static func oidString(_ oid: UnsafeMutablePointer<git_oid>) -> String {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
        defer { buf.deallocate() }
        git_oid_tostr(buf, 41, oid)
        return String(cString: buf)
    }
}

#endif
