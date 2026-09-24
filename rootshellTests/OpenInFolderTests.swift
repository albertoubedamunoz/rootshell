import Foundation
import XCTest

/// Undoes LoginShellCommand.singleQuoted for a POSIX reader, so tests can
/// assert the script the remote `sh` actually parses.
private func unquoted(_ command: String) -> String {
    let prefix = "sh -c '"
    guard command.hasPrefix(prefix), command.hasSuffix("'") else { return command }
    var inner = String(command.dropFirst(prefix.count).dropLast())
    inner = inner.replacingOccurrences(of: "'\"\\\\\"'", with: "\\")
    inner = inner.replacingOccurrences(of: "'\"'\"'", with: "'")
    return inner
}

// MARK: - InitialDirectoryCommand

final class InitialDirectoryCommandTests: XCTestCase {
    func testSupportedDirectory() {
        XCTAssertTrue(InitialDirectoryCommand.isSupportedDirectory("/"))
        XCTAssertTrue(InitialDirectoryCommand.isSupportedDirectory("/srv/app"))
        XCTAssertFalse(InitialDirectoryCommand.isSupportedDirectory("srv/app"))
        XCTAssertFalse(InitialDirectoryCommand.isSupportedDirectory("/a\nb"))
        XCTAssertFalse(InitialDirectoryCommand.isSupportedDirectory("/a\0b"))
    }

    func testLoginShellWithoutCommand() {
        let command = InitialDirectoryCommand.execCommand(directory: "/srv/app", wrapping: nil)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertEqual(
            unquoted(command),
            "cd '/srv/app' 2>/dev/null || printf 'rootshell: cannot start in %s, using home\\n' '/srv/app' >&2; "
                + "exec \"${SHELL:-/bin/sh}\" -l")
    }

    func testWrappedCommandRunsThroughUserShell() {
        let command = InitialDirectoryCommand.execCommand(directory: "/srv/app", wrapping: "tmux new -A -s main")
        let script = unquoted(command)
        XCTAssertTrue(script.hasSuffix("exec \"${SHELL:-/bin/sh}\" -c 'tmux new -A -s main'"))
        XCTAssertFalse(script.contains("exec tmux"))
    }

    func testDirectoryQuotingRoundTrip() {
        let directory = "/srv/it's $HOME"
        let script = unquoted(InitialDirectoryCommand.execCommand(directory: directory, wrapping: nil))
        XCTAssertTrue(script.hasPrefix("cd '/srv/it'\"'\"'s $HOME' 2>/dev/null"), script)
    }

    func testMoshSessionCommand() {
        let command = InitialDirectoryCommand.moshSessionCommand(directory: "/srv/app", wrapping: "$SHELL -l")
        XCTAssertEqual(
            unquoted(command),
            "cd '/srv/app' 2>/dev/null || printf 'rootshell: cannot start in %s, using home\\n' '/srv/app' >&2; exec $SHELL -l")
    }
}

// MARK: - TmuxCommandQuoting

final class TmuxCommandQuotingTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(TmuxCommandQuoting.quoted("/a b"), "'/a b'")
        XCTAssertEqual(TmuxCommandQuoting.quoted("/a'b"), "'/a'\\''b'")
        XCTAssertEqual(TmuxCommandQuoting.quotedFormatLiteral("/a'b#c"), "'/a'\\''b##c'")
    }
}

// MARK: - TerminalTargetKey

final class TerminalTargetKeyTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(TerminalTargetKey.remote(username: "kit", host: "example.com", port: 22), "kit@example.com:22")
        XCTAssertEqual(TerminalTargetKey.local, "local")
    }
}

// MARK: - DirectoryTarget

final class DirectoryTargetTests: XCTestCase {
    func testResolve() {
        XCTAssertEqual(DirectoryTarget.resolve("", baseDirectory: "/home/kit"), .absolute("/home/kit"))
        XCTAssertEqual(DirectoryTarget.resolve("", baseDirectory: nil), .home)
        XCTAssertEqual(DirectoryTarget.resolve("~", baseDirectory: "/x"), .home)
        XCTAssertEqual(DirectoryTarget.resolve("~/", baseDirectory: "/x"), .home)
        XCTAssertEqual(DirectoryTarget.resolve("~/src/x/", baseDirectory: nil), .homeRelative("src/x"))
        XCTAssertEqual(DirectoryTarget.resolve("/usr//local/./bin/", baseDirectory: nil), .absolute("/usr/local/bin"))
        XCTAssertEqual(DirectoryTarget.resolve("src", baseDirectory: "/home/kit"), .absolute("/home/kit/src"))
        XCTAssertEqual(DirectoryTarget.resolve("../x", baseDirectory: "/a/b"), .absolute("/a/x"))
        XCTAssertEqual(DirectoryTarget.resolve("src", baseDirectory: nil), .homeRelative("src"))
        XCTAssertEqual(DirectoryTarget.resolve("~bob", baseDirectory: nil), .userHome(user: "bob", rest: ""))
        XCTAssertEqual(DirectoryTarget.resolve("~bob/x/y", baseDirectory: nil), .userHome(user: "bob", rest: "x/y"))
        XCTAssertNil(DirectoryTarget.resolve("~bad name/x", baseDirectory: nil))
        XCTAssertNil(DirectoryTarget.resolve("/a\nb", baseDirectory: nil))
    }

