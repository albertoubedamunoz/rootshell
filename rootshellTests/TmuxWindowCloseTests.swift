import XCTest

final class TmuxWindowCloseTests: XCTestCase {
    func testReusedSurfaceCannotRouteToAnotherGateway() {
        let original = UUID()
        let replacement = UUID()
        XCTAssertFalse(TmuxWindowCloseState.matchesGateway(
            owner: replacement, bindingParent: original, tabOwner: original))
        XCTAssertFalse(TmuxWindowCloseState.matchesGateway(
            owner: replacement, bindingParent: original, tabOwner: nil))
        XCTAssertFalse(TmuxWindowCloseState.matchesGateway(
            owner: replacement, bindingParent: replacement, tabOwner: original))
        XCTAssertTrue(TmuxWindowCloseState.matchesGateway(
            owner: original, bindingParent: original, tabOwner: original))
        XCTAssertTrue(TmuxWindowCloseState.matchesGateway(
            owner: original, bindingParent: original, tabOwner: nil))
    }

    func testFailedKillRestoresWithoutAnotherTopologyUpdate() throws {
        var state = TmuxWindowCloseState()
        let request = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 3))
        XCTAssertTrue(state.contains(7))
        XCTAssertEqual(state.restore(windowID: 7, request: request), 3)
        XCTAssertFalse(state.contains(7))
        XCTAssertNil(state.restore(windowID: 7, request: request))
    }

    func testUnchangedTopologyDoesNotPreventTimeoutRollback() throws {
        var state = TmuxWindowCloseState()
        let request = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 3))
        state.prune(keeping: [7, 8])
        state.prune(keeping: [7, 8])
        XCTAssertTrue(state.contains(7))
        XCTAssertEqual(state.restore(windowID: 7, request: request), 3)
    }

    func testConfirmedLastWindowCloseCannotBeRestoredByLateTimeout() throws {
        var state = TmuxWindowCloseState()
        let request = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 1))
        state.prune(keeping: [])
        XCTAssertFalse(state.contains(7))
        XCTAssertNil(state.restore(windowID: 7, request: request))
    }

    func testClosingOneWindowDoesNotCancelAnotherPendingKill() throws {
        var state = TmuxWindowCloseState()
        let first = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 1))
        let second = try XCTUnwrap(state.begin(windowID: 8, tabIndex: 2))
        state.prune(keeping: [8])
        XCTAssertNil(state.restore(windowID: 7, request: first))
        XCTAssertEqual(state.restore(windowID: 8, request: second), 2)
    }

    func testDuplicateCloseDoesNotReplaceRequestAndLateReplyCannotUndoRetry() throws {
        var state = TmuxWindowCloseState()
        let first = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 1))
        XCTAssertNil(state.begin(windowID: 7, tabIndex: 2))
        XCTAssertEqual(state.restore(windowID: 7, request: first), 1)
        let retry = try XCTUnwrap(state.begin(windowID: 7, tabIndex: 4))
        XCTAssertNil(state.restore(windowID: 7, request: first))
        XCTAssertTrue(state.contains(7))
        XCTAssertEqual(state.restore(windowID: 7, request: retry), 4)
    }
}
