#if !targetEnvironment(macCatalyst)

import Foundation

/// `git fetch [<remote>]` — fetch from a remote with progress.
enum GitFetch: GitProgressSubcommand {
    static var helpText: String {
        "usage: git fetch [<options>] [<remote>]\r\n\r\n    Download objects and refs from a remote repository\r\n\r\nOptions:\r\n    -p, --prune          Remove remote-tracking refs that no longer exist on the remote\r\n    -q, --quiet          Suppress status and progress output\r\n    --progress           Force progress output\r\n    --no-progress        Suppress progress output\r\n"
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
        var prune = false
        var refspecs: [String] = []
        var positional: [String] = []
        var progressControl = GitProgressControl()

        var i = 0
        while i < args.count {
            if progressControl.consume(args[i]) {
                i += 1
                continue
            }
            switch args[i] {
            case "--prune", "-p": prune = true
            default:
                if !args[i].hasPrefix("-") {
                    positional.append(args[i])
                }
            }
            i += 1
        }

        if let first = positional.first {
            remoteName = first
            refspecs = Array(positional.dropFirst())
        }

        // Look up the remote
        var remote: OpaquePointer?
        try lg2Check(git_remote_lookup(&remote, repo, remoteName), "failed to lookup remote '\(remoteName)'")
        guard let remote else { return 1 }
        defer { git_remote_free(remote) }

        let url = git_remote_url(remote).map { String(cString: $0) } ?? remoteName
        if !progressControl.quiet {
            statusOutput("Fetching \(GitStyle.fg(GitStyle.remote, remoteName)) (\(url))...\r\n")
        }

        // Set up fetch options with progress
        var fetchOpts = git_fetch_options()
        git_fetch_options_init(&fetchOpts, UInt32(GIT_FETCH_OPTIONS_VERSION))

        if prune {
            fetchOpts.prune = GIT_FETCH_PRUNE
        }

        let reporter = GitProgressReporter(
            enabled: progressControl.isEnabled(default: progressDefault),
            cols: cols,
            output: statusOutput
        )
        let ctx = FetchProgressContext(reporter: reporter)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        fetchOpts.callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let ctx = Unmanaged<FetchProgressContext>.fromOpaque(payload).takeUnretainedValue()

            let total = stats.pointee.total_objects
            let received = stats.pointee.received_objects
            let indexed = stats.pointee.indexed_objects
            let bytes = stats.pointee.received_bytes
            let bytesStr = formatBytes(Int(bytes))

            let totalDeltas = stats.pointee.total_deltas
            let indexedDeltas = stats.pointee.indexed_deltas

            if received < total {
                ctx.reporter.report(
                    phase: "Receiving", current: Int(received), total: Int(total),
                    suffix: "  \(bytesStr)")
            } else if !ctx.didFinishReceiving {
                ctx.didFinishReceiving = true
                ctx.reporter.report(
                    phase: "Receiving", current: Int(total), total: Int(total),
                    suffix: "  \(bytesStr)")
            } else if totalDeltas > 0, indexedDeltas < totalDeltas {
                ctx.reporter.report(
                    phase: "Resolving deltas", current: Int(indexedDeltas), total: Int(totalDeltas))
            } else if totalDeltas > 0, !ctx.didFinishDeltas {
                ctx.didFinishDeltas = true
                ctx.reporter.report(
                    phase: "Resolving deltas", current: Int(totalDeltas), total: Int(totalDeltas))
            } else if indexed < total {
                ctx.reporter.report(
                    phase: "Indexing", current: Int(indexed), total: Int(total))
            } else if !ctx.didFinishIndexing {
                ctx.didFinishIndexing = true
                ctx.reporter.report(
                    phase: "Indexing", current: Int(total), total: Int(total))
            }

            return 0
        }
        fetchOpts.callbacks.payload = ctxPtr

        // Perform fetch
        let result = withGitStrarray(refspecs) { refspecArray in
            git_remote_fetch(remote, refspecArray, &fetchOpts, nil)
        }

        Unmanaged<FetchProgressContext>.fromOpaque(ctxPtr).release()

        reporter.finish()

        if result != 0 {
            let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown error"
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: \(err)\r\n"))
            return 128
        }

        // Show updated refs summary
        if !progressControl.quiet {
            try printRefUpdates(repo: repo, remoteName: remoteName, output: statusOutput)
        }

        if !progressControl.quiet {
            statusOutput(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) Fetch complete\r\n"))
        }
        return 0
    }

    private static func printRefUpdates(repo: OpaquePointer, remoteName: String, output: @escaping @Sendable (String) -> Void) throws {
        // List remote tracking refs
        var refIter: OpaquePointer?
        let pattern = "refs/remotes/\(remoteName)/*"
        guard git_reference_iterator_glob_new(&refIter, repo, pattern) == 0, let refIter else { return }
        defer { git_reference_iterator_free(refIter) }

        var ref: OpaquePointer?
        var count = 0
        while git_reference_next(&ref, refIter) == 0, let ref {
            defer { git_reference_free(ref) }
            count += 1

            if count <= 10 {
                let name = git_reference_shorthand(ref).map { String(cString: $0) } ?? ""
                var oid = git_oid()
                if git_reference_name_to_id(&oid, repo, git_reference_name(ref)) == 0 {
                    let shortHash = oidShortString(&oid)
                    output("  \(GitStyle.fg(GitStyle.hash, shortHash)) \(GitStyle.fg(GitStyle.remote, name))\r\n")
                }
            }
        }

        if count > 10 {
            output(GitStyle.fg(GitStyle.dimColor, "  ... and \(count - 10) more refs\r\n"))
        }
    }
}

/// Progress context for fetch callbacks.
private final class FetchProgressContext: @unchecked Sendable {
    let reporter: GitProgressReporter
    var didFinishReceiving = false
    var didFinishDeltas = false
    var didFinishIndexing = false
    init(reporter: GitProgressReporter) {
        self.reporter = reporter
    }
}

#endif
