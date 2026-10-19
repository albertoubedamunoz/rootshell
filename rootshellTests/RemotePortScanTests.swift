import XCTest

final class RemotePortScanTests: XCTestCase {
    private let nonce = "abc12345"

    private func output(_ lines: String) -> String {
        "::RSPORTS_\(nonce)::\n\(lines)\n::END_\(nonce)::\n"
    }

    func testParsesLsofAndDeduplicatesSockets() {
        let result = RemotePortScanParser.parse(output("""
        L 637 *:49155
        L 637 *:49155
        L 650 127.0.0.1:14013
        L 692 *:7000
        L 692 *:5000
        127.0.0.1:9000
        """), nonce: nonce)

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.ports.map(\.number), [5000, 7000, 14013, 49155])
        XCTAssertEqual(result.ports[0].bind, .any)
        XCTAssertEqual(result.ports[1].bind, .any)
        XCTAssertEqual(result.ports[2].bind, .loopback)
    }

    func testParsesSSAndPrefersWildcardOverLoopback() {
        let result = RemotePortScanParser.parse(output("""
        L 4242 127.0.0.1:9090
        L 4300 0.0.0.0:3000
        L 4310 [::1]:8080
        L 4320 [::]:8081
        """), nonce: nonce)

        XCTAssertEqual(result.ports.map(\.number), [3000, 8080, 8081, 9090])
        XCTAssertEqual(result.ports[0].bind, .any)
        XCTAssertEqual(result.ports[1].bind, .loopback)
        XCTAssertEqual(result.ports[2].bind, .any)
        XCTAssertEqual(result.ports[3].bind, .loopback)
    }

    func testLoopbackBindsTunnelToLoopbackAndAnyBindsToLoopback() {
        let ports = RemotePortScanParser.parse(output("""
        L 1 127.0.0.1:9090
        L 2 0.0.0.0:3000
        L 3 [::1]:8080
        L 4 192.168.1.9:7000
        """), nonce: nonce).ports

        XCTAssertEqual(ports.map(\.targetHost), ["127.0.0.1", "192.168.1.9", "127.0.0.1", "127.0.0.1"])
    }

    func testTruncatedAndUnavailable() {
        let truncated = RemotePortScanParser.parse("::RSPORTS_\(nonce)::\nL 1 127.0.0.1:9090\n", nonce: nonce)
        XCTAssertFalse(truncated.complete)
        XCTAssertEqual(truncated.ports.map(\.number), [9090])

        let unavailable = RemotePortScanParser.parse(output("N\n"), nonce: nonce)
        XCTAssertTrue(unavailable.unavailable)
        XCTAssertTrue(unavailable.ports.isEmpty)
    }

    func testCapsAtThirtyTwoLowestPorts() {
        let lines = (1...40).map { "L 1 127.0.0.1:\($0 + 9000)" }.joined(separator: "\n") + "\n"
        let ports = RemotePortScanParser.parse(output(lines), nonce: nonce).ports
        XCTAssertEqual(ports.count, RemotePortScanParser.maxPorts)
        XCTAssertEqual(ports.first?.number, 9001)
        XCTAssertEqual(ports.last?.number, 9032)
    }

    func testIgnoresNoiseAndMalformedAddresses() {
        let result = RemotePortScanParser.parse(output("""
        ssh: connect to host example port 22: Connection refused
        L 1 127.0.0.1:0
        L 2 127.0.0.1:notaport
        L 3 :9090
        L 4 127.0.0.1:9091
        """), nonce: nonce)

        XCTAssertEqual(result.ports.map(\.number), [9091])
    }

    func testScanCommandRunsInAShellAndFramesItsAnswer() throws {
        let (command, generatedNonce) = RemotePortScanCommand.command()
        XCTAssertTrue(command.hasPrefix("sh -c "))
        XCTAssertTrue(command.contains("::RSPORTS_\(generatedNonce)::"))
        XCTAssertTrue(command.contains("::END_\(generatedNonce)::"))
    }
}
