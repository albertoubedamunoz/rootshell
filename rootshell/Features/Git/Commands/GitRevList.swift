#if !targetEnvironment(macCatalyst)

import Foundation

/// `git rev-list [--count] [--max-count=N] [--reverse] <commit>` — list commit OIDs.
enum GitRevList: GitSubcommand {
    static var helpText: String {
        "usage: git rev-list [<options>] <commit>...\r\n\r\n    List commit objects in reverse chronological order\r\n\r\nOptions:\r\n    --count              Print a count of commits and exit\r\n    -n, --max-count <n>  Limit the number of commits to output\r\n    --reverse            Output commits in reverse order\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var countOnly = false
        var maxCount = Int.max
        var reverse = false
        var commitRef: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--count": countOnly = true
            case "--reverse": reverse = true
            case "--max-count":
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    maxCount = n
                    i += 1
                }
            case "-n":
                if i + 1 < args.count, let n = Int(args[i + 1]) {
                    maxCount = n
                    i += 1
                }
            default:
                if args[i].hasPrefix("--max-count="), let n = Int(String(args[i].dropFirst(12))) {
                    maxCount = n
                } else if args[i].hasPrefix("-n"), let n = Int(String(args[i].dropFirst(2))) {
                    maxCount = n
                } else if !args[i].hasPrefix("-") {
                    commitRef = args[i]
                }
            }
            i += 1
        }

        // Default to HEAD
        let ref = commitRef ?? "HEAD"

        // Resolve the starting commit
        var startOid = git_oid()
        let resolveResult = git_reference_name_to_id(&startOid, repo, ref)
        if resolveResult != 0 {
            // Try as a revision spec
            var obj: OpaquePointer?
            try lg2Check(git_revparse_single(&obj, repo, ref), "failed to resolve '\(ref)'")
            guard let obj else { return 1 }
            defer { git_object_free(obj) }
            startOid = git_object_id(obj)!.pointee
        }

        // Create revision walker
        var walk: OpaquePointer?
        try lg2Check(git_revwalk_new(&walk, repo), "failed to create revwalk")
        guard let walk else { return 1 }
        defer { git_revwalk_free(walk) }

        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
        git_revwalk_push(walk, &startOid)

        if countOnly {
            // Just count commits
            var oid = git_oid()
            var count = 0
            while git_revwalk_next(&oid, walk) == 0 {
                count += 1
                if count >= maxCount { break }
            }
            output("\(count)\r\n")
            return 0
        }

        // Collect OIDs
        var oids: [git_oid] = []
        var oid = git_oid()
        var collected = 0

        while git_revwalk_next(&oid, walk) == 0 && collected < maxCount {
            oids.append(oid)
            collected += 1
        }

        if reverse {
            oids.reverse()
        }

        // Output
        var out = GitOutput(write: output)

        for var commitOid in oids {
            let hashStr = oidFullString(&commitOid)
            out.line(hashStr)
        }

        out.flush()
        return 0
    }
}

#endif
