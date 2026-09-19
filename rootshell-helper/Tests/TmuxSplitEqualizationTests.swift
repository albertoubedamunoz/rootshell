import Darwin
import Foundation
import XCTest

/// Real protocol/geometry coverage lives in the native macOS XCTest target,
/// where Process is available. No user's tmux server or configuration is used.
@MainActor
final class TmuxSplitEqualizationTests: XCTestCase {
    private func pane(_ id: Int) -> TmuxLayoutNode {
        .pane(paneId: id, width: 1, height: 1, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        .split(direction: axis, children: children, width: 203, height: 69, x: 0, y: 0)
    }

    func testIssue475SixPanesGeometryAndZoomRoundTripOverControlMode() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        for id in 0...2 { try server.cli(["split-window", "-v", "-t", "%\(id)"]) }
        let control = try server.attach()
        defer { control.stop() }
        try control.command("resize-pane -t %3 -y 10")
        try control.command("resize-pane -t %4 -y 20")
        let layout = split(.horizontal, [
            split(.vertical, [pane(0), pane(3)]),
            split(.vertical, [pane(1), pane(4)]),
            split(.vertical, [pane(2), pane(5)])
        ])
        let expected = [
            "%0 0 0 67 34", "%3 0 35 67 34",
            "%1 68 0 67 34", "%4 68 35 67 34",
            "%2 136 0 67 34", "%5 136 35 67 34"
        ].sorted()
        XCTAssertNotEqual(try geometry(control), expected)
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try geometry(control), expected)
        // A shifted control reply FIFO would consume an empty resize reply here.
        XCTAssertEqual(try control.command("display-message -p reply-after-equalize"), "reply-after-equalize")
        let equalized = try control.command("display-message -p -t @0 '#{window_layout}'")
        try control.command("resize-pane -Z -t %0")
        try control.command("resize-pane -Z -t %0")
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"), equalized)
        XCTAssertEqual(try geometry(control), expected)

