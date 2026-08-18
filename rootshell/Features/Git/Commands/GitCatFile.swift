#if !targetEnvironment(macCatalyst)

import Foundation

/// `git cat-file <type> <object>` or `git cat-file -t/-p/-s <object>` — show object info.
enum GitCatFile: GitSubcommand {
    static var helpText: String {
        "usage: git cat-file <type> <object>\r\n       git cat-file (-t | -p | -s) <object>\r\n\r\n    Provide content, type, or size info for repository objects\r\n\r\nOptions:\r\n    -t                   Show the object type\r\n    -p                   Pretty-print the object contents\r\n    -s                   Show the object size\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var showType = false
        var prettyPrint = false
        var showSize = false
        var expectedType: String?
        var objectSpec: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-t": showType = true
            case "-p": prettyPrint = true
            case "-s": showSize = true
            default:
                if !args[i].hasPrefix("-") {
                    if objectSpec == nil && (showType || prettyPrint || showSize) {
                        objectSpec = args[i]
                    } else if expectedType == nil && !showType && !prettyPrint && !showSize {
                        expectedType = args[i]
                    } else if objectSpec == nil {
                        objectSpec = args[i]
                    }
                }
            }
            i += 1
        }

        guard let objectSpec else {
            output("usage: git cat-file (-t | -p | -s | <type>) <object>\r\n")
            return 1
        }

        // Resolve object
        var obj: OpaquePointer?
        try lg2Check(git_revparse_single(&obj, repo, objectSpec), "failed to resolve '\(objectSpec)'")
        guard let obj else { return 1 }
        defer { git_object_free(obj) }

        let objType = git_object_type(obj)
        let typeName = git_object_type2string(objType).map { String(cString: $0) } ?? "unknown"

        if showType {
            output("\(typeName)\r\n")
            return 0
        }

        if showSize {
            let size = try objectSize(repo: repo, obj: obj)
            output("\(size)\r\n")
            return 0
        }

        // Verify type matches if explicit type given
        if let expectedType, expectedType != typeName {
            output(GitStyle.fg(GitStyle.errorColor, "fatal: git cat-file \(expectedType): bad file\r\n"))
            return 1
        }

        // Pretty-print or type-specific output
        var out = GitOutput(write: output)

        switch objType {
        case GIT_OBJECT_BLOB:
            try printBlob(obj: obj, output: &out)
        case GIT_OBJECT_TREE:
            try printTree(obj: obj, output: &out)
        case GIT_OBJECT_COMMIT:
            try printCommit(obj: obj, output: &out)
        case GIT_OBJECT_TAG:
            try printTag(obj: obj, output: &out)
        default:
            output(GitStyle.fg(GitStyle.errorColor, "fatal: unknown object type '\(typeName)'\r\n"))
            return 1
        }

        out.flush()
        return 0
    }

    // MARK: - Object size

    private static func objectSize(repo: OpaquePointer, obj: OpaquePointer) throws -> Int {
        var odb: OpaquePointer?
        try lg2Check(git_repository_odb(&odb, repo), "failed to open ODB")
        guard let odb else { return 0 }
        defer { git_odb_free(odb) }

        let oid = git_object_id(obj)!
        var odbObj: OpaquePointer?
        try lg2Check(git_odb_read(&odbObj, odb, oid), "failed to read object")
        guard let odbObj else { return 0 }
        defer { git_odb_object_free(odbObj) }

        return git_odb_object_size(odbObj)
    }

    // MARK: - Blob

    private static func printBlob(obj: OpaquePointer, output: inout GitOutput) throws {
        let size = git_blob_rawsize(obj)
        guard size > 0 else { return }

        guard let content = git_blob_rawcontent(obj) else { return }
        let data = Data(bytes: content, count: Int(size))

        if let str = String(data: data, encoding: .utf8) {
            // Replace bare \n with \r\n for terminal display
            let lines = str.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                output.raw(line)
                if idx < lines.count - 1 {
                    output.raw("\r\n")
                }
            }
        } else {
            output.line(GitStyle.fg(GitStyle.warning, "Binary content (\(size) bytes)"))
        }
    }

    // MARK: - Tree

    private static func printTree(obj: OpaquePointer, output: inout GitOutput) throws {
        let entryCount = git_tree_entrycount(obj)

        for i in 0..<entryCount {
            guard let entry = git_tree_entry_byindex(obj, i) else { continue }

            let mode = git_tree_entry_filemode(entry)
            let entryType = git_tree_entry_type(entry)
            let typeStr = git_object_type2string(entryType).map { String(cString: $0) } ?? "unknown"
            let namePtr = git_tree_entry_name(entry)
            let name = namePtr.map { String(cString: $0) } ?? ""

            var oid = git_tree_entry_id(entry)!.pointee
            let hashStr = oidFullString(&oid)

            let modeStr = String(format: "%06o", mode.rawValue)

            let color: GitStyle.Color = entryType == GIT_OBJECT_TREE ? GitStyle.branch : GitStyle.info
            let icon = entryType == GIT_OBJECT_TREE ? GitStyle.folderIcon : GitStyle.fileIcon

            output.raw(GitStyle.fg(GitStyle.dimColor, modeStr))
            output.raw(" ")
            output.raw(GitStyle.fg(color, typeStr))
            output.raw(" ")
            output.raw(GitStyle.fg(GitStyle.hash, hashStr))
            output.raw("    ")
            output.raw(GitStyle.fg(color, "\(icon) \(name)"))
            output.line()
        }
    }

    // MARK: - Commit

    private static func printCommit(obj: OpaquePointer, output: inout GitOutput) throws {
        var treeOid = git_commit_tree_id(obj)!.pointee
        let treeHash = oidFullString(&treeOid)
        output.line(GitStyle.fg(GitStyle.dimColor, "tree ") + GitStyle.fg(GitStyle.hash, treeHash))

        let parentCount = git_commit_parentcount(obj)
        for i in 0..<parentCount {
            var parentOid = git_commit_parent_id(obj, i)!.pointee
            let parentHash = oidFullString(&parentOid)
            output.line(GitStyle.fg(GitStyle.dimColor, "parent ") + GitStyle.fg(GitStyle.hash, parentHash))
        }

        if let authorSig = git_commit_author(obj) {
            let name = authorSig.pointee.name.map { String(cString: $0) } ?? ""
            let email = authorSig.pointee.email.map { String(cString: $0) } ?? ""
            let time = authorSig.pointee.when.time
            let offset = authorSig.pointee.when.offset
            let sign = offset >= 0 ? "+" : "-"
            let absOffset = abs(Int(offset))
            let tzStr = String(format: "%@%02d%02d", sign, absOffset / 60, absOffset % 60)
            output.line(GitStyle.fg(GitStyle.author, "author \(name) <\(email)> \(time) \(tzStr)"))
        }

        if let committerSig = git_commit_committer(obj) {
            let name = committerSig.pointee.name.map { String(cString: $0) } ?? ""
            let email = committerSig.pointee.email.map { String(cString: $0) } ?? ""
            let time = committerSig.pointee.when.time
            let offset = committerSig.pointee.when.offset
            let sign = offset >= 0 ? "+" : "-"
            let absOffset = abs(Int(offset))
            let tzStr = String(format: "%@%02d%02d", sign, absOffset / 60, absOffset % 60)
            output.line(GitStyle.fg(GitStyle.author, "committer \(name) <\(email)> \(time) \(tzStr)"))
        }

        // gpgsig header — present on signed commits. Matches real git's
        // raw `cat-file -p` dump: first value line follows "gpgsig ",
        // continuation lines are indented by one space. This is the
        // canonical way to confirm a commit was signed (we don't yet
        // verify signatures).
        var sigBuf = git_buf()
        if git_commit_header_field(&sigBuf, obj, "gpgsig") == 0, let sigPtr = sigBuf.ptr {
            let signature = String(cString: sigPtr)
            for (idx, line) in signature.components(separatedBy: "\n").enumerated() {
                if idx == 0 {
                    output.line(GitStyle.fg(GitStyle.dimColor, "gpgsig ") + line)
                } else {
                    output.line(" \(line)")
                }
            }
        }
        git_buf_dispose(&sigBuf)

        output.line()

        let message = git_commit_message(obj).map { String(cString: $0) } ?? ""
        for line in message.components(separatedBy: "\n") {
            output.line("    \(line)")
        }
    }

    // MARK: - Tag

    private static func printTag(obj: OpaquePointer, output: inout GitOutput) throws {
        let targetType = git_tag_target_type(obj)
        let targetTypeStr = git_object_type2string(targetType).map { String(cString: $0) } ?? "unknown"

        var targetOid = git_tag_target_id(obj)!.pointee
        let targetHash = oidFullString(&targetOid)
        output.line(GitStyle.fg(GitStyle.dimColor, "object ") + GitStyle.fg(GitStyle.hash, targetHash))
        output.line(GitStyle.fg(GitStyle.dimColor, "type ") + targetTypeStr)

        let tagName = git_tag_name(obj).map { String(cString: $0) } ?? ""
        output.line(GitStyle.fg(GitStyle.dimColor, "tag ") + GitStyle.fg(GitStyle.tag, tagName))

        if let taggerSig = git_tag_tagger(obj) {
            let name = taggerSig.pointee.name.map { String(cString: $0) } ?? ""
            let email = taggerSig.pointee.email.map { String(cString: $0) } ?? ""
            let time = taggerSig.pointee.when.time
            let offset = taggerSig.pointee.when.offset
            let sign = offset >= 0 ? "+" : "-"
            let absOffset = abs(Int(offset))
            let tzStr = String(format: "%@%02d%02d", sign, absOffset / 60, absOffset % 60)
            output.line(GitStyle.fg(GitStyle.author, "tagger \(name) <\(email)> \(time) \(tzStr)"))
        }

        output.line()

        let message = git_tag_message(obj).map { String(cString: $0) } ?? ""
        for line in message.components(separatedBy: "\n") {
            output.line(line)
        }
    }
}

#endif
