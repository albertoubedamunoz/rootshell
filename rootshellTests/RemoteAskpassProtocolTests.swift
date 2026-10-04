import Foundation
import XCTest

nonisolated final class RemoteAskpassProtocolTests: XCTestCase {
    private let request = Data("ROOTSHELL-ASKPASS 1\nPROMPT [sudo] password for kit:\nCOMMAND sudo -A apt upgrade\nEND\n".utf8)

    func testParsesCompleteRequestAtEverySplit() throws {
        let expected = RemoteAskpassProtocol.Request(prompt: "[sudo] password for kit:", command: "sudo -A apt upgrade")
        for split in 0..<request.count {
            XCTAssertNil(try RemoteAskpassProtocol.parse(request.prefix(split)), "split \(split)")
        }
        XCTAssertEqual(try RemoteAskpassProtocol.parse(request), expected)
    }

    func testMissingFieldsAndUnknownKeys() throws {
        let data = Data("ROOTSHELL-ASKPASS 1\nFUTURE thing\nEND\n".utf8)
        XCTAssertEqual(try RemoteAskpassProtocol.parse(data), .init(prompt: "", command: ""))
    }

    func testCRLFLineEndings() throws {
        let data = Data("ROOTSHELL-ASKPASS 1\r\nPROMPT Token\r\nEND\r\n".utf8)
        XCTAssertEqual(try RemoteAskpassProtocol.parse(data)?.prompt, "Token")
    }

    func testRejectsWrongHeader() {
        for header in ["ROOTSHELL-ASKPASS 2", "GET / HTTP/1.1", ""] {
            XCTAssertThrowsError(try RemoteAskpassProtocol.parse(Data("\(header)\nEND\n".utf8))) {
                XCTAssertEqual($0 as? RemoteAskpassProtocol.ParseError, .malformed)
            }
        }
    }

    func testRejectsOversizedRequest() {
        let data = Data("ROOTSHELL-ASKPASS 1\nPROMPT ".utf8) + Data(repeating: 0x41, count: RemoteAskpassProtocol.maxRequestBytes)
        XCTAssertThrowsError(try RemoteAskpassProtocol.parse(data)) {
            XCTAssertEqual($0 as? RemoteAskpassProtocol.ParseError, .tooLarge)
        }
    }

    func testSanitizeStripsControlAndBidiCharacters() {
        XCTAssertEqual(RemoteAskpassProtocol.sanitize("a\u{1b}[31mb\tc"), "a [31mb c")
        XCTAssertEqual(RemoteAskpassProtocol.sanitize("rm\u{202E}fdp.exe"), "rmfdp.exe")
        XCTAssertEqual(RemoteAskpassProtocol.sanitize("  spaced   out  "), "spaced out")
    }

    func testSanitizeTruncates() {
        let long = String(repeating: "x", count: RemoteAskpassProtocol.maxFieldLength + 10)
        let result = RemoteAskpassProtocol.sanitize(Substring(long))
        XCTAssertEqual(result.count, RemoteAskpassProtocol.maxFieldLength + 1)
        XCTAssertTrue(result.hasSuffix("…"))
    }

    func testReplies() {
        XCTAssertEqual(RemoteAskpassProtocol.success("p@ss word"), Data("OK\np@ss word".utf8))
        XCTAssertEqual(RemoteAskpassProtocol.failure(.canceled), Data("ERR canceled\n".utf8))
        XCTAssertEqual(RemoteAskpassProtocol.failure(.protocolError), Data("ERR protocol\n".utf8))
    }
}
