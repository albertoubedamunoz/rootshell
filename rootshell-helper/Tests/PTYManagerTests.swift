//
//  PTYManagerTests.swift
//  rootshell-helperTests
//
//  Unit tests for PTY management
//

import XCTest

class PTYManagerTests: XCTestCase {

    func testPTYCreation() throws {
        // Test basic PTY creation
        let size = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)

        let pty = try PTYManagerImpl.createPTY(with: size)

        XCTAssertGreaterThan(pty.masterFD, 0, "Master FD should be valid")
        XCTAssertGreaterThan(pty.slaveFD, 0, "Slave FD should be valid")
        XCTAssertFalse(pty.slavePath.isEmpty, "Slave path should not be empty")
        XCTAssertTrue(pty.slavePath.hasPrefix("/dev/"), "Slave path should be in /dev/")

        pty.close()
    }

    func testPTYResize() throws {
        // Create PTY
        let initialSize = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)

        let pty = try PTYManagerImpl.createPTY(with: initialSize)

        // Resize it
        let newSize = PTYSize(rows: 30, cols: 100, xpixel: 0, ypixel: 0)
        try PTYManagerImpl.resizePTY(pty.masterFD, size: newSize)

        pty.close()
    }

    func testMultiplePTYs() throws {
        // Test creating multiple PTYs concurrently
        let size = PTYSize(rows: 24, cols: 80, xpixel: 0, ypixel: 0)
        var ptys: [PTYPair] = []

        for _ in 0..<5 {
            let pty = try PTYManagerImpl.createPTY(with: size)
            ptys.append(pty)
        }

        XCTAssertEqual(ptys.count, 5, "Should create 5 PTYs")

        // Cleanup
        for pty in ptys {
            pty.close()
        }
    }
}
