import CoreGraphics
import XCTest

final class TerminalKeyboardGeometryTests: XCTestCase {
    func testDockingUsesWindowBottomIncludingNonzeroOrigin() {
        let window = CGRect(x: 80, y: 120, width: 600, height: 700)
        let keyboard = CGRect(x: 80, y: 520, width: 600, height: 300)
        XCTAssertTrue(TerminalKeyboardGeometry.isDocked(keyboard: keyboard, container: window))
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: window), 300)
    }

    func testAnotherWindowsKeyboardDoesNotCountAsCoverage() {
        let window = CGRect(x: 700, y: 100, width: 600, height: 700)
        let keyboard = CGRect(x: 0, y: 500, width: 600, height: 300)
        XCTAssertFalse(TerminalKeyboardGeometry.isDocked(keyboard: keyboard, container: window))
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: window), 0)
    }

    func testFloatingKeyboardDoesNotReserveFullWidth() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 900)
        let keyboard = CGRect(x: 460, y: 640, width: 320, height: 260)
        XCTAssertFalse(TerminalKeyboardGeometry.isDocked(keyboard: keyboard, container: window))
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: window), 0)
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: window, requireFullWidth: false), 260)
    }

    func testLowerTabletopInputDoesNotShrinkUpperTerminal() {
        let terminal = CGRect(x: 0, y: 0, width: 800, height: 420)
        let keyboard = CGRect(x: 0, y: 550, width: 800, height: 350)
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: terminal), 0)
    }

    func testOverlapClampsToTerminalBoundsAfterResize() {
        let terminal = CGRect(x: 20, y: 80, width: 760, height: 640)
        let keyboard = CGRect(x: 0, y: 550, width: 800, height: 350)
        XCTAssertEqual(TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: terminal), 170)
    }

    func testAccessoryHeightIncludedExactlyOnce() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 900)
        let keyboard = CGRect(x: 0, y: 600, width: 800, height: 300)
        let accessory = CGRect(x: 0, y: 556, width: 800, height: 44)
        let combined = TerminalKeyboardGeometry.includingAccessory(keyboard: keyboard, accessory: accessory, container: window)
        XCTAssertEqual(combined.height, 344)
        XCTAssertEqual(TerminalKeyboardGeometry.includingAccessory(keyboard: combined, accessory: accessory, container: window), combined)
    }

    func testInputRegionClipsAgainstAsymmetricSafeArea() {
        let safeBounds = CGRect(x: 24, y: 18, width: 776, height: 848)
        let lowerRegion = CGRect(x: 0, y: 470, width: 800, height: 430)
        XCTAssertEqual(TerminalKeyboardGeometry.inputRegion(lowerRegion, in: safeBounds),
                       CGRect(x: 24, y: 470, width: 776, height: 396))
        XCTAssertEqual(TerminalKeyboardGeometry.inputRegion(nil, in: safeBounds), safeBounds)
        XCTAssertEqual(TerminalKeyboardGeometry.inputRegion(CGRect(x: 0, y: 1000, width: 800, height: 100), in: safeBounds), .zero)
    }
}
