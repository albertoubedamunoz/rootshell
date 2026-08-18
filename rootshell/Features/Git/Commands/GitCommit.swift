#if !targetEnvironment(macCatalyst)

import Foundation

/// `git commit` — create a new commit.
enum GitCommit: GitSubcommand {
    static var helpText: String {
        "usage: git commit [<options>]\r\n\r\n    Record changes to the repository\r\n\r\nOptions:\r\n    -m, --message <msg>      Use the given message as the commit message\r\n    --allow-empty            Allow recording an empty commit\r\n    -S, --gpg-sign[=<keyid>] Sign the commit (GPG or SSH, per gpg.format)\r\n    --no-gpg-sign            Do not sign the commit\r\n"
    }

    static func run(repo: OpaquePointer?, args: [String], cols: UInt16, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        guard let repo else { throw GitError.notARepository }

        // Parse flags
        var message: String?
        var allowEmpty = false
        var signing = SigningOptions()

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-m", "--message":
                if i + 1 < args.count {
                    if message == nil {
                        message = args[i + 1]
                    } else {
                        message! += "\n\n" + args[i + 1]
                    }
                    i += 1
                }
            case "--allow-empty":
                allowEmpty = true
            case "-S", "--gpg-sign":
                // Bare -S means "use the configured/default key" — clear
                // any key id from an earlier -S<key> (last flag wins).
                signing.explicitSign = true
                signing.keyOverride = nil
            case "--no-gpg-sign":
                signing.explicitSign = false
                signing.keyOverride = nil
            default:
                if args[i].hasPrefix("-m") {
                    // -m"message" (no space)
                    message = String(args[i].dropFirst(2))
                } else if args[i].hasPrefix("--gpg-sign=") {
                    signing.explicitSign = true
                    signing.keyOverride = String(args[i].dropFirst("--gpg-sign=".count))
                } else if args[i].hasPrefix("-S") {
                    // -S<keyid> (no space)
                    signing.explicitSign = true
                    signing.keyOverride = String(args[i].dropFirst(2))
                }
            }
            i += 1
        }

        // Get index
        var index: OpaquePointer?
        try lg2Check(git_repository_index(&index, repo), "failed to open index")
        guard let index else { throw GitError.libgit2(code: -1, message: "index is nil", detail: "", extra: nil) }
        defer { git_index_free(index) }

        // Check for staged changes
        if !allowEmpty {
            let numDeltas = stagedDeltaCount(repo: repo, index: index)
            if numDeltas == 0 {
                output("nothing to commit (use --allow-empty to override)\r\n")
                return 1
            }
        }

        // If no message provided, prepare COMMIT_EDITMSG and request editor
        guard let message, !message.isEmpty else {
            return try prepareEditorCommit(repo: repo, index: index, allowEmpty: allowEmpty, signing: signing)
        }

        // Create the commit with the provided message
        return try createCommit(repo: repo, index: index, message: message, signing: signing, output: output)
    }

    // MARK: - Signing options

    /// Commit-signing flags parsed from the command line. The resolved
    /// decision (whether to sign, in which format, with which key) is
    /// computed in `createCommit` by combining these with the repo's
    /// `commit.gpgsign` / `gpg.format` / `user.signingkey` config.
    private struct SigningOptions {
        /// The latest explicit signing decision on the command line:
        /// `true` for `-S` / `--gpg-sign[=key]`, `false` for
        /// `--no-gpg-sign`, `nil` when neither appeared. Git's option
        /// parsing is order-sensitive, so the last flag wins — e.g.
        /// `git commit --no-gpg-sign -S` signs.
        var explicitSign: Bool?
        /// Inline key id from the latest `-S<key>` / `--gpg-sign=<key>`.
        var keyOverride: String?

        /// Re-emit the flags so they survive the editor / AI-commit
        /// re-dispatch (`git commit -m <msg>` + passthroughArgs).
        var passthroughArgs: [String] {
            switch explicitSign {
            case .some(false):
                return ["--no-gpg-sign"]
            case .some(true):
                if let key = keyOverride, !key.isEmpty { return ["-S\(key)"] }
                return ["-S"]
            case .none:
                return []
            }
        }
    }

    // MARK: - Editor-based commit (no -m flag)

    /// Write a COMMIT_EDITMSG template and throw `editorNeeded` to launch the editor.
    private static func prepareEditorCommit(repo: OpaquePointer, index: OpaquePointer, allowEmpty: Bool, signing: SigningOptions) throws -> Int32 {
        guard let gitDirC = git_repository_path(repo) else {
            throw GitError.libgit2(code: -1, message: "cannot determine .git directory", detail: "", extra: nil)
        }
        let gitDir = String(cString: gitDirC)

        guard let workDirC = git_repository_workdir(repo) else {
            throw GitError.libgit2(code: -1, message: "cannot determine working directory", detail: "", extra: nil)
        }
        var workDir = String(cString: workDirC)
        if workDir.hasSuffix("/") { workDir = String(workDir.dropLast()) }

        let commitMsgPath = (gitDir as NSString).appendingPathComponent("COMMIT_EDITMSG")

        // Build template
        var template = "\n"
        template += "# Please enter the commit message for your changes. Lines starting\n"
        template += "# with '#' will be ignored, and an empty message aborts the commit.\n"
        template += "#\n"

        // Branch info
        let branchName = currentBranchName(repo: repo) ?? "(detached HEAD)"
        template += "# On branch \(branchName)\n"

        // Staged changes summary
        let stagedLines = stagedFilesSummary(repo: repo, index: index)
        if stagedLines.isEmpty {
            template += "# No changes staged for commit\n"
        } else {
            template += "# Changes to be committed:\n"
            for line in stagedLines {
                template += "#\t\(line)\n"
            }
        }
        template += "#\n"

        // Write template
        try template.write(toFile: commitMsgPath, atomically: true, encoding: .utf8)

        // Build passthrough args
        var passthrough: [String] = []
        if allowEmpty { passthrough.append("--allow-empty") }
        // Carry signing flags through the editor round-trip.
        passthrough.append(contentsOf: signing.passthroughArgs)

        throw GitError.editorNeeded(request: GitEditorRequest(
            filePath: commitMsgPath,
            workingDirectory: workDir,
            passthroughArgs: passthrough
        ))
    }

    // MARK: - Create commit

    /// Create a commit with the given message (used both for -m and post-editor).
    private static func createCommit(repo: OpaquePointer, index: OpaquePointer, message: String, signing: SigningOptions, output: @escaping @Sendable (String) -> Void) throws -> Int32 {
        // Write tree from index
        var treeOid = git_oid()
        try lg2Check(git_index_write_tree(&treeOid, index), "failed to write tree")

        var tree: OpaquePointer?
        try lg2Check(git_tree_lookup(&tree, repo, &treeOid), "failed to lookup tree")
        guard let tree else { throw GitError.libgit2(code: -1, message: "tree is nil", detail: "", extra: nil) }
        defer { git_tree_free(tree) }

        // Get signature
        var sig: UnsafeMutablePointer<git_signature>?
        let sigResult = git_signature_default(&sig, repo)
        if sigResult != 0 {
            // Fallback signature
            git_signature_now(&sig, "User", "user@localhost")
        }
        guard let sig else {
            output(GitStyle.fg(GitStyle.errorColor, "error: unable to create signature\r\n"))
            output("hint: Set user.name and user.email:\r\n")
            output("  git config user.name \"Your Name\"\r\n")
            output("  git config user.email \"you@example.com\"\r\n")
            return 1
        }
        defer { git_signature_free(sig) }

        // Get parent commit (if any)
        var parentCommit: OpaquePointer?
        var headRef: OpaquePointer?

        if git_repository_head(&headRef, repo) == 0, let headRef {
            defer { git_reference_free(headRef) }
            var parentOid = git_oid()
            if git_reference_name_to_id(&parentOid, repo, git_reference_name(headRef)) == 0 {
                git_commit_lookup(&parentCommit, repo, &parentOid)
            }
        }
        defer { if let parentCommit { git_commit_free(parentCommit) } }

        // Create commit
        var commitOid = git_oid()
        var parents: [OpaquePointer?] = parentCommit != nil ? [parentCommit] : []
        let hadParent = !parents.isEmpty

        // Resolve whether/how to sign by combining the parsed flags with
        // the repo config (commit.gpgsign / gpg.format / user.signingkey).
        // An explicit -S / --no-gpg-sign on the command line wins;
        // otherwise fall back to commit.gpgsign.
        let config = readSigningConfig(repo: repo)
        let shouldSign = signing.explicitSign ?? config.gpgsign

        if shouldSign {
            // Build the unsigned commit content, sign it, then write the
            // signed object and move the branch ourselves —
            // git_commit_create_with_signature only writes the object.
            var buf = git_buf()
            defer { git_buf_dispose(&buf) }

            let bufResult: Int32
            if parents.isEmpty {
                bufResult = git_commit_create_buffer(&buf, repo, sig, sig, nil, message, tree, 0, nil)
            } else {
                bufResult = parents.withUnsafeMutableBufferPointer { p in
                    git_commit_create_buffer(&buf, repo, sig, sig, nil, message, tree, 1, p.baseAddress)
                }
            }
            try lg2Check(bufResult, "failed to create commit buffer")

            guard let ptr = buf.ptr else {
                throw GitError.libgit2(code: -1, message: "empty commit buffer", detail: "", extra: nil)
            }
            let content = String(cString: ptr)

            // Use the committer time as the signature creation time so the
            // OpenPGP signature timestamp matches the commit.
            let signatureTime = Date(timeIntervalSince1970: TimeInterval(sig.pointee.when.time))
            let key = signing.keyOverride ?? config.signingKey
            let workDir = git_repository_workdir(repo).map { String(cString: $0) }

            let armoredSig: String
            switch GitCommitSigner.signBlocking(
                content: content, format: config.format, signingKey: key,
                signatureTime: signatureTime, workingDirectory: workDir
            ) {
            case .success(let s):
                armoredSig = s
            case .failure(let err):
                let detail = (err as? GitSignError)?.errorDescription ?? err.localizedDescription
                output(GitStyle.fg(GitStyle.errorColor, "error: gpg failed to sign the data\r\n"))
                output(GitStyle.fg(GitStyle.errorColor, "error: \(detail)\r\n"))
                output(GitStyle.fg(GitStyle.errorColor, "fatal: failed to write commit object\r\n"))
                return 1
            }

            try lg2Check(
                git_commit_create_with_signature(&commitOid, repo, content, armoredSig, "gpgsig"),
                "failed to write signed commit"
            )
            try updateHeadAfterCommit(repo: repo, oid: &commitOid, message: message, hadParent: hadParent)
        } else {
            let result: Int32
            if parents.isEmpty {
                result = git_commit_create(
                    &commitOid, repo, "HEAD",
                    sig, sig,
                    nil, message,
                    tree,
                    0, nil
                )
            } else {
                result = parents.withUnsafeMutableBufferPointer { buf in
                    git_commit_create(
                        &commitOid, repo, "HEAD",
                        sig, sig,
                        nil, message,
                        tree,
                        1, buf.baseAddress
                    )
                }
            }
            try lg2Check(result, "failed to create commit")
        }

        // Output result
        let shortHash = oidShortString(&commitOid)
        let branchName = currentBranchName(repo: repo) ?? "(detached)"

        var out = GitOutput(write: output)
        let firstLine = message.components(separatedBy: "\n").first ?? message
        out.line("[\(GitStyle.fg(GitStyle.branch, branchName)) \(GitStyle.fg(GitStyle.hash, shortHash))] \(firstLine)")
        out.flush()

        return 0
    }

    // MARK: - Signing config + ref update

    /// Read the signing-related config from the merged repo config.
    private static func readSigningConfig(repo: OpaquePointer) -> (gpgsign: Bool, format: GitSignFormat, signingKey: String?) {
        var cfg: OpaquePointer?
        guard git_repository_config(&cfg, repo) == 0, let cfg else {
            return (false, .openpgp, nil)
        }
        defer { git_config_free(cfg) }

        var gpgsign = false
        var boolVal: Int32 = 0
        if git_config_get_bool(&boolVal, cfg, "commit.gpgsign") == 0 {
            gpgsign = boolVal != 0
        }

        var format: GitSignFormat = .openpgp
        if let fmt = configString(cfg, "gpg.format"), fmt.lowercased() == "ssh" {
            format = .ssh
        }

        return (gpgsign, format, configString(cfg, "user.signingkey"))
    }

    /// Read a string config value into an owned Swift string (copies via
    /// git_buf so the value outlives the config handle).
    private static func configString(_ cfg: OpaquePointer, _ key: String) -> String? {
        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        guard git_config_get_string_buf(&buf, cfg, key) == 0, let ptr = buf.ptr else {
            return nil
        }
        let value = String(cString: ptr)
        return value.isEmpty ? nil : value
    }

    /// Point HEAD's branch (or detached HEAD) at the freshly written
    /// commit and write a reflog entry. `git_commit_create_with_signature`
    /// only writes the object, so unlike `git_commit_create("HEAD", …)`
    /// we have to move the ref ourselves.
    private static func updateHeadAfterCommit(repo: OpaquePointer, oid: inout git_oid, message: String, hadParent: Bool) throws {
        let summary = message.components(separatedBy: "\n").first ?? message
        let logMessage = hadParent ? "commit: \(summary)" : "commit (initial): \(summary)"

        var headRef: OpaquePointer?
        guard git_reference_lookup(&headRef, repo, "HEAD") == 0, let headRef else {
            throw GitError.libgit2(code: -1, message: "cannot resolve HEAD", detail: "", extra: nil)
        }
        defer { git_reference_free(headRef) }

        if let targetC = git_reference_symbolic_target(headRef) {
            // Normal case: HEAD → refs/heads/<branch>. Force-create covers
            // both updating an existing branch and the unborn-branch case.
            let branchName = String(cString: targetC)
            var newRef: OpaquePointer?
            let result = logMessage.withCString { logC in
                branchName.withCString { nameC in
                    git_reference_create(&newRef, repo, nameC, &oid, 1, logC)
                }
            }
            if let newRef { git_reference_free(newRef) }
            try lg2Check(result, "failed to update branch reference")
        } else {
            // Detached HEAD: move HEAD directly to the new commit.
            try lg2Check(git_repository_set_head_detached(repo, &oid), "failed to update detached HEAD")
        }
    }

    // MARK: - Staged Diff Text (for AI commit messages)

    /// Get the staged diff as plain patch text for AI commit message generation.
    /// Can be called from any thread — manages its own libgit2 lifecycle.
    /// Returns nil if there are no staged changes or if diff extraction fails.
    static func stagedDiffText(workingDirectory: String, maxLength: Int = 15000) -> String? {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }

        var repo: OpaquePointer?
        guard git_repository_open_ext(&repo, workingDirectory, 0, nil) == 0, let repo else {
            return nil
        }
        defer { git_repository_free(repo) }

        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else {
            return nil
        }
        defer { git_index_free(index) }

        // Get HEAD tree (nil for initial commit)
        var headTree: OpaquePointer?
        var head: OpaquePointer?
        if git_repository_head(&head, repo) == 0, let head {
            defer { git_reference_free(head) }
            var commitObj: OpaquePointer?
            if git_reference_peel(&commitObj, head, GIT_OBJECT_COMMIT) == 0, let commitObj {
                defer { git_object_free(commitObj) }
                git_commit_tree(&headTree, commitObj)
            }
        }
        defer { if let headTree { git_tree_free(headTree) } }

        // Diff tree-to-index (staged changes)
        var diff: OpaquePointer?
        guard git_diff_tree_to_index(&diff, repo, headTree, index, nil) == 0, let diff else {
            return nil
        }
        defer { git_diff_free(diff) }

        guard git_diff_num_deltas(diff) > 0 else { return nil }

        // Format as patch text
        var buf = git_buf()
        guard git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH) == 0 else {
            return nil
        }
        defer { git_buf_dispose(&buf) }

        guard let ptr = buf.ptr else { return nil }
        var text = String(cString: ptr)

        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "\n... (diff truncated)"
        }

        return text
    }

    // MARK: - Helpers

    private static func currentBranchName(repo: OpaquePointer) -> String? {
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0, let head else { return nil }
        defer { git_reference_free(head) }

        if git_reference_is_branch(head) != 0 {
            return git_reference_shorthand(head).map { String(cString: $0) }
        }
        return nil
    }

    /// Count the number of staged deltas (changes between HEAD and index).
    private static func stagedDeltaCount(repo: OpaquePointer, index: OpaquePointer) -> Int {
        var head: OpaquePointer?
        var headTree: OpaquePointer?
        let hasHead = git_repository_head(&head, repo) == 0

        if hasHead, let head {
            defer { git_reference_free(head) }
            var commitObj: OpaquePointer?
            if git_reference_peel(&commitObj, head, GIT_OBJECT_COMMIT) == 0, let commitObj {
                defer { git_object_free(commitObj) }
                git_commit_tree(&headTree, commitObj)
            }
        }

        var diff: OpaquePointer?
        git_diff_tree_to_index(&diff, repo, headTree, index, nil)
        if let headTree { git_tree_free(headTree) }

        let numDeltas = diff.map { git_diff_num_deltas($0) } ?? 0
        if let diff { git_diff_free(diff) }

        return numDeltas
    }

    /// Get a summary of staged files for the COMMIT_EDITMSG template.
    private static func stagedFilesSummary(repo: OpaquePointer, index: OpaquePointer) -> [String] {
        var head: OpaquePointer?
        var headTree: OpaquePointer?
        let hasHead = git_repository_head(&head, repo) == 0

        if hasHead, let head {
            defer { git_reference_free(head) }
            var commitObj: OpaquePointer?
            if git_reference_peel(&commitObj, head, GIT_OBJECT_COMMIT) == 0, let commitObj {
                defer { git_object_free(commitObj) }
                git_commit_tree(&headTree, commitObj)
            }
        }

        var diff: OpaquePointer?
        git_diff_tree_to_index(&diff, repo, headTree, index, nil)
        if let headTree { git_tree_free(headTree) }

        guard let diff else { return [] }
        defer { git_diff_free(diff) }

        var lines: [String] = []
        let count = git_diff_num_deltas(diff)
        for idx in 0..<count {
            guard let delta = git_diff_get_delta(diff, idx) else { continue }
            let status = delta.pointee.status
            let filePath: String
            if let newFile = delta.pointee.new_file.path {
                filePath = String(cString: newFile)
            } else if let oldFile = delta.pointee.old_file.path {
                filePath = String(cString: oldFile)
            } else {
                continue
            }

            let label: String
            switch status {
            case GIT_DELTA_ADDED:     label = "new file:   "
            case GIT_DELTA_DELETED:   label = "deleted:    "
            case GIT_DELTA_MODIFIED:  label = "modified:   "
            case GIT_DELTA_RENAMED:   label = "renamed:    "
            case GIT_DELTA_COPIED:    label = "copied:     "
            case GIT_DELTA_TYPECHANGE: label = "typechange: "
            default:                  label = "changed:    "
            }
            lines.append("\(label)\(filePath)")
        }
        return lines
    }
}

#endif
