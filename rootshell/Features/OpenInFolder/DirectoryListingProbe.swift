//
//  DirectoryListingProbe.swift
//  rootshell
//
//  Shell scripts that list a directory on a target over an exec channel, and
//  the parser for their nonce-framed output. Pure so it can be unit tested.
//

import Foundation

nonisolated struct DirectoryEntry: Hashable, Sendable {
    let name: String
    /// A symlink to a directory counts as a directory.
    let isDirectory: Bool
}

nonisolated enum DirectoryListingError: Equatable, Sendable {
    case notFound
    case notDirectory
    case permissionDenied
    /// Client-side: the typed path cannot be quoted or resolved.
    case unsupportedPath
    /// The start marker never arrived.
    case malformedResponse
}

nonisolated struct DirectoryListingResult: Equatable, Sendable {
    var home: String?
    /// Logical `pwd` after `cd`: `.`/`..` collapsed, symlinks kept.
    var resolvedPath: String?
    var entries: [DirectoryEntry] = []
    var error: DirectoryListingError?
    /// Hit the entry cap; `entries` holds the first cap-many.
    var truncated = false
    /// The end marker arrived; false means the transport cut the reply.
    var complete = false

    var directories: [DirectoryEntry] { entries.filter(\.isDirectory) }
}

/// What the user typed, resolved against the pane's cwd on the Swift side.
nonisolated enum DirectoryTarget: Equatable, Sendable {
    case absolute(String)
    case home
    /// `~/x` → `x` (no leading slash).
    case homeRelative(String)
    /// `~bob/x`; the user name is validated before it reaches a shell.
    case userHome(user: String, rest: String)

    /// nil when the path cannot be passed to a shell safely.
    static func resolve(_ typed: String, baseDirectory: String?) -> DirectoryTarget? {
        guard !typed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        if typed.isEmpty {
            if let baseDirectory, baseDirectory.hasPrefix("/") { return .absolute(PathCompletion.normalize(baseDirectory)) }
            return .home
        }
        if typed == "~" || typed == "~/" { return .home }
        if typed.hasPrefix("~/") {
            let rest = PathCompletion.normalize(String(typed.dropFirst(2)))
            return rest.isEmpty ? .home : .homeRelative(rest)
        }
        if typed.hasPrefix("~") {
            let body = typed.dropFirst()
            let user = String(body.prefix { $0 != "/" })
            guard isValidUserName(user) else { return nil }
            let rest = PathCompletion.normalize(String(body.dropFirst(user.count).drop { $0 == "/" }))
            return .userHome(user: user, rest: rest)
        }
        if typed.hasPrefix("/") { return .absolute(PathCompletion.normalize(typed)) }
        if let baseDirectory, baseDirectory.hasPrefix("/") {
            return .absolute(PathCompletion.normalize(baseDirectory + "/" + typed))
        }
        return .homeRelative(PathCompletion.normalize(typed))
    }

    private static func isValidUserName(_ user: String) -> Bool {
        !user.isEmpty && user.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// The shell word assigned to `_t` in the probe script.
    var shellExpression: String {
        switch self {
        case .absolute(let path):
            return LoginShellCommand.singleQuoted(path)
        case .home:
            return "\"$HOME\""
        case .homeRelative(let rest):
            return "\"$HOME\"" + LoginShellCommand.singleQuoted("/" + rest)
        case .userHome(let user, let rest):
            // The tilde prefix must end at an UNQUOTED slash or it does not expand.
            return rest.isEmpty ? "~\(user)" : "~\(user)/" + LoginShellCommand.singleQuoted(rest)
        }
    }
}

nonisolated enum DirectoryListingProbe {
    static let defaultMaxEntries = 4000
    static let scanAheadMaxChildren = 32
    static let scanAheadMaxEntriesPerChild = 300
    static let maxResponseBytes = 512 * 1024

    /// Portable prologue: C collation, no GNU quoting, no forced BSD colors.
    private static let environment = "LC_ALL=C; export LC_ALL; unset QUOTING_STYLE CLICOLOR_FORCE; "

    // MARK: Fast path

    /// Lists one directory. Ready for RemoteExecProbe.run / the helper.
    static func command(target: DirectoryTarget, maxEntries: Int = defaultMaxEntries) -> (command: String, nonce: String) {
        let (script, nonce) = script(target: target, maxEntries: maxEntries)
        return (LoginShellCommand.runInPOSIXShell(script), nonce)
    }

    /// The inner script, exposed so tests can inspect what the remote shell parses.
    static func script(target: DirectoryTarget, maxEntries: Int = defaultMaxEntries) -> (script: String, nonce: String) {
        let nonce = makeNonce()
        // `ls -1ApL`: one name per line, dotfiles, `/` after directories, symlinks
        // followed so a link to a directory is marked. `exit 0` always: Citadel
        // discards output on a non-zero exit.
        let script = environment
            + "printf '::RSDIR_\(nonce)::\\n'; printf 'H\\t%s\\n' \"$HOME\"; "
            + "_t=\(target.shellExpression); "
            + "if [ ! -e \"$_t\" ] && [ ! -L \"$_t\" ]; then printf 'E\\tnotfound\\n'; "
            + "elif [ ! -d \"$_t\" ]; then printf 'E\\tnotdir\\n'; "
            + "elif ! [ -r \"$_t\" ] || ! [ -x \"$_t\" ] || ! cd \"$_t\" 2>/dev/null; then printf 'E\\tdenied\\n'; "
            + "else printf 'P\\t'; pwd; printf 'L\\n'; ls -1ApL . 2>/dev/null | head -n \(maxEntries + 1); fi; "
            + "printf '::END_\(nonce)::\\n'; exit 0"
        return (script, nonce)
    }

    static func parse(output: String, nonce: String, maxEntries: Int = defaultMaxEntries) -> DirectoryListingResult {
        var result = DirectoryListingResult()
        let startMarker = "::RSDIR_\(nonce)::"
        let endMarker = "::END_\(nonce)::"
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        guard let start = lines.firstIndex(where: { $0 == startMarker }) else {
            result.error = .malformedResponse
            return result
        }
        lines = lines[(start + 1)...]
        var listing = false
        for line in lines {
            if line == endMarker { result.complete = true; break }
            if listing {
                if line.isEmpty { continue }
                result.entries.append(entry(from: line))
                continue
            }
            if line == "L" { listing = true; continue }
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let value = String(line[line.index(after: tab)...])
            switch line[..<tab] {
            case "H": result.home = value.isEmpty ? nil : value
            case "P": result.resolvedPath = value
            case "E": result.error = error(from: value)
            default: continue
            }
        }
        applyCap(&result, maxEntries: maxEntries)
        return result
    }

    /// Applies the `head -n cap+1` convention: cap+1 lines means truncated.
    private static func applyCap(_ result: inout DirectoryListingResult, maxEntries: Int) {
        if result.entries.count > maxEntries {
            result.entries.removeLast(result.entries.count - maxEntries)
            result.truncated = true
        }
    }

    // MARK: Scan-ahead

    /// Lists up to `scanAheadMaxChildren` child directories of `directory` in
    /// one round trip, each capped. Names are relative to `directory`.
    static func scanAheadCommand(
        directory: String,
        children: [String],
        maxEntriesPerChild: Int = scanAheadMaxEntriesPerChild
    ) -> (command: String, nonce: String) {
        let nonce = makeNonce()
        let names = children.prefix(scanAheadMaxChildren)
            .filter { !$0.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) && $0 != "." && $0 != ".." }
            .map(LoginShellCommand.singleQuoted)
            .joined(separator: " ")
        // Control records carry the nonce so no file name (`Z`, `D<tab>x`) can
        // pose as one. A child that vanished is skipped; one the user cannot
        // read is reported so the cache does not mistake it for empty.
        let script = environment
            + "printf '::RSDIR_\(nonce)::\\n'; "
            + "cd \(LoginShellCommand.singleQuoted(directory)) 2>/dev/null && for _d in \(names); do "
            + "[ -d \"./$_d\" ] || continue; printf '::D_\(nonce)::\\t%s\\n' \"$_d\"; "
            + "if [ -r \"./$_d\" ] && [ -x \"./$_d\" ]; then ls -1ApL \"./$_d\" 2>/dev/null | head -n \(maxEntriesPerChild + 1); "
            + "else printf '::E_\(nonce)::\\tdenied\\n'; fi; printf '::Z_\(nonce)::\\n'; done; "
            + "printf '::END_\(nonce)::\\n'; exit 0"
        return (LoginShellCommand.runInPOSIXShell(script), nonce)
    }

    /// Complete child listings keyed by child name. A child cut off by the
    /// transport (no end record) is dropped rather than cached as partial.
    static func parseScanAhead(
        output: String,
        nonce: String,
        directory: String,
        maxEntriesPerChild: Int = scanAheadMaxEntriesPerChild
    ) -> [String: DirectoryListingResult] {
        var results: [String: DirectoryListingResult] = [:]
        let startMarker = "::RSDIR_\(nonce)::"
        let endMarker = "::END_\(nonce)::"
        let childMarker = "::D_\(nonce)::\t"
        let errorMarker = "::E_\(nonce)::\t"
        let closeMarker = "::Z_\(nonce)::"
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)[...]
        guard let start = lines.firstIndex(where: { $0 == startMarker }) else { return results }
        lines = lines[(start + 1)...]
        var currentName: String?
        var current = DirectoryListingResult()
        for line in lines {
            if line == endMarker { break }
            if let name = currentName {
                if line == closeMarker {
                    applyCap(&current, maxEntries: maxEntriesPerChild)
                    current.complete = true
                    current.resolvedPath = PathCompletion.join(directory, name)
                    results[name] = current
                    currentName = nil
                    continue
                }
                if line.hasPrefix(errorMarker) {
                    current.error = error(from: String(line.dropFirst(errorMarker.count)))
                    continue
                }
                if line.isEmpty { continue }
                current.entries.append(entry(from: line))
                continue
            }
            if line.hasPrefix(childMarker) {
                currentName = String(line.dropFirst(childMarker.count))
                current = DirectoryListingResult()
            }
        }
        return results
    }

    // MARK: Helpers

    private static func entry(from line: Substring) -> DirectoryEntry {
        if line.hasSuffix("/") {
            return DirectoryEntry(name: String(line.dropLast()), isDirectory: true)
        }
        return DirectoryEntry(name: String(line), isDirectory: false)
    }

    private static func error(from value: String) -> DirectoryListingError {
        switch value {
        case "notfound": return .notFound
        case "notdir": return .notDirectory
        default: return .permissionDenied
        }
    }

    private static func makeNonce() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }
}
