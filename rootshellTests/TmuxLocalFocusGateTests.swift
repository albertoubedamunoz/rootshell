import XCTest

final class TmuxLocalFocusGateTests: XCTestCase {
    func testBounceEchoesAreSuppressedUntilLastReply() {
        var gate = TmuxLocalFocusGate()
        // A → B → C → B: echoes B, C, B arrive while selects are in flight.
        let first = gate.noteSent(windowId: 1, paneId: 1)
        let second = gate.noteSent(windowId: 1, paneId: 2)
        let third = gate.noteSent(windowId: 1, paneId: 1)
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 1))
        gate.noteCompleted(first)
        XCTAssertTrue(gate.suppresses(windowId: 1, paneId: 2))
        gate.noteCompleted(second)
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 1))
        gate.noteCompleted(third)
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 2))
    }

    func testEarlyEchoIsSuppressedWhileLaterSelectsPending() {
        var gate = TmuxLocalFocusGate()
        // A → B → C → D with B's echo landing before C and D are answered.
        let first = gate.noteSent(windowId: 1, paneId: 1)
        _ = gate.noteSent(windowId: 1, paneId: 2)
        _ = gate.noteSent(windowId: 1, paneId: 3)
        gate.noteCompleted(first)
        XCTAssertTrue(gate.suppresses(windowId: 1, paneId: 1))
        XCTAssertTrue(gate.suppresses(windowId: 1, paneId: 2))
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 3))
    }

    func testRemoteChangeAfterSettlePasses() {
        var gate = TmuxLocalFocusGate()
        let token = gate.noteSent(windowId: 1, paneId: 1)
        gate.noteCompleted(token)
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 7))
    }

    func testWindowsAreIndependent() {
        var gate = TmuxLocalFocusGate()
        _ = gate.noteSent(windowId: 1, paneId: 1)
        XCTAssertTrue(gate.suppresses(windowId: 1, paneId: 2))
        XCTAssertFalse(gate.suppresses(windowId: 2, paneId: 2))
    }

    func testRemoveClearsState() {
        var gate = TmuxLocalFocusGate()
        _ = gate.noteSent(windowId: 1, paneId: 1)
        _ = gate.noteSent(windowId: 2, paneId: 3)
        gate.remove(windowId: 1)
        XCTAssertFalse(gate.suppresses(windowId: 1, paneId: 2))
        XCTAssertTrue(gate.suppresses(windowId: 2, paneId: 4))
        gate.removeAll()
        XCTAssertFalse(gate.suppresses(windowId: 2, paneId: 4))
    }

    func testCompletionFromBeforeResetLeavesNewEntryArmed() {
        var gate = TmuxLocalFocusGate()
        let stale = gate.noteSent(windowId: 1, paneId: 1)
        gate.removeAll()
        _ = gate.noteSent(windowId: 1, paneId: 2)
        gate.noteCompleted(stale)
        XCTAssertTrue(gate.suppresses(windowId: 1, paneId: 1))
    }
}
