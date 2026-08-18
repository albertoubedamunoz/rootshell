#if !targetEnvironment(macCatalyst)

import Foundation

/// `git reflog` — show reference log entries.
enum GitReflog: GitSubcommand {
    static var helpText: String {
        "usage: git reflog [show] [<ref>]\r\n       git reflog [<options>]\r\n\r\n    Manage reflog information\r\n\r\nSubcommands:\r\n    show [<ref>]         Show reflog entries (default: HEAD)\r\n\r\nOptions:\r\n    -n, --max-count <n>  Limit the number of entries to show\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var refName = "HEAD"
        var maxCount = 50

        var i = 0
        while i < args.count {
            switch args[i] {
            case "show":
                break // default subcommand
            case "-n", "--max-count":
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    maxCount = n
                    i += 1
                }
            default:
                if args[i].hasPrefix("-n"), let n = Int(String(args[i].dropFirst(2))) {
                    maxCount = n
                } else if args[i].hasPrefix("--max-count="), let n = Int(String(args[i].dropFirst(12))) {
                    maxCount = n
                } else if !args[i].hasPrefix("-") {
                    refName = args[i]
                }
            }
            i += 1
        }

        // Read the reflog
        var reflog: OpaquePointer?
        try lg2Check(git_reflog_read(&reflog, repo, refName), "failed to read reflog for '\(refName)'")
        guard let reflog else { return 1 }
        defer { git_reflog_free(reflog) }

        let count = git_reflog_entrycount(reflog)
        if count == 0 {
            output("No reflog entries for '\(refName)'\r\n")
            return 0
        }

        var out = GitOutput(write: output)
        let entriesToShow = min(Int(count), maxCount)

        for idx in 0..<entriesToShow {
            guard let entry = git_reflog_entry_byindex(reflog, idx) else { continue }

            let newOid = git_reflog_entry_id_new(entry)
            let message = git_reflog_entry_message(entry).map { String(cString: $0) } ?? ""

            let committer = git_reflog_entry_committer(entry)
            let time = committer?.pointee.when.time ?? 0
            let relTime = GitLog.relativeTime(from: time)

            var shortHash = "0000000"
            if let newOid {
                shortHash = oidShortString(newOid)
            }

            // Format: HEAD@{0}: shortHash message (time ago)
            let refLabel = refName == "HEAD" ? "HEAD" : refName
            out.raw(GitStyle.fg(GitStyle.hash, "\(refLabel)@{\(idx)}"))
            out.raw(": ")
            out.raw(GitStyle.fg(GitStyle.hash, shortHash))
            out.raw(" \(message)")
            out.raw("  \(GitStyle.fg(GitStyle.dimColor, "(\(relTime))"))")
            out.line()
        }

        out.flush()
        return 0
    }
}

#endif
