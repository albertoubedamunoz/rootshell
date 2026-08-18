#if !targetEnvironment(macCatalyst)

import Foundation

/// `git clean` — remove untracked files from the working tree.
enum GitClean: GitSubcommand {
    static var helpText: String {
        "usage: git clean [<options>]\r\n\r\n    Remove untracked files from the working tree\r\n\r\nOptions:\r\n    -f, --force          Required to actually delete files\r\n    -n, --dry-run        Show what would be removed\r\n    -d                   Remove untracked directories too\r\n    -x                   Also remove ignored files\r\n    -X                   Only remove ignored files\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        var force = false
        var dryRun = false
        var removeDirs = false
        var removeIgnored = false
        var onlyIgnored = false

        for arg in args {
            switch arg {
            case "-f", "--force": force = true
            case "-n", "--dry-run": dryRun = true
            case "-d": removeDirs = true
            case "-x": removeIgnored = true
            case "-X": onlyIgnored = true
            default: break
            }
        }

        if !force && !dryRun {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: clean.requireForce defaults to true and neither -n nor -f given; refusing to clean\r\n"))
            return 128
        }

        // Build status options
        var statusOpts = git_status_options()
        git_status_options_init(&statusOpts, UInt32(GIT_STATUS_OPTIONS_VERSION))

        var flags: UInt32 = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
        if removeDirs {
            flags |= GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        }
        if removeIgnored || onlyIgnored {
            flags |= GIT_STATUS_OPT_INCLUDE_IGNORED.rawValue
        }
        statusOpts.flags = flags
        statusOpts.show = GIT_STATUS_SHOW_WORKDIR_ONLY

        var statusList: OpaquePointer?
        try lg2Check(git_status_list_new(&statusList, repo, &statusOpts), "failed to get status")
        guard let statusList else { return 1 }
        defer { git_status_list_free(statusList) }

        let workdir = git_repository_workdir(repo).map { String(cString: $0) } ?? ""
        let count = git_status_list_entrycount(statusList)
        var removed = 0
        var out = GitOutput(write: output)

        for i in 0..<count {
            guard let entry = git_status_byindex(statusList, i) else { continue }

            let status = entry.pointee.status

            let isUntracked = status.rawValue & GIT_STATUS_WT_NEW.rawValue != 0
            let isIgnored = status.rawValue & GIT_STATUS_IGNORED.rawValue != 0

            let shouldRemove: Bool
            if onlyIgnored {
                shouldRemove = isIgnored
            } else if removeIgnored {
                shouldRemove = isUntracked || isIgnored
            } else {
                shouldRemove = isUntracked && !isIgnored
            }

            guard shouldRemove else { continue }

            guard let path = entry.pointee.index_to_workdir?.pointee.new_file.path else { continue }
            let pathStr = String(cString: path)
            let fullPath = workdir + pathStr

            if dryRun {
                out.line("Would remove \(pathStr)")
            } else {
                let fm = FileManager.default
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue && !removeDirs { continue }
                    do {
                        try fm.removeItem(atPath: fullPath)
                        out.line("Removing \(pathStr)")
                        removed += 1
                    } catch {
                        out.line(GitStyle.fg(GitStyle.errorColor, "error: failed to remove '\(pathStr)': \(error.localizedDescription)"))
                    }
                }
            }
        }

        if !dryRun && removed == 0 {
            out.line("Nothing to clean")
        }

        out.flush()
        return 0
    }
}

#endif