    func testShellExpressions() {
        XCTAssertEqual(DirectoryTarget.absolute("/a b/'c").shellExpression, "'/a b/'\"'\"'c'")
        XCTAssertEqual(DirectoryTarget.home.shellExpression, "\"$HOME\"")
        XCTAssertEqual(DirectoryTarget.homeRelative("x y").shellExpression, "\"$HOME\"'/x y'")
        XCTAssertEqual(DirectoryTarget.userHome(user: "bob", rest: "x").shellExpression, "~bob/'x'")
        XCTAssertEqual(DirectoryTarget.userHome(user: "bob", rest: "").shellExpression, "~bob")
    }
}

// MARK: - DirectoryListingProbe

final class DirectoryListingProbeTests: XCTestCase {
    func testScriptShape() {
        let (command, nonce) = DirectoryListingProbe.command(target: .absolute("/a b"), maxEntries: 10)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        let script = unquoted(command)
        XCTAssertTrue(script.contains("_t='/a b'; "))
        XCTAssertTrue(script.contains("::RSDIR_\(nonce)::"))
        XCTAssertTrue(script.contains("::END_\(nonce)::"))
        XCTAssertTrue(script.contains("ls -1ApL . 2>/dev/null | head -n 11"))
        XCTAssertTrue(script.hasSuffix("exit 0"))
        XCTAssertEqual(nonce.count, 8)
    }

