#if !targetEnvironment(macCatalyst)

import Foundation

/// `git index-pack <packfile>` — index a pack file.
enum GitIndexPack: GitProgressSubcommand {
    static var helpText: String {
        "usage: git index-pack [--progress | --no-progress] [-q] <packfile>\r\n\r\n    Build pack index file for an existing packed archive\r\n"
    }

    static func run(
        repo: OpaquePointer?,
        args: [String],
        cols: UInt16,
        output: @escaping @Sendable (String) -> Void,
        statusOutput: @escaping @Sendable (String) -> Void,
        progressDefault: Bool
    ) throws -> Int32 {
        // Parse args
        var packPath: String?
        var progressControl = GitProgressControl()

        for arg in args {
            if progressControl.consume(arg) { continue }
            if !arg.hasPrefix("-") {
                packPath = arg
            }
        }

        guard let packPath else {
            statusOutput("usage: git index-pack <packfile>\r\n")
            return 1
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: packPath) else {
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: cannot open packfile '\(packPath)'\r\n"))
            return 128
        }

        // Read the pack file
        guard let fileData = FileManager.default.contents(atPath: packPath) else {
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: failed to read '\(packPath)'\r\n"))
            return 128
        }

        // Determine output directory (same as pack file)
        let dirPath = (packPath as NSString).deletingLastPathComponent

        // Set up progress context
        let reporter = GitProgressReporter(
            enabled: progressControl.isEnabled(default: progressDefault),
            cols: cols,
            output: statusOutput
        )
        defer { reporter.finish() }
        let ctx = IndexPackProgressContext(reporter: reporter)
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<IndexPackProgressContext>.fromOpaque(ctxPtr).release() }

        // Set up indexer options with progress callback
        var indexerOpts = git_indexer_options()
        try lg2Check(
            git_indexer_options_init(&indexerOpts, UInt32(GIT_INDEXER_OPTIONS_VERSION)),
            "failed to initialize indexer options"
        )
        indexerOpts.mode = 0
        indexerOpts.odb = nil

        indexerOpts.progress_cb = { stats, payload in
            guard let stats, let payload else { return 0 }
            let ctx = Unmanaged<IndexPackProgressContext>.fromOpaque(payload).takeUnretainedValue()

            let total = stats.pointee.total_objects
            let indexed = stats.pointee.indexed_objects
            let received = stats.pointee.received_objects

            if received < total {
                ctx.reporter.report(
                    phase: "Receiving", current: Int(received), total: Int(total))
            } else if indexed < total {
                ctx.reporter.report(
                    phase: "Indexing", current: Int(indexed), total: Int(total))
            } else {
                ctx.reporter.report(
                    phase: "Indexing", current: Int(indexed), total: Int(total),
                    suffix: ", done.")
            }

            return 0
        }
        indexerOpts.progress_cb_payload = ctxPtr

        // Create indexer
        var indexer: OpaquePointer?
        try lg2Check(
            git_indexer_new(&indexer, dirPath, &indexerOpts),
            "failed to create indexer"
        )

        guard let indexer else {
            statusOutput(GitStyle.fg(GitStyle.errorColor, "fatal: failed to create indexer\r\n"))
            return 128
        }
        defer { git_indexer_free(indexer) }

        // Feed data in chunks
        let chunkSize = 65536
        var stats = git_indexer_progress()
        memset(&stats, 0, MemoryLayout<git_indexer_progress>.size)

        try fileData.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }
            var offset = 0
            let totalBytes = fileData.count

            while offset < totalBytes {
                let remaining = totalBytes - offset
                let thisChunk = min(chunkSize, remaining)
                let ptr = basePtr.advanced(by: offset)

                try lg2Check(
                    git_indexer_append(indexer, ptr, thisChunk, &stats),
                    "failed to append data to indexer"
                )

                offset += thisChunk
            }
        }

        // Commit the index
        try lg2Check(
            git_indexer_commit(indexer, &stats),
            "failed to commit index"
        )

        reporter.finish()

        // Show result
        if let hashPtr = git_indexer_name(indexer) {
            let name = String(cString: hashPtr)
            output("pack\t\(GitStyle.fg(GitStyle.hash, name))\r\n")
        }

        if !progressControl.quiet {
            statusOutput(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) Index complete\r\n"))
        }
        return 0
    }
}

/// Progress context for indexer callbacks.
private final class IndexPackProgressContext: @unchecked Sendable {
    let reporter: GitProgressReporter
    init(reporter: GitProgressReporter) {
        self.reporter = reporter
    }
}

#endif
