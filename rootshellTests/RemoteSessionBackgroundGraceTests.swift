import XCTest

final class RemoteSessionBackgroundGraceTests: XCTestCase {
    func testEligibleConnectionRequestsGraceWithoutOtherBackgroundModeInputs() {
        XCTAssertNil(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: true, sessionCount: 1, hasActiveTask: false))
        XCTAssertNil(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: true, sessionCount: 6, hasActiveTask: false))
    }

    func testUserOptOutIsRespected() {
        XCTAssertEqual(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: false, sessionCount: 1, hasActiveTask: false), .settingDisabled)
    }

    func testNoEligibleSessionsDoesNotRequestGrace() {
        for count in [0, -1] {
            XCTAssertEqual(RemoteSessionBackgroundGracePolicy.skipReason(
                isEnabled: true, sessionCount: count, hasActiveTask: false), .noSessions)
        }
    }

    func testExistingTaskPreventsDuplicateRequest() {
        XCTAssertEqual(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: true, sessionCount: 1, hasActiveTask: true), .alreadyActive)
    }

    func testSkipReasonPrecedenceIsPreserved() {
        XCTAssertEqual(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: false, sessionCount: 0, hasActiveTask: true), .settingDisabled)
        XCTAssertEqual(RemoteSessionBackgroundGracePolicy.skipReason(
            isEnabled: true, sessionCount: 0, hasActiveTask: true), .noSessions)
    }
}