    func testParseListing() {
        let nonce = "0badf00d"
        let output = """
        motd noise before the marker
        ::RSDIR_\(nonce)::
        H\t/home/kit
        P\t/home/kit/work
        L
        .git/
        Documents/
        a\tb
        name with spaces/
        README.md
        ünïcode/
        ::END_\(nonce)::

        """
        let result = DirectoryListingProbe.parse(output: output, nonce: nonce)
        XCTAssertEqual(result.home, "/home/kit")
        XCTAssertEqual(result.resolvedPath, "/home/kit/work")
        XCTAssertNil(result.error)
        XCTAssertTrue(result.complete)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.entries, [
            DirectoryEntry(name: ".git", isDirectory: true),
            DirectoryEntry(name: "Documents", isDirectory: true),
            DirectoryEntry(name: "a\tb", isDirectory: false),
            DirectoryEntry(name: "name with spaces", isDirectory: true),
            DirectoryEntry(name: "README.md", isDirectory: false),
            DirectoryEntry(name: "ünïcode", isDirectory: true),
        ])
        XCTAssertEqual(result.directories.map(\.name), [".git", "Documents", "name with spaces", "ünïcode"])
    }

    func testParseErrors() {
        for (code, expected) in [("notfound", DirectoryListingError.notFound), ("notdir", .notDirectory), ("denied", .permissionDenied)] {
            let output = "::RSDIR_n::\nH\t/root\nE\t\(code)\n::END_n::\n"
            let result = DirectoryListingProbe.parse(output: output, nonce: "n")
            XCTAssertEqual(result.error, expected)
            XCTAssertNil(result.resolvedPath)
            XCTAssertTrue(result.entries.isEmpty)
            XCTAssertTrue(result.complete)
        }
    }

    func testParseMissingStartMarkerAndMissingEnd() {
        XCTAssertEqual(DirectoryListingProbe.parse(output: "garbage", nonce: "n").error, .malformedResponse)
        let partial = DirectoryListingProbe.parse(output: "::RSDIR_n::\nP\t/x\nL\na/\nb/\n", nonce: "n")
        XCTAssertFalse(partial.complete)
        XCTAssertEqual(partial.entries.count, 2)
    }

    func testParseTruncationAndCRLF() {
        let output = "::RSDIR_n::\r\nP\t/x\r\nL\r\na/\r\nb/\r\nc/\r\n::END_n::\r\n"
        let result = DirectoryListingProbe.parse(output: output, nonce: "n", maxEntries: 2)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.entries.map(\.name), ["a", "b"])
        XCTAssertEqual(result.resolvedPath, "/x")
        XCTAssertTrue(result.complete)
    }

    func testEmptyHomeIsNil() {
        let result = DirectoryListingProbe.parse(output: "::RSDIR_n::\nH\t\nE\tnotfound\n::END_n::\n", nonce: "n")
        XCTAssertNil(result.home)
    }

    func testScanAheadCommandFiltersUnsafeNames() {
        let (command, nonce) = DirectoryListingProbe.scanAheadCommand(directory: "/home/kit", children: ["a", "..", "b\nc", "d e"])
        let script = unquoted(command)
        XCTAssertTrue(script.contains("cd '/home/kit' 2>/dev/null && for _d in 'a' 'd e'; do"))
        XCTAssertTrue(script.contains("head -n 301"))
        XCTAssertTrue(script.contains("printf '::D_\(nonce)::\\t%s\\n' \"$_d\""))
        XCTAssertTrue(script.contains("printf '::Z_\(nonce)::\\n'"))
    }

    func testParseScanAhead() {
        let nonce = "n"
        // Entries named like bare control words must stay ordinary entries.
        let output = """
        ::RSDIR_\(nonce)::
        ::D_\(nonce)::\tsrc
        main/
        lib.swift
        Z
        D\tfake
        ::Z_\(nonce)::
        ::D_\(nonce)::\tsecret
        ::E_\(nonce)::\tdenied
        ::Z_\(nonce)::
        ::D_\(nonce)::\tbig
        one/
        two/
        three/
        four/
        five/
        ::Z_\(nonce)::
        ::D_\(nonce)::\tcut
        partial/
        """
        let results = DirectoryListingProbe.parseScanAhead(output: output, nonce: nonce, directory: "/home/kit", maxEntriesPerChild: 4)
        XCTAssertEqual(Set(results.keys), ["src", "secret", "big"])
        XCTAssertEqual(results["src"]?.resolvedPath, "/home/kit/src")
        XCTAssertEqual(results["src"]?.entries.map(\.name), ["main", "lib.swift", "Z", "D\tfake"])
        XCTAssertEqual(results["src"]?.complete, true)
        XCTAssertEqual(results["secret"]?.error, .permissionDenied)
        XCTAssertEqual(results["big"]?.truncated, true)
        XCTAssertEqual(results["big"]?.entries.count, 4)
    }
}

// MARK: - DirectoryListingCache

final class DirectoryListingCacheTests: XCTestCase {
    private let key = DirectoryListingKey(targetKey: "kit@host:22", path: "/home/kit")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func listing(resolved: String? = "/home/kit", error: DirectoryListingError? = nil, truncated: Bool = false) -> DirectoryListingResult {
        var result = DirectoryListingResult()
        result.resolvedPath = resolved
        result.error = error
        result.truncated = truncated
        result.complete = true
        return result
    }

    func testFetchDedupeAndAccept() {
        var cache = DirectoryListingCache()
        XCTAssertEqual(cache.lookup(key, now: now), .miss)
        guard let generation = cache.beginFetch(key) else { return XCTFail("first fetch should dispatch") }
        XCTAssertNil(cache.beginFetch(key), "second fetch deduped")
        XCTAssertTrue(cache.isInFlight(key))
        XCTAssertTrue(cache.accept(listing(), for: key, dispatchedGeneration: generation, now: now))
        XCTAssertFalse(cache.isInFlight(key))
        XCTAssertEqual(cache.lookup(key, now: now), .fresh(.init(result: listing(), validatedAt: now)))
    }

    func testResolvedPathAlias() {
        var cache = DirectoryListingCache()
        let requested = DirectoryListingKey(targetKey: "t", path: "/home/kit/work/..")
        cache.store(listing(resolved: "/home/kit"), for: requested, now: now)
        XCTAssertNotEqual(cache.lookup(DirectoryListingKey(targetKey: "t", path: "/home/kit"), now: now), .miss)
        XCTAssertEqual(cache.lookup(DirectoryListingKey(targetKey: "other", path: "/home/kit"), now: now), .miss)
    }

    func testFreshStaleMissTimings() {
        var cache = DirectoryListingCache()
        cache.store(listing(), for: key, now: now)
        XCTAssertEqual(cache.lookup(key, now: now + 10), .fresh(.init(result: listing(), validatedAt: now)))
        XCTAssertEqual(cache.lookup(key, now: now + 30), .stale(.init(result: listing(), validatedAt: now)))
        XCTAssertEqual(cache.lookup(key, now: now + 11 * 60), .miss)
    }

