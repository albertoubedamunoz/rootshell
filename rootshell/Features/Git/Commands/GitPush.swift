#if !targetEnvironment(macCatalyst)

import Foundation

/// `git push [<remote> [<refspec>]]` — push to a remote.
enum GitPush: GitProgressSubcommand {
    static var helpText: String {
        "usage: git push [<options>] [<remote> [<refspec>...]]\r\n\r\n    Update remote refs along with associated objects\r\n\r\nOptions:\r\n    -f, --force          Force update even if remote has diverged\r\n    -u, --set-upstream   Set upstream tracking reference\r\n    -q, --quiet          Suppress status and progress output\r\n    --progress           Force progress output\r\n    --no-progress        Suppress progress output\r\n"
    }

    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void,
        statusOutput: @escaping @Sendable (String) -> Void,
        progressDefault: Bool
    ) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse args
        var remoteName = "origin"
        var refspec: String?
        var force = false
        var setUpstream = false
        var positional: [String] = []
        var progressControl = GitProgressControl()

        var i = 0
        while i < args.count {
            if progressControl.consume(args[i]) {
                i += 1
                continue
            }
            switch args[i] {
            case "-f", "--force": force = true
            case "-u", "--set-upstream": setUpstream = true
            default:
                if !args[i].hasPrefix("-") {
                    positional.append(args[i])
                }
            }
            i += 1
        }

        if positional.count >= 1 {
            remoteName = positional[0]
        }
        if positional.count >= 2 {
            refspec = positional[1]
        }

        // If no refspec, derive from current branch
        if refspec == nil {
            var headRef: OpaquePointer?
            if git_repository_head(&headRef, repo) == 0, let headRef {
                defer { git_reference_free(headRef) }
                if git_reference_is_branch(headRef) != 0 {
                    let branchName = git_reference_shorthand(headRef).map { String(cString: $0) }
                    if let branchName {
                        refspec = "refs/heads/\(branchName):refs/heads/\(branchName)"
                    }
                }
            }
        }

        guard let refspec else {
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: no refspec and no current branch\r\n"))
            return 1
        }

        // Look up remote
        var remote: OpaquePointer?
        try lg2Check(git_remote_lookup(&remote, repo, remoteName), "failed to lookup remote '\(remoteName)'")
        guard let remote else { return 1 }
        defer { git_remote_free(remote) }

        let url = git_remote_url(remote).map { String(cString: $0) } ?? remoteName
        if !progressControl.quiet {
            statusOutput("Pushing to \(GitStyle.fg(GitStyle.remote, remoteName)) (\(url))...\r\n")
        }

        // Set up push options
        var pushOpts = git_push_options()
        git_push_options_init(&pushOpts, UInt32(GIT_PUSH_OPTIONS_VERSION))

        let reporter = GitProgressReporter(
            enabled: progressControl.isEnabled(default: progressDefault),
            cols: cols,
            output: statusOutput
        )
        let ctx = PushProgressContext(reporter: reporter)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        pushOpts.callbacks.push_transfer_progress = { current, total, bytes, payload in
            guard let payload else { return 0 }
            let ctx = Unmanaged<PushProgressContext>.fromOpaque(payload).takeUnretainedValue()

            if total > 0 {
                let bytesStr = formatBytes(Int(bytes))
                ctx.reporter.report(
                    phase: "Writing", current: Int(current), total: Int(total),
                    suffix: "  \(bytesStr)")
            }
            return 0
        }
        pushOpts.callbacks.payload = ctxPtr

        // Build refspec with force prefix if needed
        let finalRefspec = force ? "+\(refspec)" : refspec

        // Create refspec array
        let cRefspec = strdup(finalRefspec)!
        defer { free(cRefspec) }
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 1)
        ptrs[0] = cRefspec
        defer { ptrs.deallocate() }

        var refspecs = git_strarray()
        refspecs.strings = ptrs
        refspecs.count = 1

        let result = git_remote_push(remote, &refspecs, &pushOpts)

        Unmanaged<PushProgressContext>.fromOpaque(ctxPtr).release()

        reporter.finish()

        if result != 0 {
            let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown error"
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: \(err)\r\n"))
            return 128
        }

        // Set upstream tracking if requested
        if setUpstream {
            var headRef: OpaquePointer?
            if git_repository_head(&headRef, repo) == 0, let headRef, git_reference_is_branch(headRef) != 0 {
                defer { git_reference_free(headRef) }
                let branchName = git_reference_shorthand(headRef).map { String(cString: $0) } ?? ""
                let remoteBranch = trackingBranchName(for: refspec, currentBranch: branchName)
                try setUpstreamBranch(
                    repo: repo,
                    branchRef: headRef,
                    localBranch: branchName,
                    remoteName: remoteName,
                    remoteBranch: remoteBranch
                )
                let trackingRef = "\(remoteName)/\(remoteBranch)"
                if !progressControl.quiet {
                    statusOutput("Branch '\(GitStyle.fg(GitStyle.branch, branchName))' set up to track '\(GitStyle.fg(GitStyle.remote, trackingRef))'\r\n")
                }
            }
        }

        if !progressControl.quiet {
            statusOutput(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) Push complete\r\n"))
        }
        return 0
    }

    private static func trackingBranchName(for refspec: String?, currentBranch: String) -> String {
        guard let refspec, !refspec.isEmpty else {
            return currentBranch
        }

        let normalized = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        let destination = normalized.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? normalized
        guard !destination.isEmpty else {
            return currentBranch
        }

        return shortBranchName(from: destination) ?? destination
    }

    private static func shortBranchName(from ref: String) -> String? {
        if ref.hasPrefix("refs/heads/") {
            return String(ref.dropFirst("refs/heads/".count))
        }

        if ref.hasPrefix("heads/") {
            return String(ref.dropFirst("heads/".count))
        }

        if ref.contains("/") {
            return (ref as NSString).lastPathComponent
        }

        return ref.isEmpty ? nil : ref
    }

    private static func setUpstreamBranch(
        repo: OpaquePointer,
        branchRef: OpaquePointer,
        localBranch: String,
        remoteName: String,
        remoteBranch: String
    ) throws {
        let upstreamName = "\(remoteName)/\(remoteBranch)"
        if git_branch_set_upstream(branchRef, upstreamName) == 0 {
            return
        }

        var config: OpaquePointer?
        try lg2Check(git_repository_config(&config, repo), "failed to open repository config")
        guard let config else { return }
        defer { git_config_free(config) }

        try lg2Check(
            git_config_set_string(config, "branch.\(localBranch).remote", remoteName),
            "failed to set upstream remote"
        )
        try lg2Check(
            git_config_set_string(config, "branch.\(localBranch).merge", "refs/heads/\(remoteBranch)"),
            "failed to set upstream merge target"
        )
    }
}

/// Progress context for push callbacks.
private final class PushProgressContext: @unchecked Sendable {
    let reporter: GitProgressReporter
    init(reporter: GitProgressReporter) {
        self.reporter = reporter
    }
}

func withGitStrarray<Result>(_ strings: [String], _ body: (UnsafePointer<git_strarray>?) -> Result) -> Result {
    guard !strings.isEmpty else {
        return body(nil)
    }

    let cStrings = strings.map { strdup($0)! }
    defer { cStrings.forEach { free($0) } }

    let pointerArray = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cStrings.count)
    defer { pointerArray.deallocate() }

    for (index, value) in cStrings.enumerated() {
        pointerArray[index] = value
    }

    var strarray = git_strarray()
    strarray.strings = pointerArray
    strarray.count = cStrings.count
    return body(&strarray)
}

#endif
