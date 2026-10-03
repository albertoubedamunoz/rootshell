import Foundation
import XCTest

nonisolated final class TerminalClipboardURLRequestTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"

    private func envelope(timestamp: Int = 1000, id: String? = nil, url: String = "https://example.com/path?q=a&b=c#anchor") -> String {
        "\(TerminalClipboardURLRequest.prefix)\(timestamp):\(id ?? self.id):\(url)"
    }

    func testFreshEnvelopeAndUnsafeTargets() throws {
        let request = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope()))
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.url.absoluteString, "https://example.com/path?q=a&b=c#anchor")
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https:///", "https://user:pass@example.com", "https://example.com/a b", "https://example.com/\nnext"] {
            XCTAssertNil(TerminalClipboardURLRequest.decode(envelope(url: url)))
        }
    }

    /// Mosh suppression keys on this: reserved envelopes, including invalid or
    /// future versions, never reach the clipboard; ordinary copies always do.
    func testReservedClipboardStateRecognition() {
        for text in [envelope(), "rootshell-open-url:v2:anything", "rootshell-open-url:"] {
            XCTAssertTrue(TerminalClipboardURLRequest.isReservedClipboardState(Data(text.utf8).base64EncodedString()), text)
        }
        for text in ["ordinary clipboard text", "https://example.com", "rootshell-open-url"] {
            XCTAssertFalse(TerminalClipboardURLRequest.isReservedClipboardState(Data(text.utf8).base64EncodedString()), text)
        }
        XCTAssertFalse(TerminalClipboardURLRequest.isReservedClipboardState("not base64 %%%"))
    }

    func testMalformedEnvelopeAndUnrelatedClipboard() {
        for text in ["ordinary clipboard contents", "https://example.com", "rootshell-open-url:v2:1000:\(id):https://example.com", envelope(id: "invalid"), envelope(id: String(repeating: "g", count: 32)), envelope(timestamp: -1), "\(TerminalClipboardURLRequest.prefix)NaN:\(id):https://example.com", envelope(url: String(repeating: "a", count: 20_000))] {
            XCTAssertNil(TerminalClipboardURLRequest.decode(text), text.prefix(100).description)
        }
    }

    func testExpiryAndFutureClockSkew() throws {
        let request = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope()))
        XCTAssertTrue(request.isFresh(at: 995))
        XCTAssertFalse(request.isFresh(at: 994))
        XCTAssertTrue(request.isFresh(at: 1060))
        XCTAssertFalse(request.isFresh(at: 1061))
    }

    func testReplaySuppressionSurvivesAppRestart() throws {
        let request = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope()))
        var ledger = TerminalURLRequestLedger()
        XCTAssertTrue(ledger.consume(request, now: 1000))
        var restored = TerminalURLRequestLedger(data: ledger.data)
        XCTAssertFalse(restored.consume(request, now: 1001))
        XCTAssertFalse(restored.consume(request, now: 1061))
    }

    func testRepeatedURLWithNewIDIsANewRequest() throws {
        let first = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope()))
        let second = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope(id: String(repeating: "a", count: 32))))
        var ledger = TerminalURLRequestLedger()
        XCTAssertTrue(ledger.consume(first, now: 1000))
        XCTAssertTrue(ledger.consume(second, now: 1001))
        XCTAssertEqual(first.url, second.url)
    }

    func testFullLedgerDoesNotEvictUnexpiredID() throws {
        var ledger = TerminalURLRequestLedger()
        for index in 0..<TerminalURLRequestLedger.capacity {
            let request = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope(id: String(format: "%032x", index))))
            XCTAssertTrue(ledger.consume(request, now: 1000))
        }
        let overflow = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope()))
        XCTAssertFalse(ledger.consume(overflow, now: 1001))
        let first = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope(id: String(repeating: "0", count: 32))))
        XCTAssertFalse(ledger.consume(first, now: 1001))
        let fresh = try XCTUnwrap(TerminalClipboardURLRequest.decode(envelope(timestamp: 1061)))
        XCTAssertTrue(ledger.consume(fresh, now: 1061))
        XCTAssertEqual(ledger.expirations.count, 1)
    }
}
