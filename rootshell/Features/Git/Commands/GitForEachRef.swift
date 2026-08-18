#if !targetEnvironment(macCatalyst)

import Foundation

/// `git for-each-ref [--sort=<key>] [--count=<count>] [<pattern>]` — list refs.
enum GitForEachRef: GitSubcommand {
    static var helpText: String {
        "usage: git for-each-ref [<options>] [<pattern>...]\r\n\r\n    Output information on each ref\r\n\r\nOptions:\r\n    --sort <key>         Sort by a field name\r\n    --count <n>          Limit the number of refs to output\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var sortKey = "refname"
        var maxCount = Int.max
        var patterns: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--sort":
                if i + 1 < args.count {
                    sortKey = args[i + 1]
                    i += 1
                }
            case "--count":
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    maxCount = n
                    i += 1
                }
            default:
                if args[i].hasPrefix("--sort=") {
                    sortKey = String(args[i].dropFirst(7))
                } else if args[i].hasPrefix("--count="), let n = Int(String(args[i].dropFirst(8))) {
                    maxCount = n
                } else if !args[i].hasPrefix("-") {
                    patterns.append(args[i])
                }
            }
            i += 1
        }

        // Collect refs
        var refs: [RefEntry] = []

        var refIter: OpaquePointer?
        let iterResult: Int32
        if let pattern = patterns.first {
            iterResult = git_reference_iterator_glob_new(&refIter, repo, pattern)
        } else {
            iterResult = git_reference_iterator_new(&refIter, repo)
        }

        guard iterResult == 0, let refIter else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to iterate refs\r\n"))
            return 1
        }
        defer { git_reference_iterator_free(refIter) }

        var ref: OpaquePointer?
        while git_reference_next(&ref, refIter) == 0, let ref {
            defer { git_reference_free(ref) }

            let refName = git_reference_name(ref).map { String(cString: $0) } ?? ""

            // Resolve to the final target OID
            var resolved: OpaquePointer?
            var oid = git_oid()
            if git_reference_resolve(&resolved, ref) == 0, let resolved {
                defer { git_reference_free(resolved) }
                if let targetOid = git_reference_target(resolved) {
                    oid = targetOid.pointee
                }
            } else if let directOid = git_reference_target(ref) {
                oid = directOid.pointee
            }

            // Determine object type by peeling
            var peeled: OpaquePointer?
            var objType = "commit"
            if git_reference_peel(&peeled, ref, GIT_OBJECT_ANY) == 0, let peeled {
                let t = git_object_type(peeled)
                objType = git_object_type2string(t).map { String(cString: $0) } ?? "commit"
                git_object_free(peeled)
            }

            // Get commit date for date sorting
            var commitTime: git_time_t = 0
            var commit: OpaquePointer?
            if git_commit_lookup(&commit, repo, &oid) == 0, let commit {
                commitTime = git_commit_time(commit)
                git_commit_free(commit)
            }

            refs.append(RefEntry(
                refName: refName,
                oid: oid,
                objectType: objType,
                commitTime: commitTime
            ))
        }

        // Sort
        let descending = sortKey.hasPrefix("-")
        let key = descending ? String(sortKey.dropFirst()) : sortKey

        switch key {
        case "creatordate", "committerdate", "date":
            refs.sort { a, b in
                descending ? a.commitTime > b.commitTime : a.commitTime < b.commitTime
            }
        default:
            // Sort by refname
            refs.sort { a, b in
                descending ? a.refName > b.refName : a.refName < b.refName
            }
        }

        // Limit output
        let limited = refs.prefix(maxCount)

        var out = GitOutput(write: output)

        for entry in limited {
            var oid = entry.oid
            let hashStr = oidFullString(&oid)

            let color = colorForRef(entry.refName)

            out.raw(GitStyle.fg(GitStyle.hash, hashStr))
            out.raw(" ")
            out.raw(GitStyle.fg(GitStyle.dimColor, entry.objectType.padding(toLength: 6, withPad: " ", startingAt: 0)))
            out.raw(" ")
            out.raw(GitStyle.fg(color, entry.refName))
            out.line()
        }

        out.flush()
        return 0
    }

    // MARK: - Helpers

    private struct RefEntry {
        let refName: String
        var oid: git_oid
        let objectType: String
        let commitTime: git_time_t
    }

    private static func colorForRef(_ refName: String) -> GitStyle.Color {
        if refName.hasPrefix("refs/heads/") {
            return GitStyle.branch
        } else if refName.hasPrefix("refs/tags/") {
            return GitStyle.tag
        } else if refName.hasPrefix("refs/remotes/") {
            return GitStyle.remote
        }
        return GitStyle.dimColor
    }
}

#endif
