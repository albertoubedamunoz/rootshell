#if !targetEnvironment(macCatalyst)

import Foundation

/// `git remote [add|remove|rename|set-url|show|-v]` — manage remotes.
enum GitRemote: GitSubcommand {
    static var helpText: String {
        "usage: git remote [-v]\r\n       git remote add <name> <url>\r\n       git remote remove <name>\r\n       git remote rename <old> <new>\r\n       git remote set-url <name> <url>\r\n       git remote show <name>\r\n\r\n    Manage set of tracked repositories\r\n\r\nOptions:\r\n    -v, --verbose        Show remote URL after name\r\n\r\nSubcommands:\r\n    add                  Add a remote\r\n    remove, rm           Remove a remote\r\n    rename               Rename a remote\r\n    set-url              Change a remote's URL\r\n    show                 Show information about a remote\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // No subcommand or -v: list remotes
        if args.isEmpty {
            return try listRemotes(repo: repo, verbose: false, output: output)
        }

        let sub = args[0]

        switch sub {
        case "-v", "--verbose":
            return try listRemotes(repo: repo, verbose: true, output: output)

        case "add":
            guard args.count >= 3 else {
                output("usage: git remote add <name> <url>\r\n")
                return 1
            }
            return try addRemote(repo: repo, name: args[1], url: args[2], output: output)

        case "remove", "rm":
            guard args.count >= 2 else {
                output("usage: git remote remove <name>\r\n")
                return 1
            }
            return try removeRemote(repo: repo, name: args[1], output: output)

        case "rename":
            guard args.count >= 3 else {
                output("usage: git remote rename <old> <new>\r\n")
                return 1
            }
            return try renameRemote(repo: repo, oldName: args[1], newName: args[2], output: output)

        case "set-url":
            guard args.count >= 3 else {
                output("usage: git remote set-url <name> <newurl>\r\n")
                return 1
            }
            return try setUrl(repo: repo, name: args[1], url: args[2], output: output)

        case "show":
            if args.count >= 2 {
                return try showRemote(repo: repo, name: args[1], output: output)
            } else {
                return try listRemotes(repo: repo, verbose: false, output: output)
            }

        default:
            output(GitStyle.fg(GitStyle.errorColor, "error: unknown subcommand: \(sub)\r\n"))
            output("usage: git remote [-v | add | remove | rename | set-url | show]\r\n")
            return 1
        }
    }

    // MARK: - List remotes

    private static func listRemotes(repo: OpaquePointer, verbose: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        var remoteList = git_strarray()
        try lg2Check(git_remote_list(&remoteList, repo), "failed to list remotes")
        defer { git_strarray_dispose(&remoteList) }

        for i in 0..<remoteList.count {
            guard let namePtr = remoteList.strings[i] else { continue }
            let name = String(cString: namePtr)

            if verbose {
                var remote: OpaquePointer?
                if git_remote_lookup(&remote, repo, name) == 0, let remote {
                    defer { git_remote_free(remote) }
                    let fetchUrl = git_remote_url(remote).map { String(cString: $0) } ?? ""
                    let pushUrl = git_remote_pushurl(remote).map { String(cString: $0) } ?? fetchUrl

                    out.line("\(GitStyle.fg(GitStyle.remote, name))\t\(fetchUrl) (fetch)")
                    out.line("\(GitStyle.fg(GitStyle.remote, name))\t\(pushUrl) (push)")
                }
            } else {
                out.line(GitStyle.fg(GitStyle.remote, name))
            }
        }

        out.flush()
        return 0
    }

    // MARK: - Add remote

    private static func addRemote(repo: OpaquePointer, name: String, url: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var remote: OpaquePointer?
        try lg2Check(git_remote_create(&remote, repo, name, url), "failed to add remote '\(name)'")
        if let remote { git_remote_free(remote) }

        output("Remote '\(GitStyle.fg(GitStyle.remote, name))' added: \(url)\r\n")
        return 0
    }

    // MARK: - Remove remote

    private static func removeRemote(repo: OpaquePointer, name: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        try lg2Check(git_remote_delete(repo, name), "failed to remove remote '\(name)'")
        output("Remote '\(GitStyle.fg(GitStyle.remote, name))' removed\r\n")
        return 0
    }

    // MARK: - Rename remote

    private static func renameRemote(repo: OpaquePointer, oldName: String, newName: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var problems = git_strarray()
        try lg2Check(git_remote_rename(&problems, repo, oldName, newName), "failed to rename remote")
        defer { git_strarray_dispose(&problems) }

        if problems.count > 0 {
            for i in 0..<problems.count {
                if let p = problems.strings[i] {
                    output(GitStyle.fg(GitStyle.warning, "warning: \(String(cString: p))\r\n"))
                }
            }
        }

        output("Remote '\(GitStyle.fg(GitStyle.remote, oldName))' renamed to '\(GitStyle.fg(GitStyle.remote, newName))'\r\n")
        return 0
    }

    // MARK: - Set URL

    private static func setUrl(repo: OpaquePointer, name: String, url: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        try lg2Check(git_remote_set_url(repo, name, url), "failed to set URL for '\(name)'")
        output("URL for '\(GitStyle.fg(GitStyle.remote, name))' set to \(url)\r\n")
        return 0
    }

    // MARK: - Show remote details

    private static func showRemote(repo: OpaquePointer, name: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        var remote: OpaquePointer?
        try lg2Check(git_remote_lookup(&remote, repo, name), "failed to lookup remote '\(name)'")
        guard let remote else { return 1 }
        defer { git_remote_free(remote) }

        let fetchUrl = git_remote_url(remote).map { String(cString: $0) } ?? "(none)"
        let pushUrl = git_remote_pushurl(remote).map { String(cString: $0) } ?? fetchUrl

        out.line("* remote \(GitStyle.fg(GitStyle.remote, name))")
        out.line("  Fetch URL: \(fetchUrl)")
        out.line("  Push  URL: \(pushUrl)")

        // Show remote tracking branches
        var refIter: OpaquePointer?
        let pattern = "refs/remotes/\(name)/*"
        if git_reference_iterator_glob_new(&refIter, repo, pattern) == 0, let refIter {
            defer { git_reference_iterator_free(refIter) }

            out.line("  Remote branches:")
            var ref: OpaquePointer?
            while git_reference_next(&ref, refIter) == 0, let ref {
                defer { git_reference_free(ref) }
                let shortName = git_reference_shorthand(ref).map { String(cString: $0) } ?? ""
                // Strip remote name prefix
                let branchPart: String
                let prefix = "\(name)/"
                if shortName.hasPrefix(prefix) {
                    branchPart = String(shortName.dropFirst(prefix.count))
                } else {
                    branchPart = shortName
                }
                out.line("    \(GitStyle.fg(GitStyle.branch, branchPart))")
            }
        }

        out.flush()
        return 0
    }
}

#endif
