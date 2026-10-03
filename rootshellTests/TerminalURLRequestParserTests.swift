import Foundation
import XCTest

nonisolated final class TerminalURLRequestParserTests: XCTestCase {
    private func request(_ url: String = "https://example.com/path?q=a&b=c#anchor", end: String = "\u{7}") -> Data {
        Data(("\u{1b}]1337;OpenURL=:" + Data(url.utf8).base64EncodedString() + end).utf8)
    }

    private func tmux(_ bytes: Data) -> Data {
        var out = Data("\u{1b}Ptmux;".utf8)
        for byte in bytes {
            out.append(byte)
            if byte == 0x1b { out.append(byte) }
        }
        out.append(Data("\u{1b}\\".utf8))
        return out
    }

    func testEverySplitAndBothTerminators() {
        for end in ["\u{7}", "\u{1b}\\"] {
            let bytes = request(end: end)
            for split in 0...bytes.count {
                var parser = TerminalURLRequestParser()
                let result = parser.consume(Data(bytes.prefix(split))) + parser.consume(Data(bytes.dropFirst(split)))
                XCTAssertEqual(result.map(\.absoluteString), ["https://example.com/path?q=a&b=c#anchor"])
            }
        }
    }

    func testTmuxByteByByteAndNestedWrappers() {
        for bytes in [tmux(request()), tmux(tmux(request(end: "\u{1b}\\")))] {
            var parser = TerminalURLRequestParser()
            var result: [URL] = []
            for byte in bytes { result += parser.consume(Data([byte])) }
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.host, "example.com")
        }
        var parser = TerminalURLRequestParser()
        XCTAssertTrue(parser.consume(tmux(tmux(tmux(request())))).isEmpty)
    }

    func testPlainOutputAndOtherOSCDoNotOpenURLs() {
        var parser = TerminalURLRequestParser()
        XCTAssertTrue(parser.consume(Data("https://example.com\u{1b}]8;;https://example.com\u{7}link\u{1b}]0;title\u{7}".utf8)).isEmpty)
        XCTAssertEqual(parser.consume(request()).count, 1)
        XCTAssertTrue(parser.consume(Data("more output".utf8)).isEmpty)
    }

    func testITermArgumentsAndOtherOSC1337Commands() {
        let encoded = Data("https://example.com".utf8).base64EncodedString()
        var parser = TerminalURLRequestParser()
        XCTAssertEqual(parser.consume(Data("\u{1b}]1337;OpenURL=future=1:\(encoded)\u{7}".utf8)).map(\.host), ["example.com"])
        for other in ["1337;OpenURL=\(encoded)", "1337;SetUserVar=url=\(encoded)", "1337;File=inline=1:\(encoded)", "777;rootshell;open-url;\(encoded)"] {
            XCTAssertTrue(parser.consume(Data("\u{1b}]\(other)\u{7}".utf8)).isEmpty, other)
        }
    }

    func testRequestsInsideOtherControlStringsAreIgnored() {
        for prefix in ["\u{1b}Pimage;", "\u{1b}_G", "\u{1b}^", "\u{1b}X"] {
            var parser = TerminalURLRequestParser()
            XCTAssertTrue(parser.consume(Data(prefix.utf8) + request() + Data("\u{1b}\\".utf8)).isEmpty)
            XCTAssertEqual(parser.consume(request()).count, 1)
        }
    }

    func testUnsafeAndMalformedURLsAreRejected() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "rootshell://ssh/host", "https:///", "https://user:pass@example.com", "https://example.com/\nnext", "https://example.com/a b"] {
            var parser = TerminalURLRequestParser()
            XCTAssertTrue(parser.consume(request(url)).isEmpty, url)
        }
        var parser = TerminalURLRequestParser()
        XCTAssertTrue(parser.consume(Data("\u{1b}]1337;OpenURL=:%%%\u{7}".utf8)).isEmpty)
        let invalidUTF8 = Data([0xff]).base64EncodedString()
        XCTAssertTrue(parser.consume(Data("\u{1b}]1337;OpenURL=:\(invalidUTF8)\u{7}".utf8)).isEmpty)
    }

    func testOversizedRequestRecoversAfterTerminator() {
        var parser = TerminalURLRequestParser()
        let bytes = Data("\u{1b}]1337;OpenURL=:".utf8) + Data(repeating: 0x41, count: 100_000)
        XCTAssertTrue(parser.consume(bytes).isEmpty)
        XCTAssertTrue(parser.consume(Data([0x07])).isEmpty)
        XCTAssertEqual(parser.consume(request()).count, 1)
    }

    func testCancelledAndInterruptedRequestsCannotInjectAnOSC() {
        for cancel: UInt8 in [0x18, 0x1a] {
            var parser = TerminalURLRequestParser()
            XCTAssertTrue(parser.consume(Data("\u{1b}]1337;OpenURL=:".utf8) + Data([cancel])).isEmpty)
            XCTAssertEqual(parser.consume(request()).count, 1)
        }
        var parser = TerminalURLRequestParser()
        XCTAssertTrue(parser.consume(Data("\u{1b}]bad".utf8) + request()).isEmpty)
        XCTAssertEqual(parser.consume(request()).count, 1)
    }

    func testMultipleRequestsAndUnicodeURL() {
        var parser = TerminalURLRequestParser()
        let result = parser.consume(request("https://example.com/caf%C3%A9") + request("http://localhost:3000/settings"))
        XCTAssertEqual(result.map(\.host), ["example.com", "localhost"])
    }
}
