#if !targetEnvironment(macCatalyst)

import Foundation

/// `git init` — create a new repository.
enum GitInit: GitSubcommand {
    static var helpText: String {
        "usage: git init [<options>] [<directory>]\r\n\r\n    Create an empty Git repository or reinitialize an existing one\r\n\r\nOptions:\r\n    --bare               Create a bare repository\r\n    -b, --initial-branch <name>\r\n                         Use the specified name for the initial branch\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var bare = false
        var initialBranch: String?
        var path: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--bare": bare = true
            case "-b", "--initial-branch":
                if i + 1 < args.count {
                    initialBranch = args[i + 1]
                    i += 1
                }
            default:
                if args[i].hasPrefix("--initial-branch=") {
                    initialBranch = String(args[i].dropFirst(17))
                } else if !args[i].hasPrefix("-") {
                    path = args[i]
                }
            }
            i += 1
        }

        // Default to current directory
        let repoPath = path ?? "."

        var newRepo: OpaquePointer?

        if bare {
            try lg2Check(git_repository_init(&newRepo, repoPath, 1), "failed to init bare repository")
        } else {
            var initOpts = git_repository_init_options()
            git_repository_init_options_init(&initOpts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
            initOpts.flags = GIT_REPOSITORY_INIT_MKPATH.rawValue

            if let initialBranch {
                initialBranch.withCString { cstr in
                    initOpts.initial_head = cstr
                    let result = git_repository_init_ext(&newRepo, repoPath, &initOpts)
                    if result < 0 {
                        let err = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "unknown"
                        output(GitStyle.fg(GitStyle.errorColor, "fatal: \(err)\r\n"))
                    }
                }
            } else {
                try lg2Check(git_repository_init_ext(&newRepo, repoPath, &initOpts), "failed to init repository")
            }
        }

        guard let newRepo else {
            return 1
        }
        defer { git_repository_free(newRepo) }

        // Get the actual path of the new repository
        let repoWorkdir = git_repository_workdir(newRepo).map { String(cString: $0) } ?? repoPath
        let repoBareDir = git_repository_path(newRepo).map { String(cString: $0) } ?? repoPath

        if bare {
            output("Initialized empty Git repository in \(repoBareDir)\r\n")
        } else {
            output("Initialized empty Git repository in \(repoWorkdir).git/\r\n")
        }

        return 0
    }
}

#endif
