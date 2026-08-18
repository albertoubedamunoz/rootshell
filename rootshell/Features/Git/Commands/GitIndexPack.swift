#if !targetEnvironment(macCatalyst)

import Foundation

/// `git index-pack <packfile>` — index a pack file.
enum GitIndexPack: GitSubcommand {
    static var helpText: String {
        "usage: git index-pack <packfile>\r\n\r\n    Build pack index file for an existing packed archive\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Parse args
        var packPath: String?

        for arg in args {
            if !arg.hasPrefix("-") {
                packPath = arg
            }
        }

        guard let packPath else {
            output("usage: git index-pack <packfile>\r\n")
            return 1
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: packPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: cannot open packfile '\(packPath)'\r\n"))
            return 128
        }

        // Read the pack file
        guard let fileData = FileManager.default.contents(atPath: packPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to read '\(packPath)'\r\n"))
            return 128
        }

        // Determine output directory (same as pack file)
        let dirPath = (packPath as NSString).deletingLastPathComponent

        // Set up progress context
        let ctx = IndexPackProgressContext(output: output, cols: cols)
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
                ctx.output(GitStyle.formatProgressLine(
                    label: "Receiving", current: Int(received), total: Int(total),
                    cols: ctx.cols))
            } else if indexed < total {
                ctx.output(GitStyle.formatProgressLine(
                    label: "Indexing", current: Int(indexed), total: Int(total),
                    cols: ctx.cols))
            } else {
                ctx.output(GitStyle.formatProgressLine(
                    label: "Indexing", current: Int(indexed), total: Int(total),
                    cols: ctx.cols, suffix: ", done."))
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
            output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to create indexer\r\n"))
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

        output("\r\n")

        // Show result
        if let hashPtr = git_indexer_name(indexer) {
            let name = String(cString: hashPtr)
            output("pack\t\(GitStyle.fg(GitStyle.hash, name))\r\n")
        }

        output(GitStyle.fg(GitStyle.success, "\(GitStyle.checkIcon) Index complete\r\n"))
        return 0
    }
}

/// Progress context for indexer callbacks.
private final class IndexPackProgressContext: @unchecked Sendable {
    let output: @Sendable (String) -> Void
    let cols: UInt16
    init(output: @escaping @Sendable (String) -> Void, cols: UInt16) {
        self.output = output
        self.cols = cols
    }
}

#endif
