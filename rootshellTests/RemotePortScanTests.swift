import Foundation
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
        XCTAssertEqual(result.ports[0].bind, .any("*"))
        XCTAssertEqual(result.ports[1].bind, .any("*"))
        XCTAssertEqual(result.ports[2].bind, .loopback("127.0.0.1"))
    }

    func testParsesSSAndPrefersWildcardOverLoopback() {
        let result = RemotePortScanParser.parse(output("""
        L 4242 127.0.0.1:9090
        L 4300 0.0.0.0:3000
        L 4310 [::1]:8080
        L 4320 [::]:8081
        """), nonce: nonce)

        XCTAssertEqual(result.ports.map(\.number), [3000, 8080, 8081, 9090])
        XCTAssertEqual(result.ports[0].bind, .any("0.0.0.0"))
        XCTAssertEqual(result.ports[1].bind, .loopback("::1"))
        XCTAssertEqual(result.ports[2].bind, .any("::"))
        XCTAssertEqual(result.ports[3].bind, .loopback("127.0.0.1"))
    }

    func testTunnelDialsTheAddressTheSocketListensOn() {
        let ports = RemotePortScanParser.parse(output("""
        L 1 127.0.0.1:9090
        L 2 0.0.0.0:3000
        L 3 [::1]:8080
        L 4 192.168.1.9:7000
        L 5 127.0.0.2:8000
        L 6 [::]:8081
        L 7 [::ffff:127.0.0.1]:8082
        """), nonce: nonce).ports

        XCTAssertEqual(ports.map(\.number), [3000, 7000, 8000, 8080, 8081, 8082, 9090])
        XCTAssertEqual(
            ports.map(\.targetHost),
            ["127.0.0.1", "192.168.1.9", "127.0.0.2", "::1", "::1", "127.0.0.1", "127.0.0.1"]
        )
        XCTAssertEqual(ports[3].address, "[::1]:8080")
        XCTAssertEqual(ports[2].address, "127.0.0.2:8000")
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

    #if os(macOS)
    /// `Process` is unavailable on iOS; the shell-level check runs on macOS.
    func testScriptIsValidPOSIXShell() throws {
        let script = RemotePortScanCommand.script(nonce: nonce)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let input = Pipe()
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the remote shell must be able to parse the script")
    }
    #endif

    /// Ports are attributed to the connection that started them; a host whose
    /// process tree cannot be read keeps the unfiltered answer instead.
    func testScriptAttributesPortsToThisConnection() {
        let script = RemotePortScanCommand.script(nonce: nonce)
        XCTAssertTrue(script.contains("--RSLISTEN--"))
        XCTAssertTrue(script.contains("M conn"))
        XCTAssertTrue(script.contains("M all"))
        XCTAssertTrue(script.contains("sshd"))
        XCTAssertTrue(script.contains("ps -A -o pid=,ppid=,tty=,comm="))
    }

    func testUnfilteredScriptListsEveryPort() {
        let script = RemotePortScanCommand.script(nonce: nonce, filterOwnership: false)
        XCTAssertTrue(script.contains("M all"))
        XCTAssertFalse(script.contains("--RSLISTEN--"))
    }

    func testParserIgnoresOwnershipMarkers() {
        let result = RemotePortScanParser.parse(output("""
        M conn
        L 1 127.0.0.1:9090
        M all
        L 2 127.0.0.1:9091
        """), nonce: nonce)

        XCTAssertEqual(result.ports.map(\.number), [9090, 9091])
    }

    /// tmux/herdr/mosh detach their server, so ancestry cannot attribute; the
    /// scan must then keep the unfiltered answer.
    func testScriptFallsBackWhenTheSessionHasNoTTY() {
        let script = RemotePortScanCommand.script(nonce: nonce)
        XCTAssertTrue(script.contains("ps -A -o pid=,ppid=,tty=,comm="))
        XCTAssertTrue(script.contains("detached"))
    }

    /// The script is wrapped in single quotes for `sh -c`, so one stray
    /// apostrophe (in a comment, say) splits it and the remote shell runs
    /// garbage. The macOS-only `sh -n` test never runs on iOS, so check the
    /// quoting itself here.
    func testScriptKeepsItsShellQuotingBalanced() {
        let script = RemotePortScanCommand.script(nonce: nonce)
        XCTAssertEqual(script.filter { $0 == "'" }.count % 2, 0)
    }
}
