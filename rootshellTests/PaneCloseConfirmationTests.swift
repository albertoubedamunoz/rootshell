import XCTest

final class PaneCloseConfirmationTests: XCTestCase {
    func testPendingTargetSurvivesFocusOrderChangesButNotRemoval() {
        let target = UUID()
        let other = UUID()
        XCTAssertTrue(PaneCloseConfirmationPolicy.targetExists(
            pendingID: target, livePaneIDs: [target, other]))
        XCTAssertTrue(PaneCloseConfirmationPolicy.targetExists(
            pendingID: target, livePaneIDs: [other, target]))
        XCTAssertFalse(PaneCloseConfirmationPolicy.targetExists(
            pendingID: target, livePaneIDs: [other]))
        XCTAssertFalse(PaneCloseConfirmationPolicy.targetExists(
            pendingID: target, livePaneIDs: []))
        XCTAssertFalse(PaneCloseConfirmationPolicy.targetExists(
            pendingID: nil, livePaneIDs: [other]))
    }

    func testConfirmationRequiresEnabledSettingAndMultiplePanes() {
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: false, paneCount: 2))
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 0))
        XCTAssertFalse(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 1))
        XCTAssertTrue(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 2))
        XCTAssertTrue(PaneCloseConfirmationPolicy.shouldConfirm(isEnabled: true, paneCount: 4))
    }
}