        // Exercise the previously broken two-command path while pane %0 is zoomed.
        try control.command("resize-pane -t %0 -x 90")
        try control.command("resize-pane -Z -t %0")
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"), "1:%0")
        XCTAssertEqual(try control.command("display-message -p reply-after-zoom"), "reply-after-zoom")
        try control.command("resize-pane -Z -t %0")
        XCTAssertEqual(try geometry(control), expected)
    }

    func testFullWidthJoinedPaneKeepsItsPosition() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["new-window", "-d", "-t", "equalize"])
        // On tmux 3.6, this produces traversal [0, 1, 2] but pane-list [0, 2, 1].
        try server.cli(["join-pane", "-f", "-v", "-s", "%2", "-t", "%0"])
        let control = try server.attach()
        defer { control.stop() }
        let layout = split(.vertical, [split(.horizontal, [pane(0), pane(1)]), pane(2)])
        try control.command("resize-pane -t %2 -y 10")
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try geometry(control), [
            "%0 0 0 101 34", "%1 102 0 101 34", "%2 0 35 203 34"
        ])
        XCTAssertEqual(try control.command("display-message -p still-aligned"), "still-aligned")
    }

    func testVerticalRoundingUsesServerCellSizes() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-v", "-t", "%0"])
        try server.cli(["split-window", "-v", "-t", "%1"])
        let control = try server.attach()
        defer { control.stop() }
        try control.command("refresh-client -C 10,12")
        let layout = split(.vertical, [pane(0), pane(1), pane(2)])
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        let rows = try geometry(control).map { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(rows.map { $0[0] }, ["%0", "%1", "%2"])
        XCTAssertEqual(rows.map { $0[3] }, ["10", "10", "10"])
        // One rounding cell, with two rows reserved for the tmux dividers.
        // tmux versions may assign that rounding cell to different children.
        XCTAssertEqual(rows.compactMap { Int($0[4]) }.sorted(), [3, 3, 4])
        XCTAssertEqual(rows.compactMap { Int($0[4]) }.reduce(0, +) + 2, 12)
    }

    func testConstrainedNestedLayoutDoesNotIssueSpreadOrHangServer() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-v", "-t", "%1"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        try server.cli(["split-window", "-h", "-t", "%3"])
        let control = try server.attach()
        defer { control.stop() }
        try control.command("refresh-client -C 8,5")
        try control.command("resize-pane -t %0 -x 2")
        let original = try geometry(control)
        XCTAssertEqual(original, [
            "%0 0 0 2 5", "%1 3 0 1 2", "%2 3 3 5 2",
            "%3 5 0 1 2", "%4 7 0 1 2"
        ])
        // Deliberately stale, roomy model dimensions: the preflight must use
        // the current server tree, not geometry from the last UI reconcile.
        let layout = split(.horizontal, [pane(0),
            split(.vertical, [split(.horizontal, [pane(1), pane(3), pane(4)]), pane(2)])
        ])
        for zoomed in [false, true] {
            if zoomed { try control.command("resize-pane -Z -t %0") }
            var spreads = 0
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { command in
                    if command.hasPrefix("select-layout") {
                        spreads += 1
                        // Never actually send a known server-hanging command,
                        // even if this regression reappears on tmux 3.6a.
                        throw NSError(domain: "UnsafeTmuxSpread", code: 1)
                    }
                    return try control.command(command)
                }
                XCTFail("Expected constrained layout rejection")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(spreads, 0)
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try control.command("display-message -p server-responsive"), "server-responsive")
            XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}'"), zoomed ? "1" : "0")
            if zoomed { try control.command("resize-pane -Z -t %0") }
            XCTAssertEqual(try geometry(control), original)
        }
    }

    private func geometry(_ control: ControlClient) throws -> [String] {
        try control.command("list-panes -t @0 -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'")
            .split(separator: "\n").map(String.init).sorted()
    }

    @MainActor
    private final class Server {
        let executable: String
        let directory: String
        var socket: String { directory + "/socket" }

        init() throws {
            guard let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw XCTSkip("tmux is not installed")
            }
            self.executable = executable
            directory = "/tmp/rs-equalize-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                try cli(["-f", "/dev/null", "new-session", "-d", "-s", "equalize", "-x", "203", "-y", "69", "/bin/sh"])
                try cli(["set-option", "-g", "status", "off"])
                try cli(["set-option", "-g", "aggressive-resize", "off"])
                try cli(["set-option", "-g", "window-size", "manual"])
                try cli(["resize-window", "-t", "@0", "-x", "203", "-y", "69"])
            } catch {
                stop()
                throw error
            }
        }

        @discardableResult
        func cli(_ arguments: [String]) throws -> String {
            try XCTUnwrap(LocalMultiplexerRecovery.run(executable, ["-S", socket] + arguments,
                environment: [:], deadline: Date().addingTimeInterval(5)), "tmux \(arguments)")
        }

        func attach() throws -> ControlClient {
            let client = try ControlClient(executable: executable, socket: socket)
            do {
                try client.command("refresh-client -C 203,69")
                try client.command("set-option -w -t @0 window-size latest")
                return client
            } catch {
                client.stop()
                throw error
            }
        }

        func stop() {
            try? cli(["kill-server"])
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// Like Ghostty's user-query queue, consume exactly one client reply per
    /// command. Subsequent marker queries make surplus/misaligned replies fail.
    @MainActor
    private final class ControlClient {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var buffered = Data()

        init(executable: String, socket: String) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-S", socket, "-C", "attach-session", "-t", "equalize"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TMUX")
            environment.removeValue(forKey: "TMUX_PANE")
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            // The initial attach comes from argv, so its block lacks the flag
            // tmux sets on subsequent commands read from the control pipe.
            do { _ = try reply(acceptAttach: true) } catch { stop(); throw error }
        }

        @discardableResult
        func command(_ command: String) throws -> String {
            try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            return try reply()
        }

        private func reply(acceptAttach: Bool = false) throws -> String {
            let deadline = Date().addingTimeInterval(5)
            var block: [String] = []
            var inReply = false
            while Date() < deadline {
                let line = try readLine(deadline: deadline)
                if line.hasPrefix("%begin ") {
                    // Flags bit 0 distinguishes our commands from server hooks.
                    let isClientReply = line.split(separator: " ").last.flatMap { Int($0) }.map { $0 & 1 != 0 } ?? false
                    inReply = acceptAttach || isClientReply
                    block = []
                } else if inReply && line.hasPrefix("%end ") {
                    return block.joined(separator: "\n")
                } else if inReply && line.hasPrefix("%error ") {
                    throw NSError(domain: "TmuxControlTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: block.joined(separator: "\n")])
                } else if inReply {
                    block.append(line)
                }
            }
            throw NSError(domain: "TmuxControlTest", code: 2)
        }

        private func readLine(deadline: Date) throws -> String {
            let fd = output.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                if let newline = buffered.firstIndex(of: 10) {
                    let line = String(decoding: buffered[..<newline], as: UTF8.self)
                    buffered.removeSubrange(...newline)
                    return line
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 50) < 0, errno != EINTR { break }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { break }
                else if errno != EAGAIN && errno != EINTR { break }
            }
            throw NSError(domain: "TmuxControlTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out or lost tmux control connection"])
        }

        func stop() {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            output.fileHandleForReading.closeFile()
        }
    }
}
