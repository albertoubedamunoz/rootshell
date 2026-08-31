#if !targetEnvironment(macCatalyst)

import Foundation

/// `git clone` — clone a repository with progress display.
enum GitClone: GitProgressSubcommand {
    static var helpText: String {
        "usage: git clone [<options>] <url> [<directory>]\r\n\r\n    Clone a repository into a new directory\r\n\r\nOptions:\r\n    --bare               Create a bare repository\r\n    --depth <n>          Shallow clone with <n> commits of history\r\n    -q, --quiet          Suppress status and progress output\r\n    --progress           Force progress output\r\n    --no-progress        Suppress progress output\r\n"
    }

    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void,
        statusOutput: @escaping @Sendable (String) -> Void,
        progressDefault: Bool
    ) throws -> Int32 {
        var url: String?
        var path: String?
        var bare = false
        var depth: UInt32 = 0
        var progressControl = GitProgressControl()

        var i = 0
        while i < args.count {
            if progressControl.consume(args[i]) {
                i += 1
                continue
            }
            switch args[i] {
            case "--bare": bare = true
            case "--depth":
                if i + 1 < args.count, let d = UInt32(args[i + 1]) {
                    depth = d
                    i += 1
                }
            default:
                if args[i].hasPrefix("--depth="), let d = UInt32(String(args[i].dropFirst(8))) {
                    depth = d
                } else if !args[i].hasPrefix("-") {
                    if url == nil {
                        url = args[i]
                    } else if path == nil {
                        path = args[i]
                    }
                }
            }
            i += 1
        }

        guard let url else {
            statusOutput("usage: git clone <url> [<directory>]\r\n")
            return 1
        }

        // Default path from URL
        if path == nil {
            path = defaultDirectory(from: url)
        }

        guard let path else {
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: could not determine directory name\r\n"))
            return 1
        }

        if !progressControl.quiet {
            statusOutput("Cloning into '\(path)'...\r\n")
        }

        var cloneOpts = git_clone_options()
        git_clone_options_init(&cloneOpts, UInt32(GIT_CLONE_OPTIONS_VERSION))

        if bare {
            cloneOpts.bare = 1
        }

        if depth > 0 {
            cloneOpts.fetch_opts.depth = Int32(depth)
        }

        // Set up fetch progress callback
        let reporter = GitProgressReporter(
            enabled: progressControl.isEnabled(default: progressDefault),
            cols: cols,
            output: statusOutput
        )
        let ctx = CloneProgressContext(reporter: reporter)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()

        cloneOpts.fetch_opts.callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let ctx = Unmanaged<CloneProgressContext>.fromOpaque(payload).takeUnretainedValue()

            let total = stats.pointee.total_objects
            let received = stats.pointee.received_objects
            let indexed = stats.pointee.indexed_objects
            let bytes = stats.pointee.received_bytes
            let bytesStr = formatBytes(Int(bytes))

            if received < total {
                ctx.reporter.report(
                    phase: "Receiving", current: Int(received), total: Int(total),
                    suffix: "  \(bytesStr)")
            } else {
                if !ctx.didFinishReceiving {
                    ctx.didFinishReceiving = true
                    ctx.reporter.report(
                        phase: "Receiving", current: Int(total), total: Int(total),
                        suffix: "  \(bytesStr)")
                }
                if indexed < total {
                    ctx.reporter.report(
                        phase: "Indexing", current: Int(indexed), total: Int(total))
                } else if !ctx.didFinishIndexing {
                    ctx.didFinishIndexing = true
                    ctx.reporter.report(
                        phase: "Indexing", current: Int(total), total: Int(total))
                }
            }

            return 0
        }
        cloneOpts.fetch_opts.callbacks.payload = ctxPtr

        // Checkout progress
        cloneOpts.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        cloneOpts.checkout_opts.progress_cb = { path, completed, total, payload in
            guard let payload else { return }
            let ctx = Unmanaged<CloneProgressContext>.fromOpaque(payload).takeUnretainedValue()

            if total > 0 {
                ctx.reporter.report(
                    phase: "Checkout", current: Int(completed), total: Int(total))
            }
        }
        cloneOpts.checkout_opts.progress_payload = ctxPtr

        var newRepo: OpaquePointer?
        let result = git_clone(&newRepo, url, path, &cloneOpts)

        // Clean up progress context
        Unmanaged<CloneProgressContext>.fromOpaque(ctxPtr).release()

        reporter.finish()

        if result != 0 {
            let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown error"
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: \(err)\r\n"))
            return 128
        }

        if let newRepo {
            git_repository_free(newRepo)
        }

        if !progressControl.quiet {
            statusOutput(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) Clone complete\r\n"))
        }
        return 0
    }

    private static func defaultDirectory(from url: String) -> String? {
        // Extract directory name from URL
        var name = url

        // Remove trailing .git
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }

        // Remove trailing slash
        if name.hasSuffix("/") {
            name = String(name.dropLast())
        }

        // Get last path component
        if let lastSlash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: lastSlash)...])
        }

        // Handle ssh:// style with ':'
        if let lastColon = name.lastIndex(of: ":") {
            name = String(name[name.index(after: lastColon)...])
        }

        return name.isEmpty ? nil : name
    }
}

/// Progress context for clone callbacks (passed through C void pointer).
private final class CloneProgressContext: @unchecked Sendable {
    let reporter: GitProgressReporter
    var didFinishReceiving = false
    var didFinishIndexing = false
    init(reporter: GitProgressReporter) {
        self.reporter = reporter
    }
}

/// Format byte count for display.
func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1048576 { return "\(bytes / 1024) KB" }
    if bytes < 1073741824 { return String(format: "%.1f MB", Double(bytes) / 1048576.0) }
    return String(format: "%.2f GB", Double(bytes) / 1073741824.0)
}

#endif
