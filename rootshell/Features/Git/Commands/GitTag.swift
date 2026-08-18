#if !targetEnvironment(macCatalyst)

import Foundation

/// `git tag [-a] [-d] [-l] [-n] [<tagname>] [<commit>]` — manage tags.
enum GitTag: GitSubcommand {
    static var helpText: String {
        "usage: git tag [<options>] [<tagname> [<commit>]]\r\n       git tag -d <tagname>\r\n       git tag -l [<pattern>]\r\n\r\n    Create, list, delete, or verify a tag object\r\n\r\nOptions:\r\n    -l, --list           List tags\r\n    -d, --delete         Delete a tag\r\n    -a, --annotate       Create an annotated tag\r\n    -m, --message <msg>  Tag message\r\n    -n                   Print tag messages in list mode\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var annotated = false
        var delete = false
        var list = false
        var showMessages = false
        var message: String?
        var tagName: String?
        var commitRef: String?
        var filterPattern: String?
        var positional: [String] = []

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-a", "--annotate": annotated = true
            case "-d", "--delete": delete = true
            case "-l", "--list": list = true
            case "-n": showMessages = true
            case "-m", "--message":
                if i + 1 < args.count {
                    message = args[i + 1]
                    annotated = true
                    i += 1
                }
            default:
                if args[i].hasPrefix("-m") {
                    // -m"message" (no space)
                    message = String(args[i].dropFirst(2))
                    annotated = true
                } else if !args[i].hasPrefix("-") {
                    positional.append(args[i])
                }
            }
            i += 1
        }

        // Determine mode
        if delete {
            guard let name = positional.first else {
                output("usage: git tag -d <tagname>\r\n")
                return 1
            }
            return try deleteTag(repo: repo, name: name, output: output)
        }

        if list || positional.isEmpty || (showMessages && !annotated && message == nil && positional.count <= 1) {
            // List mode; positional[0] is optional filter pattern
            filterPattern = positional.first
            return try listTags(repo: repo, pattern: filterPattern, showMessages: showMessages, output: output)
        }

        // Create tag
        tagName = positional[0]
        if positional.count >= 2 {
            commitRef = positional[1]
        }

        guard let tagName else { return 1 }

        if annotated {
            let msg = message ?? tagName
            return try createAnnotatedTag(repo: repo, name: tagName, commitRef: commitRef, message: msg, output: output)
        } else {
            return try createLightweightTag(repo: repo, name: tagName, commitRef: commitRef, output: output)
        }
    }

    // MARK: - List tags

    private static func listTags(repo: OpaquePointer, pattern: String?, showMessages: Bool, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        var out = GitOutput(write: output)

        var tagList = git_strarray()
        if let pattern {
            try lg2Check(git_tag_list_match(&tagList, pattern, repo), "failed to list tags")
        } else {
            try lg2Check(git_tag_list(&tagList, repo), "failed to list tags")
        }
        defer { git_strarray_dispose(&tagList) }

        for i in 0..<tagList.count {
            guard let namePtr = tagList.strings[i] else { continue }
            let name = String(cString: namePtr)

            out.raw(GitStyle.fg(GitStyle.tag, "\(GitStyle.tagIcon) \(name)"))

            if showMessages {
                // Try to get annotated tag message
                let refName = "refs/tags/\(name)"
                var ref: OpaquePointer?
                if git_reference_lookup(&ref, repo, refName) == 0, let ref {
                    defer { git_reference_free(ref) }

                    var tagObj: OpaquePointer?
                    if git_reference_peel(&tagObj, ref, GIT_OBJECT_TAG) == 0, let tagObj {
                        defer { git_object_free(tagObj) }
                        if let msgPtr = git_tag_message(tagObj) {
                            let msg = String(cString: msgPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                            let firstLine = msg.components(separatedBy: "\n").first ?? msg
                            out.raw("  \(GitStyle.fg(GitStyle.dimColor, firstLine))")
                        }
                    }
                }
            }

            out.line()
        }

        out.flush()
        return 0
    }

    // MARK: - Create annotated tag

    private static func createAnnotatedTag(repo: OpaquePointer, name: String, commitRef: String?, message: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Resolve target commit
        let target = try resolveTarget(repo: repo, ref: commitRef)
        defer { git_object_free(target) }

        // Get signature
        var sig: UnsafeMutablePointer<git_signature>?
        let sigResult = git_signature_default(&sig, repo)
        if sigResult != 0 {
            git_signature_now(&sig, "User", "user@localhost")
        }
        guard let sig else {
            output(GitStyle.fg(GitStyle.errorColor, "error: unable to create signature\r\n"))
            return 1
        }
        defer { git_signature_free(sig) }

        var tagOid = git_oid()
        try lg2Check(
            git_tag_create(&tagOid, repo, name, target, sig, message, 0),
            "failed to create tag '\(name)'"
        )

        let shortHash = oidShortString(&tagOid)
        output("Created annotated tag '\(GitStyle.fg(GitStyle.tag, name))' (\(GitStyle.fg(GitStyle.hash, shortHash)))\r\n")
        return 0
    }

    // MARK: - Create lightweight tag

    private static func createLightweightTag(repo: OpaquePointer, name: String, commitRef: String?, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        let target = try resolveTarget(repo: repo, ref: commitRef)
        defer { git_object_free(target) }

        var tagOid = git_oid()
        try lg2Check(
            git_tag_create_lightweight(&tagOid, repo, name, target, 0),
            "failed to create tag '\(name)'"
        )

        let shortHash = oidShortString(&tagOid)
        output("Created tag '\(GitStyle.fg(GitStyle.tag, name))' at \(GitStyle.fg(GitStyle.hash, shortHash))\r\n")
        return 0
    }

    // MARK: - Delete tag

    private static func deleteTag(repo: OpaquePointer, name: String, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        try lg2Check(git_tag_delete(repo, name), "failed to delete tag '\(name)'")
        output("Deleted tag '\(GitStyle.fg(GitStyle.tag, name))'\r\n")
        return 0
    }

    // MARK: - Helpers

    private static func resolveTarget(repo: OpaquePointer, ref: String?) throws -> OpaquePointer {
        var obj: OpaquePointer?

        if let ref {
            try lg2Check(git_revparse_single(&obj, repo, ref), "failed to resolve '\(ref)'")
        } else {
            // Default to HEAD
            try lg2Check(git_revparse_single(&obj, repo, "HEAD"), "failed to resolve HEAD")
        }

        guard let obj else {
            throw GitError.invalidArguments("could not resolve target")
        }

        return obj
    }
}

#endif
