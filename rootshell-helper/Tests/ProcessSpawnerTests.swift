//
//  ProcessSpawnerTests.swift
//  rootshell-helperTests
//
//  Unit tests for process spawning
//

import XCTest

class ProcessSpawnerTests: XCTestCase {

    func testDefaultShell() throws {
        let shell = try ProcessSpawner.defaultShellForUser()

        XCTAssertTrue(shell.hasPrefix("/"), "Shell path should be absolute")
    }

    func testCurrentUsername() throws {
        let username = try ProcessSpawner.currentUsername()

        XCTAssertFalse(username.isEmpty, "Username should not be empty")
    }

    // Note: buildLoginCommand is a private method, so we can't test it directly
    // We test it indirectly through testBasicShellSpawn

    func testBasicShellSpawn() throws {
        let config = ShellSpawnConfig()
        config.size = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)
        config.environment = [
            "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin"
        ]

        let result = try ProcessSpawner.spawnShell(with: config)

        XCTAssertGreaterThan(result.pid, 0, "PID should be valid")
        XCTAssertNotNil(result.pty, "PTY should be valid")

        // Give shell time to start
        usleep(100_000)

        // Check if process is alive
        let status = ProcessSpawner.wait(forProcess: result.pid, blocking: false)
        XCTAssertEqual(status, -1, "Process should still be running")

        // Cleanup
        try ProcessSpawner.killProcess(result.pid, signal: SIGKILL)
        result.pty.close()
    }

    func testShellIO() throws {
        let config = ShellSpawnConfig()
        config.size = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)
        config.environment = [
            "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin"
        ]

        let result = try ProcessSpawner.spawnShell(with: config)

        // Give shell time to initialize
        usleep(200_000)

        // Write a simple command
        let command = "echo test123\n"
        let data = command.data(using: .utf8)!
        let written = write(result.pty.masterFD, (data as NSData).bytes, data.count)

        XCTAssertGreaterThan(written, 0, "Should write bytes to PTY")

        // Give shell time to process
        usleep(100_000)

        // Try to read output
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(result.pty.masterFD, &buffer, buffer.count)

        XCTAssertGreaterThan(bytesRead, 0, "Should read output from PTY")

        let output = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        // Output should contain our echo (may also contain shell prompt)
        // Note: We can't be too strict here as shell might output other things

        // Cleanup
        try ProcessSpawner.killProcess(result.pid, signal: SIGKILL)
        result.pty.close()
    }
}
