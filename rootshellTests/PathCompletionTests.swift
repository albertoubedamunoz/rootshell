import Foundation
import XCTest

final class PathCompletionTests: XCTestCase {
    private let cwd = "/home/kit/work"
    private let home = "/home/kit"

    private func split(_ text: String) -> PathCompletion.Split {
        PathCompletion.split(text, cwd: cwd, home: home)
    }

    // MARK: normalize / parent / join

    func testNormalizeCollapsesDotsAndSlashes() {
        XCTAssertEqual(PathCompletion.normalize("/a//b/./c/../d/"), "/a/b/d")
        XCTAssertEqual(PathCompletion.normalize("/../"), "/")
        XCTAssertEqual(PathCompletion.normalize("/"), "/")
        XCTAssertEqual(PathCompletion.normalize(""), "")
        XCTAssertEqual(PathCompletion.normalize("a/../../b"), "../b")
        XCTAssertEqual(PathCompletion.normalize("~bob/x/../y/"), "~bob/y")
        XCTAssertEqual(PathCompletion.normalize("~bob/.."), "~bob")
    }

    func testParent() {
        XCTAssertEqual(PathCompletion.parent(of: "/"), "/")
        XCTAssertEqual(PathCompletion.parent(of: "/usr"), "/")
        XCTAssertEqual(PathCompletion.parent(of: "/usr/local/"), "/usr")
        XCTAssertEqual(PathCompletion.parent(of: "~bob"), "~bob")
        XCTAssertEqual(PathCompletion.parent(of: "~bob/x"), "~bob")
    }

    func testJoin() {
        XCTAssertEqual(PathCompletion.join("/", "usr"), "/usr")
        XCTAssertEqual(PathCompletion.join("/usr", "local"), "/usr/local")
        XCTAssertEqual(PathCompletion.join("", "x"), "x")
    }

    // MARK: split

    func testSplitTable() {
        XCTAssertEqual(split(""), .init(directory: cwd, prefix: ""))
        XCTAssertEqual(split("~"), .init(directory: home, prefix: ""))
        XCTAssertEqual(split("~/"), .init(directory: home, prefix: ""))
        XCTAssertEqual(split("~/pro"), .init(directory: home, prefix: "pro"))
        XCTAssertEqual(split("/usr/lo"), .init(directory: "/usr", prefix: "lo"))
        XCTAssertEqual(split("/usr/local/"), .init(directory: "/usr/local", prefix: ""))
        XCTAssertEqual(split("/"), .init(directory: "/", prefix: ""))
        XCTAssertEqual(split("/us"), .init(directory: "/", prefix: "us"))
        XCTAssertEqual(split("src/ma"), .init(directory: cwd + "/src", prefix: "ma"))
        XCTAssertEqual(split("ma"), .init(directory: cwd, prefix: "ma"))
        XCTAssertEqual(split("."), .init(directory: cwd, prefix: ""))
        XCTAssertEqual(split(".."), .init(directory: home, prefix: ""))
        XCTAssertEqual(split("../x"), .init(directory: home, prefix: "x"))
        XCTAssertEqual(split("~bob"), .init(directory: "~bob", prefix: ""))
        XCTAssertEqual(split("~bob/pr"), .init(directory: "~bob", prefix: "pr"))
    }

    func testExpandTildeOnlyBareOrSlash() {
        XCTAssertEqual(PathCompletion.expandTilde("~", home: home), home)
        XCTAssertEqual(PathCompletion.expandTilde("~/x", home: home), home + "/x")
        XCTAssertEqual(PathCompletion.expandTilde("~user/x", home: home), "~user/x")
        XCTAssertEqual(PathCompletion.expandTilde("a~", home: home), "a~")
    }

    func testEndsWithSeparator() {
        for text in ["~", "/", "a/", ".", "..", "a/..", "~bob"] {
            XCTAssertTrue(PathCompletion.endsWithSeparator(text), text)
        }
        for text in ["a", "~/a", "/usr/lo", ""] {
            XCTAssertFalse(PathCompletion.endsWithSeparator(text), text)
        }
    }

    // MARK: rank

    func testRankLadder() {
        XCTAssertEqual(PathCompletion.rank("docs", against: "docs"), .exact)
        XCTAssertEqual(PathCompletion.rank("docs", against: "Documents"), .subsequence)
        XCTAssertEqual(PathCompletion.rank("doc", against: "Documents"), .prefix)
        XCTAssertEqual(PathCompletion.rank("cum", against: "Documents"), .substring)
        XCTAssertEqual(PathCompletion.rank("dl", against: "Downloads"), .subsequence)
        XCTAssertNil(PathCompletion.rank("z", against: "Downloads"))
        XCTAssertNil(PathCompletion.rank("q", against: "Documents"), "single characters never match by subsequence")
        XCTAssertEqual(PathCompletion.rank("", against: "anything"), .prefix)
    }

    func testRankedFoldersOrdering() {
        let names = ["Documents", "docs", ".dotfiles", "Downloads", "build"]
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: "docs"), ["docs", "Documents"], "exact beats subsequence")
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: "do"), ["docs", "Documents", "Downloads", ".dotfiles"])
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: ".d"), [".dotfiles"])
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: "dl"), ["Downloads", ".dotfiles"], "dotfolders sink")
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: ""), ["build", "docs", "Documents", "Downloads", ".dotfiles"])
        XCTAssertEqual(PathCompletion.rankedFolders(names, prefix: "zz"), [])
    }

    // MARK: completion

    func testCompletedTextKeepsStyle() {
        XCTAssertEqual(
            PathCompletion.completedText(directory: home, name: "Documents", originalText: "~/Do", cwd: cwd, home: home),
            "~/Documents/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: home, name: "Documents", originalText: "/home/kit/Do", cwd: cwd, home: home),
            "/home/kit/Documents/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: cwd, name: "src", originalText: "sr", cwd: cwd, home: home),
            "src/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: cwd + "/src", name: "main", originalText: "src/ma", cwd: cwd, home: home),
            "src/main/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: home, name: "other", originalText: "../ot", cwd: cwd, home: home),
            "/home/kit/other/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: "~bob", name: "x", originalText: "~bob/", cwd: cwd, home: home),
            "~bob/x/")
        XCTAssertEqual(
            PathCompletion.completedText(directory: "/", name: "usr", originalText: "/u", cwd: cwd, home: home),
            "/usr/")
    }

    func testDisplayPath() {
        XCTAssertEqual(PathCompletion.displayPath("/home/kit/x", home: home), "~/x")
        XCTAssertEqual(PathCompletion.displayPath("/home/kit", home: home), "~")
        XCTAssertEqual(PathCompletion.displayPath("/home/kitten", home: home), "/home/kitten")
        XCTAssertEqual(PathCompletion.displayPath("/x", home: ""), "/x")
    }
}
