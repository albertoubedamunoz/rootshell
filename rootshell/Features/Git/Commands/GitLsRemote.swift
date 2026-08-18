#if !targetEnvironment(macCatalyst)

import Foundation

/// `git ls-remote [<remote>]` — list remote refs.
enum GitLsRemote: GitSubcommand {
    static var helpText: String {
        "usage: git ls-remote [<options>] [<remote>]\r\n\r\n    List references in a remote repository\r\n\r\nOptions:\r\n    -h, --heads          Limit to heads (branches) only\r\n    -t, --tags           Limit to tags only\r\n\r\nNote: Use --help for help; -h means --heads for this command.\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var remoteName = "origin"
        var showHeads = false
        var showTags = false

        for arg in args {
            switch arg {
            case "--heads", "-h": showHeads = true
            case "--tags", "-t": showTags = true
            default:
                if !arg.hasPrefix("-") {
                    remoteName = arg
                }
            }
        }

        // Look up remote (may use repo or direct URL)
        var remote: OpaquePointer?

        if let repo {
            // Try as named remote first
            if git_remote_lookup(&remote, repo, remoteName) != 0 {
                // Try as URL
                try lg2Check(
                    git_remote_create_anonymous(&remote, repo, remoteName),
                    "failed to create remote for '\(remoteName)'"
                )
            }
        } else {
            try lg2Check(
                git_remote_create_detached(&remote, remoteName),
                "failed to create detached remote for '\(remoteName)'"
            )
        }

        guard let remote else { return 1 }
        defer { git_remote_free(remote) }

        // Connect to the remote for reading
        var connectOpts = git_remote_connect_options()
        git_remote_connect_options_init(&connectOpts, UInt32(GIT_REMOTE_CONNECT_OPTIONS_VERSION))

        try lg2Check(
            git_remote_connect_ext(remote, GIT_DIRECTION_FETCH, &connectOpts),
            "failed to connect to remote"
        )
        defer { git_remote_disconnect(remote) }

        // List remote refs
        var refs: UnsafeMutablePointer<UnsafePointer<git_remote_head>?>?
        var refCount: Int = 0

        try lg2Check(
            git_remote_ls(&refs, &refCount, remote),
            "failed to list remote refs"
        )

        var out = GitOutput(write: output)

        for i in 0..<refCount {
            guard let refHead = refs?[i] else { continue }
            let name = refHead.pointee.name.map { String(cString: $0) } ?? ""

            // Filter by type if requested
            if showHeads && !name.hasPrefix("refs/heads/") { continue }
            if showTags && !name.hasPrefix("refs/tags/") { continue }

            var oid = refHead.pointee.oid
            let oidStr = oidFullString(&oid)

            // Color the ref name based on type
            let coloredName: String
            if name.hasPrefix("refs/heads/") {
                coloredName = GitStyle.fg(GitStyle.branch, name)
            } else if name.hasPrefix("refs/tags/") {
                coloredName = GitStyle.fg(GitStyle.tag, name)
            } else if name == "HEAD" {
                coloredName = GitStyle.boldFg(GitStyle.branch, name)
            } else {
                coloredName = name
            }

            out.line("\(GitStyle.fg(GitStyle.hash, oidStr))\t\(coloredName)")
        }

        out.flush()
        return 0
    }
}

#endif