    func testErrorsAndTruncationAreNeverFresh() {
        var cache = DirectoryListingCache()
        cache.store(listing(error: .notFound), for: key, now: now)
        XCTAssertEqual(cache.lookup(key, now: now + 5), .fresh(.init(result: listing(error: .notFound), validatedAt: now)))
        XCTAssertEqual(cache.lookup(key, now: now + 25), .miss)

        cache.store(listing(truncated: true), for: key, now: now)
        XCTAssertEqual(cache.lookup(key, now: now + 1), .stale(.init(result: listing(truncated: true), validatedAt: now)))
    }

    func testInvalidationRejectsLateAnswer() {
        var cache = DirectoryListingCache()
        let generation = cache.beginFetch(key)!
        cache.invalidate(key)
        XCTAssertFalse(cache.accept(listing(), for: key, dispatchedGeneration: generation, now: now))
        XCTAssertEqual(cache.lookup(key, now: now), .miss)
        XCTAssertFalse(cache.isInFlight(key))
    }

    func testEndFetchIgnoresSupersededGeneration() {
        var cache = DirectoryListingCache()
        let first = cache.beginFetch(key)!
        cache.invalidate(key)
        // The invalidated fetch is still in flight; releasing it makes room.
        cache.endFetch(key, dispatchedGeneration: first)
        XCTAssertFalse(cache.isInFlight(key))
        let second = cache.beginFetch(key)!
        XCTAssertNotEqual(first, second)
        cache.endFetch(key, dispatchedGeneration: first)
        XCTAssertTrue(cache.isInFlight(key), "a stale release must not clear a newer fetch")
    }

    func testInvalidateTargetAndEviction() {
        var cache = DirectoryListingCache()
        cache.store(listing(resolved: nil), for: key, now: now)
        cache.store(listing(resolved: nil), for: DirectoryListingKey(targetKey: "other", path: "/"), now: now)
        cache.invalidate(targetKey: key.targetKey)
        XCTAssertEqual(cache.lookup(key, now: now), .miss)
        XCTAssertNotEqual(cache.lookup(DirectoryListingKey(targetKey: "other", path: "/"), now: now), .miss)

        for index in 0..<(DirectoryListingCache.maxEntries + 5) {
            cache.store(listing(resolved: nil), for: DirectoryListingKey(targetKey: "t", path: "/\(index)"), now: now + TimeInterval(index))
        }
        XCTAssertEqual(cache.entries.count, DirectoryListingCache.maxEntries)
        XCTAssertNil(cache.entries[DirectoryListingKey(targetKey: "t", path: "/0")], "oldest evicted first")
    }
}

// MARK: - OpenInFolderRecents

final class OpenInFolderRecentsTests: XCTestCase {
    func testMostRecentFirstDedupedAndCapped() {
        var recents = OpenInFolderRecents()
        recents.record("/a", target: "t", capacity: 3)
        recents.record("/b", target: "t", capacity: 3)
        recents.record("/a", target: "t", capacity: 3)
        XCTAssertEqual(recents.paths(for: "t"), ["/a", "/b"])
        recents.record("/c", target: "t", capacity: 3)
        recents.record("/d", target: "t", capacity: 3)
        XCTAssertEqual(recents.paths(for: "t"), ["/d", "/c", "/a"])
        XCTAssertEqual(recents.paths(for: "other"), [])
    }

    func testRemoveAndCodable() {
        var recents = OpenInFolderRecents()
        recents.record("/a", target: "t")
        recents.record("/b", target: "u")
        recents.remove("/a", target: "t")
        XCTAssertEqual(recents.paths(for: "t"), [])
        let decoded = OpenInFolderRecents.decode(recents.encoded())
        XCTAssertEqual(decoded, recents)
        XCTAssertEqual(OpenInFolderRecents.decode(Data("junk".utf8)), OpenInFolderRecents())
        XCTAssertEqual(OpenInFolderRecents.decode(nil), OpenInFolderRecents())
    }
}

// MARK: - OpenInFolderPlacement

final class OpenInFolderPlacementTests: XCTestCase {
    func testAvailability() {
        XCTAssertEqual(OpenInFolderPlacement.available(supportsLeftUp: false), [.newTab, .splitRight, .splitDown])
        XCTAssertEqual(OpenInFolderPlacement.available(supportsLeftUp: true), OpenInFolderPlacement.allCases)
        XCTAssertFalse(OpenInFolderPlacement.newTab.isSplit)
        XCTAssertTrue(OpenInFolderPlacement.splitUp.isSplit)
    }
}
