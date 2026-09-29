import XCTest

final class BackgroundExecutionPolicyTests: XCTestCase {
    func testOnlyProcessingTicksInTheBackground() {
        XCTAssertTrue(BackgroundExecutionPhase.processing.allowsBackgroundTick)
        for phase in [BackgroundExecutionPhase.foreground, .finalizing, .parked] {
            XCTAssertFalse(phase.allowsBackgroundTick, "\(phase)")
        }
    }

    func testTickAllowedWhilePresentableOrProcessing() {
        for phase in [BackgroundExecutionPhase.foreground, .processing, .finalizing, .parked] {
            XCTAssertTrue(BackgroundExecutionPolicy.allowsTick(isPresentationRevoked: false, phase: phase))
        }
        XCTAssertTrue(BackgroundExecutionPolicy.allowsTick(isPresentationRevoked: true, phase: .processing))
        // Resume window: phase is back to foreground but the gate hasn't opened.
        XCTAssertFalse(BackgroundExecutionPolicy.allowsTick(isPresentationRevoked: true, phase: .foreground))
        XCTAssertFalse(BackgroundExecutionPolicy.allowsTick(isPresentationRevoked: true, phase: .finalizing))
        XCTAssertFalse(BackgroundExecutionPolicy.allowsTick(isPresentationRevoked: true, phase: .parked))
    }

    func testBackgroundingPhaseFollowsTheTask() {
        XCTAssertEqual(BackgroundExecutionPolicy.phaseOnBackground(hasBackgroundTask: true), .processing)
        XCTAssertEqual(BackgroundExecutionPolicy.phaseOnBackground(hasBackgroundTask: false), .parked)
    }

    func testFinalizeDelayKeepsAMargin() {
        XCTAssertEqual(BackgroundExecutionPolicy.finalizeDelay(backgroundTimeRemaining: 30), 25)
        XCTAssertEqual(BackgroundExecutionPolicy.finalizeDelay(backgroundTimeRemaining: 3), 0)
    }

    func testUnboundedRemainingTimeNeedsNoFinalize() {
        XCTAssertNil(BackgroundExecutionPolicy.finalizeDelay(backgroundTimeRemaining: .greatestFiniteMagnitude))
        XCTAssertNil(BackgroundExecutionPolicy.finalizeDelay(backgroundTimeRemaining: .infinity))
    }

    func testTrzszOutputWritesThroughOnlyWhileProcessing() {
        typealias Policy = BackgroundExecutionPolicy
        XCTAssertEqual(Policy.trzszOutputRoute(
            isPresentationRevoked: false, phase: .foreground, expectsControlGateway: true), .writeThrough)
        XCTAssertEqual(Policy.trzszOutputRoute(
            isPresentationRevoked: true, phase: .processing, expectsControlGateway: false), .writeThrough)
        for phase in [BackgroundExecutionPhase.foreground, .finalizing, .parked] {
            XCTAssertEqual(Policy.trzszOutputRoute(
                isPresentationRevoked: true, phase: phase, expectsControlGateway: false), .buffer, "\(phase)")
        }
    }

    func testControlGatewayStaysBufferedInTheBackground() {
        XCTAssertEqual(BackgroundExecutionPolicy.trzszOutputRoute(
            isPresentationRevoked: true, phase: .processing, expectsControlGateway: true), .buffer)
    }

    private typealias Queue = BackgroundHeldQueue<Int, String>

    private static func focus(_ window: Int) -> HeldReconcileKind {
        .update(key: "focus:\(window)", coveredByFullSync: false)
    }

    private static func tabTitle(_ window: Int) -> HeldReconcileKind {
        .update(key: "tabTitle:\(window)", coveredByFullSync: true)
    }

    func testHeldQueueKeepsArrivalOrderForDistinctUpdates() {
        var queue = Queue()
        XCTAssertTrue(queue.append("a", owner: 1, kind: Self.focus(1)).isEmpty)
        XCTAssertTrue(queue.append("b", owner: 2, kind: Self.focus(1)).isEmpty)
        XCTAssertTrue(queue.append("c", owner: 1, kind: Self.tabTitle(1)).isEmpty)
        XCTAssertEqual(queue.drain().map(\.element), ["a", "b", "c"])
        XCTAssertTrue(queue.isEmpty)
    }

