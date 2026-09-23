import XCTest

final class FileManagerLogicTests: XCTestCase {

    // MARK: - Paths

    func testJoinAndParent() {
        XCTAssertEqual(FileTransferLogic.join("/", "a"), "/a")
        XCTAssertEqual(FileTransferLogic.join("/a/", "b"), "/a/b")
        XCTAssertEqual(FileTransferLogic.join("/a", "/b"), "/a/b")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a/b"), "/a")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a"), "/")
        XCTAssertEqual(FileTransferLogic.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(FileTransferLogic.lastComponent(of: "/a/b/"), "b")
    }

    func testDestinationMapping() {
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir", sourceRoot: "/src/dir", destinationRoot: "/dst/dir"), "/dst/dir")
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir/x/y.txt", sourceRoot: "/src/dir", destinationRoot: "/dst/dir"), "/dst/dir/x/y.txt")
        // A sibling that merely shares a prefix is not inside the root.
        XCTAssertEqual(FileTransferLogic.destination(for: "/src/dir2/y", sourceRoot: "/src/dir", destinationRoot: "/dst"), "/dst/y")
    }

    func testSameOrDescendant() {
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b", of: "/a/b"))
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b/c", of: "/a/b"))
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant("/a/bc", of: "/a/b"))
    }

    // MARK: - Keep both

    func testKeepBothNames() {
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "report.pdf", existing: ["report.pdf"]), "report 2.pdf")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "report.pdf", existing: ["report.pdf", "report 2.pdf"]), "report 3.pdf")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "backup.tar.gz", existing: []), "backup 2.tar.gz")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: ".bashrc", existing: []), ".bashrc 2")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: "Makefile", existing: []), "Makefile 2")
        XCTAssertEqual(FileTransferLogic.keepBothName(for: ".config.yml", existing: []), ".config 2.yml")
    }

    func testKeepBothSkipsNamesOtherItemsInTheJobWillTake() {
        // Destination holds a.txt; the job brings a.txt and "a 2.txt".
        var names = TransferNamePlanner(incomingNames: ["a.txt", "a 2.txt"])
        XCTAssertEqual(names.claimKeepBothName(for: "a.txt", existingOnDisk: ["a.txt"]), "a 3.txt")
        XCTAssertFalse(names.isClaimed("a 2.txt"))
        names.claim("a 2.txt")
        XCTAssertEqual(names.claimKeepBothName(for: "a.txt", existingOnDisk: ["a.txt"]), "a 4.txt")
    }

    func testDuplicateIncomingNamesAreClaimed() {
        var names = TransferNamePlanner(incomingNames: ["x", "x"])
        XCTAssertFalse(names.isClaimed("x"))
        names.claim("x")
        XCTAssertTrue(names.isClaimed("x"))
        XCTAssertEqual(names.claimKeepBothName(for: "x", existingOnDisk: []), "x 2")
    }

    func testPathsOverlapEitherDirection() {
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d", "/d"))
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d", "/d/x"))
        XCTAssertTrue(FileTransferLogic.pathsOverlap("/d/x", "/d"))
        XCTAssertFalse(FileTransferLogic.pathsOverlap("/d/x", "/d/y"))
        XCTAssertFalse(FileTransferLogic.pathsOverlap("/d", "/dx"))
    }

    func testReplacingAnAncestorIsDetected() {
        // Moving /a/b/b into /a targets /a/b, which contains the source.
        XCTAssertTrue(FileTransferLogic.isSameOrDescendant("/a/b/b", of: "/a/b"))
        XCTAssertFalse(FileTransferLogic.isSameOrDescendant("/a/bb", of: "/a/b"))
    }

    // MARK: - Rate and throttle

    func testRateMeterSmoothsAndEstimates() {
        var meter = TransferRateMeter()
        XCTAssertNil(meter.eta(remainingBytes: 100))
        meter.record(totalBytes: 0, at: 0)
        meter.record(totalBytes: 1_000, at: 1)
        XCTAssertEqual(meter.bytesPerSecond, 1_000, accuracy: 0.001)
        meter.record(totalBytes: 3_000, at: 2)
        // 0.3 × 2000 + 0.7 × 1000
        XCTAssertEqual(meter.bytesPerSecond, 1_300, accuracy: 0.001)
        XCTAssertEqual(meter.eta(remainingBytes: 2_600) ?? 0, 2, accuracy: 0.001)
    }

    func testRateMeterIgnoresBackwardsSamples() {
        var meter = TransferRateMeter()
        meter.record(totalBytes: 500, at: 1)
        meter.record(totalBytes: 100, at: 2)
        XCTAssertEqual(meter.bytesPerSecond, 0)
    }

    func testPublishThrottle() {
        var throttle = PublishThrottle(interval: 0.1)
        XCTAssertTrue(throttle.shouldPublish(at: 0))
        XCTAssertFalse(throttle.shouldPublish(at: 0.05))
        XCTAssertTrue(throttle.shouldPublish(at: 0.05, force: true))
        XCTAssertFalse(throttle.shouldPublish(at: 0.1))
        XCTAssertTrue(throttle.shouldPublish(at: 0.16))
    }

    // MARK: - Selection

    private let paths = ["/a", "/b", "/c", "/d"]

    func testCursorMovesAndClamps() {
        var selection = FileListSelection()
        selection.moveCursor(by: 1, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/a")
        selection.moveCursor(by: 10, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/d")
        selection.moveCursor(by: -1, in: paths, extending: false)
        XCTAssertEqual(selection.cursor, "/c")
        XCTAssertTrue(selection.isEmpty)
    }

    func testShiftExtendsAndShrinksFromAnchor() {
        var selection = FileListSelection()
        selection.setCursor("/b")
        selection.moveCursor(by: 1, in: paths, extending: true)
        selection.moveCursor(by: 1, in: paths, extending: true)
        XCTAssertEqual(selection.selected, ["/b", "/c", "/d"])
        selection.moveCursor(by: -1, in: paths, extending: true)
        XCTAssertEqual(selection.selected, ["/b", "/c"])
    }

    func testClickModifiers() {
        var selection = FileListSelection()
        selection.click("/a", in: paths, modifier: .none)
        selection.click("/c", in: paths, modifier: .range)
        XCTAssertEqual(selection.selected, ["/a", "/b", "/c"])
        selection.click("/b", in: paths, modifier: .toggle)
        XCTAssertEqual(selection.selected, ["/a", "/c"])
        selection.click("/d", in: paths, modifier: .none)
        XCTAssertEqual(selection.selected, ["/d"])
    }

    func testEffectivePathsFallBackToCursorInListOrder() {
        var selection = FileListSelection()
        selection.setCursor("/b")
        XCTAssertEqual(selection.effectivePaths(in: paths), ["/b"])
        selection.toggle("/d")
        selection.toggle("/a")
        XCTAssertEqual(selection.effectivePaths(in: paths), ["/a", "/d"])
    }

    func testReconcileDropsVanishedPaths() {
        var selection = FileListSelection()
        selection.selectAll(paths)
        selection.setCursor("/d")
        selection.reconcile(with: ["/a", "/b"])
        XCTAssertEqual(selection.selected, ["/a", "/b"])
        XCTAssertEqual(selection.cursor, "/a")
    }

    // MARK: - sftp-server launcher

    func testLauncherQuotesAndOrdersCandidates() {
        let command = SFTPServerLauncher.command(preferredPath: "/opt/it's/sftp-server")
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        // The preferred path is tried first and survives quoting.
        let preferred = command.range(of: "/opt/it")
        let debian = command.range(of: "/usr/lib/openssh/sftp-server")
        XCTAssertNotNil(preferred)
        XCTAssertNotNil(debian)
        XCTAssertLessThan(preferred!.lowerBound, debian!.lowerBound)
        XCTAssertTrue(command.contains("exit \(SFTPServerLauncher.notFoundExitStatus)"))
    }

    func testShellQuote() {
        XCTAssertEqual(SFTPServerLauncher.shellQuote("a b"), "'a b'")
        XCTAssertEqual(SFTPServerLauncher.shellQuote("it's"), "'it'\\''s'")
    }
}
