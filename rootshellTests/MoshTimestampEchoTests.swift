import XCTest

final class MoshTimestampEchoTests: XCTestCase {
    func testNoReplyBeforeAnyServerTimestamp() {
        var echo = MoshTimestampEcho()
        XCTAssertEqual(echo.takeReply(nowMs: 5_000), MoshTimestampEcho.none)
    }

    func testReplyIsAdvancedByHoldTime() {
        var echo = MoshTimestampEcho()
        echo.save(1_000, receivedAtMs: 50_000)
        // Held 100 ms before acknowledgment: the server must not count that as RTT.
        XCTAssertEqual(echo.takeReply(nowMs: 50_100), 1_100)
    }

    func testReplyIsSentOnlyOnce() {
        var echo = MoshTimestampEcho()
        echo.save(1_000, receivedAtMs: 50_000)
        XCTAssertEqual(echo.takeReply(nowMs: 50_020), 1_020)
        // Heartbeats and later keystrokes must not re-echo the stale timestamp.
        XCTAssertEqual(echo.takeReply(nowMs: 53_000), MoshTimestampEcho.none)
    }

    func testStaleTimestampIsNotEchoed() {
        var echo = MoshTimestampEcho()
        echo.save(1_000, receivedAtMs: 50_000)
        XCTAssertEqual(echo.takeReply(nowMs: 50_999), 1_999)
        echo.save(2_000, receivedAtMs: 60_000)
        XCTAssertEqual(echo.takeReply(nowMs: 61_000), MoshTimestampEcho.none)
    }

    func testReplyWrapsAt16Bits() {
        var echo = MoshTimestampEcho()
        echo.save(0xFFF0, receivedAtMs: 70_000)
        XCTAssertEqual(echo.takeReply(nowMs: 70_032), 0x0010)
    }

    func testNewerServerTimestampReplacesOlder() {
        var echo = MoshTimestampEcho()
        echo.save(1_000, receivedAtMs: 50_000)
        echo.save(1_080, receivedAtMs: 50_080)
        XCTAssertEqual(echo.takeReply(nowMs: 50_090), 1_090)
    }

    func testNoTimestampSentinelIsIgnored() {
        var echo = MoshTimestampEcho()
        echo.save(1_000, receivedAtMs: 50_000)
        echo.save(MoshTimestampEcho.none, receivedAtMs: 50_050)
        XCTAssertEqual(echo.takeReply(nowMs: 50_060), 1_060)
    }
}
