#if !targetEnvironment(macCatalyst)

import Foundation

/// `git rev-parse [--git-dir] [--show-toplevel] [--is-bare-repository] [--abbrev-ref] [--short] <rev>`
enum GitRevParse: GitSubcommand {
    static var helpText: String {
        "usage: git rev-parse [<options>] [<arg>...]\r\n\r\n    Pick out and massage parameters\r\n\r\nOptions:\r\n    --git-dir            Show the path to the .git directory\r\n    --show-toplevel      Show the path to the top-level directory\r\n    --is-bare-repository Output true/false for bare repository check\r\n    --abbrev-ref         Output the short name of a ref\r\n    --short              Output the abbreviated object name\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var showGitDir = false
        var showToplevel = false
        var isBare = false
        var abbrevRef = false
        var short = false
        var revSpec: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--git-dir": showGitDir = true
            case "--show-toplevel": showToplevel = true
            case "--is-bare-repository": isBare = true
            case "--abbrev-ref":
                abbrevRef = true
                // If next arg is not a flag, treat it as the ref
                if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                    revSpec = args[i + 1]
                    i += 1
                }
            case "--short": short = true
            default:
                if !args[i].hasPrefix("-") {
                    revSpec = args[i]
                }
            }
            i += 1
        }

        // Handle informational flags — output each requested piece
        var didOutput = false

        if showGitDir {
            if let path = git_repository_path(repo) {
                var gitDir = String(cString: path)
                // Remove trailing slash for consistency
                if gitDir.hasSuffix("/") {
                    gitDir = String(gitDir.dropLast())
                }
                output("\(gitDir)\r\n")
            }
            didOutput = true
        }

        if showToplevel {
            if let path = git_repository_workdir(repo) {
                var workDir = String(cString: path)
                if workDir.hasSuffix("/") {
                    workDir = String(workDir.dropLast())
                }
                output("\(workDir)\r\n")
            } else {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: this operation must be run in a work tree\r\n"))
                return 128
            }
            didOutput = true
        }

        if isBare {
            let bare = git_repository_is_bare(repo) != 0
            output("\(bare ? "true" : "false")\r\n")
            didOutput = true
        }

        if abbrevRef {
            let ref = revSpec ?? "HEAD"
            return try resolveAbbrevRef(repo: repo, ref: ref, output: output)
        }

        // If only informational flags were requested, we're done
        if didOutput && revSpec == nil {
            return 0
        }

        // Default: resolve revision to OID
        guard let revSpec else {
            if didOutput { return 0 }
            output("usage: git rev-parse [--git-dir] [--show-toplevel] [--is-bare-repository] [--abbrev-ref] [--short] <rev>\r\n")
            return 1
        }

        return try resolveRevision(repo: repo, rev: revSpec, short: short, output: output)
    }

    // MARK: - Resolve abbreviated ref

    private static func resolveAbbrevRef(repo: OpaquePointer, ref: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        if ref == "HEAD" {
            var headRef: OpaquePointer?
            let result = git_repository_head(&headRef, repo)

            if result == GIT_EUNBORNBRANCH.rawValue {
                output("HEAD\r\n")
                return 0
            }

            guard result == 0, let headRef else {
                output("HEAD\r\n")
                return 0
            }
            defer { git_reference_free(headRef) }

            if git_reference_is_branch(headRef) != 0 {
                let name = git_reference_shorthand(headRef).map { String(cString: $0) } ?? "HEAD"
                output("\(name)\r\n")
            } else {
                // Detached HEAD — show short OID
                var oid = git_oid()
                if git_reference_name_to_id(&oid, repo, "HEAD") == 0 {
                    let shortHash = oidShortString(&oid)
                    output("\(shortHash)\r\n")
                } else {
                    output("HEAD\r\n")
                }
            }
            return 0
        }

        // Try to resolve as a reference
        var refPtr: OpaquePointer?
        if git_reference_dwim(&refPtr, repo, ref) == 0, let refPtr {
            defer { git_reference_free(refPtr) }
            let shortName = git_reference_shorthand(refPtr).map { String(cString: $0) } ?? ref
            output("\(shortName)\r\n")
            return 0
        }

        // Fall back to showing the ref as-is
        output("\(ref)\r\n")
        return 0
    }

    // MARK: - Resolve revision to OID

    private static func resolveRevision(repo: OpaquePointer, rev: String, short: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, rev), "failed to resolve '\(rev)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        var oid = git_object_id(obj)!.pointee

        if short {
            let hashStr = oidShortString(&oid)
            output("\(hashStr)\r\n")
        } else {
            let hashStr = oidFullString(&oid)
            output("\(hashStr)\r\n")
        }

        return 0
    }
}

#endif
