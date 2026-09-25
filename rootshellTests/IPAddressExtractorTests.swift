import Foundation
import XCTest

final class IPAddressExtractorTests: XCTestCase {
    private func first(_ text: String) -> String? {
        IPAddressExtractor.firstAddress(in: text)
    }

    func testBareAddresses() {
        XCTAssertEqual(first("1.1.1.1"), "1.1.1.1")
        XCTAssertEqual(first("  203.0.113.7\n"), "203.0.113.7")
        XCTAssertEqual(first("2606:4700:4700::1111"), "2606:4700:4700::1111")
        XCTAssertEqual(first("::1"), "::1")
        XCTAssertEqual(first("::ffff:192.0.2.1"), "::ffff:192.0.2.1")
    }

    func testStripsPortsBracketsZonesAndPrefixes() {
        XCTAssertEqual(first("192.0.2.1:22"), "192.0.2.1")
        XCTAssertEqual(first("[2001:db8::1]:443"), "2001:db8::1")
        XCTAssertEqual(first("fe80::1%en0"), "fe80::1")
        XCTAssertEqual(first("10.0.0.0/8"), "10.0.0.0")
        XCTAssertEqual(first("2001:db8::/32"), "2001:db8::")
    }

    func testFindsAddressInsideText() {
        XCTAssertEqual(first("Accepted publickey for kit from 198.51.100.4 port 52144 ssh2"), "198.51.100.4")
        XCTAssertEqual(first("ssh root@192.0.2.10"), "192.0.2.10")
        XCTAssertEqual(first("https://[2001:db8::2]:8443/path"), "2001:db8::2")
        XCTAssertEqual(first("http://198.51.100.9:8080/health"), "198.51.100.9")
        XCTAssertEqual(first("Blocked 203.0.113.99."), "203.0.113.99")
        XCTAssertEqual(first("inet6 2001:db8::5, scope global"), "2001:db8::5")
    }

    func testRejectsNonAddresses() {
        XCTAssertNil(first(""))
        XCTAssertNil(first("hello world"))
        XCTAssertNil(first("256.1.1.1"))
        XCTAssertNil(first("1.2.3"))
        XCTAssertNil(first("1.2.3.4.5"))
        XCTAssertNil(first("12:30:45"))
        XCTAssertNil(first("aa:bb:cc:dd:ee:ff"))
        XCTAssertNil(first("std::vector"))
        XCTAssertNil(first("::"))
        XCTAssertNil(first("192.0.2.1:http"))
    }

    func testScansOnlyTheHead() {
        let padding = String(repeating: "x ", count: IPAddressExtractor.scanLimit)
        XCTAssertNil(first(padding + "192.0.2.1"))
    }
}