    func testUpdatesKeepOnlyTheLatestPerKey() {
        var queue = Queue()
        _ = queue.append("title-a", owner: 1, kind: Self.tabTitle(1))
        _ = queue.append("focus", owner: 1, kind: Self.focus(1))
        XCTAssertEqual(queue.append("title-b", owner: 1, kind: Self.tabTitle(1)), ["title-a"])
        XCTAssertEqual(queue.append("title-c", owner: 1, kind: Self.tabTitle(1)), ["title-b"])
        // Another gateway's same key is independent.
        XCTAssertTrue(queue.append("other", owner: 2, kind: Self.tabTitle(1)).isEmpty)
        XCTAssertEqual(queue.drain().map(\.element), ["focus", "title-c", "other"])
    }

    func testFullSyncSupersedesSyncsAndTitlesButKeepsFocusAfterIt() {
        var queue = Queue()
        _ = queue.append("sync1", owner: 1, kind: .fullSync)
        _ = queue.append("title", owner: 1, kind: Self.tabTitle(3))
        _ = queue.append("focus", owner: 1, kind: Self.focus(3))
        _ = queue.append("other", owner: 2, kind: .fullSync)
        XCTAssertEqual(queue.append("sync2", owner: 1, kind: .fullSync), ["sync1", "title"])
        XCTAssertEqual(queue.drain().map(\.element), ["other", "sync2", "focus"])
    }

    func testTeardownIsKeptAsABoundaryForAReattach() {
        var queue = Queue()
        _ = queue.append("sync-old-viewer", owner: 1, kind: .fullSync)
        _ = queue.append("focus-old", owner: 1, kind: Self.focus(1))
        XCTAssertEqual(queue.append("teardown", owner: 1, kind: .teardown),
                       ["sync-old-viewer", "focus-old"])
        // The reattach's sync must not reach back past the teardown.
        XCTAssertTrue(queue.append("sync-new-viewer", owner: 1, kind: .fullSync).isEmpty)
        XCTAssertTrue(queue.append("focus-new", owner: 1, kind: Self.focus(1)).isEmpty)
        XCTAssertEqual(queue.append("sync-newer", owner: 1, kind: .fullSync), ["sync-new-viewer"])
        XCTAssertEqual(queue.drain().map(\.element), ["teardown", "sync-newer", "focus-new"])
    }

    func testRepeatedDetachReattachStaysBounded() {
        var queue = Queue()
        for cycle in 0..<50 {
            _ = queue.append("teardown\(cycle)", owner: 1, kind: .teardown)
            _ = queue.append("sync\(cycle)", owner: 1, kind: .fullSync)
        }
        XCTAssertEqual(queue.drain().map(\.element), ["teardown49", "sync49"])
    }

    func testTitleChurnWithStableTopologyStaysBounded() {
        var queue = Queue()
        _ = queue.append("sync", owner: 1, kind: .fullSync)
        for index in 0..<1_000 {
            _ = queue.append("title\(index)", owner: 1, kind: Self.tabTitle(index % 3))
            _ = queue.append("focus\(index)", owner: 1, kind: Self.focus(index % 3))
        }
        XCTAssertEqual(queue.entries.count, 7)
    }

    func testCapDropsTheOldestUpdatesFirst() {
        var queue = Queue(maxEntries: 3)
        _ = queue.append("sync", owner: 1, kind: .fullSync)
        _ = queue.append("u1", owner: 1, kind: .update(key: "1", coveredByFullSync: false))
        _ = queue.append("u2", owner: 1, kind: .update(key: "2", coveredByFullSync: false))
        XCTAssertEqual(queue.append("u3", owner: 1, kind: .update(key: "3", coveredByFullSync: false)), ["u1"])
        XCTAssertEqual(queue.drain().map(\.element), ["sync", "u2", "u3"])
    }
}
