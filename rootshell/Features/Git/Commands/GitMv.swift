#if !targetEnvironment(macCatalyst)

import Foundation

/// `git mv` — move or rename a file, directory, or symlink.
enum GitMv: GitSubcommand {
    static var helpText: String {
        "usage: git mv [<options>] <source> <destination>\r\n\r\n    Move or rename a file, directory, or symlink\r\n\r\nOptions:\r\n    -f, --force          Force renaming or moving even if target exists\r\n    -n, --dry-run        Dry run\r\n    -v, --verbose        Be verbose\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var force = false
        var dryRun = false
        var verbose = false
        var positional: [String] = []

        for arg in args {
            switch arg {
            case "-f", "--force": force = true
            case "-n", "--dry-run": dryRun = true
            case "-v", "--verbose": verbose = true
            default:
                if !arg.hasPrefix("-") {
                    positional.append(arg)
                }
            }
        }

        guard positional.count >= 2 else {
            output(GitStyle.fg(GitStyle.errorColor, "usage: git mv <source> <destination>\r\n"))
            return 1
        }

        let source = positional[0]
        let destination = positional[1]

        guard let workdirC = git_repository_workdir(repo) else {
            throw GitError.libgit2(code: -1, message: "cannot determine working directory", detail: "", extra: nil)
        }
        let workdir = String(cString: workdirC)

        let srcPath = workdir + source
        let fm = FileManager.default

        // Check source exists
        guard fm.fileExists(atPath: srcPath) else {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: bad source, source=\(source), destination=\(destination)\r\n"))
            return 128
        }

        // Determine actual destination
        var dstPath = workdir + destination
        var dstIndexPath = destination

        // If destination is a directory, move source into it
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dstPath, isDirectory: &isDir), isDir.boolValue {
            let fileName = (source as NSString).lastPathComponent
            dstPath = (dstPath as NSString).appendingPathComponent(fileName)
            dstIndexPath = (destination as NSString).appendingPathComponent(fileName)
        }

        // Check destination doesn't already exist (unless -f)
        if !force && fm.fileExists(atPath: dstPath) {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: destination exists, source=\(source), destination=\(dstIndexPath)\r\n"))
            return 128
        }

        if verbose || dryRun {
            output("Renaming \(source) to \(dstIndexPath)\r\n")
        }

        if !dryRun {
            // Move file on disk
            do {
                // Create parent directory if needed
                let parentDir = (dstPath as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: parentDir) {
                    try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
                }
                try fm.moveItem(atPath: srcPath, toPath: dstPath)
            } catch {
                output(GitStyle.fg(GitStyle.errorColor, "fatal: renaming '\(source)' failed: \(error.localizedDescription)\r\n"))
                return 128
            }

            // Update index: remove old path, add new path
            var index: OpaquePointer?
            try lg2Check(git_repository_index(&index, repo), "failed to open index")
            guard let index else { return 1 }
            defer { git_index_free(index) }

            git_index_remove_bypath(index, source)

            let addResult = git_index_add_bypath(index, dstIndexPath)
            if addResult < 0 {
                let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
                output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to add '\(dstIndexPath)' to index: \(err)\r\n"))
                return 128
            }

            try lg2Check(git_index_write(index), "failed to write index")
        }

        return 0
    }
}

#endif
