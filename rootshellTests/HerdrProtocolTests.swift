import Foundation
import XCTest

final class HerdrProtocolTests: XCTestCase {

    // MARK: Version requirement

    func testVersionsBelowMinimumAreRefused() {
        XCTAssertThrowsError(try HerdrVersionRequirement.validate("0.8.9"))
        XCTAssertThrowsError(try HerdrVersionRequirement.validate(nil))
        XCTAssertThrowsError(try HerdrVersionRequirement.validate("garbage"))
    }

    func testForkAndBuildSuffixesPass() throws {
        XCTAssertEqual(try HerdrVersionRequirement.validate("0.9.0"), "0.9.0")
        XCTAssertEqual(try HerdrVersionRequirement.validate("0.9.0-rootshell.0.1.2"), "0.9.0-rootshell.0.1.2")
        XCTAssertEqual(try HerdrVersionRequirement.validate("1.0.0+build.7"), "1.0.0+build.7")
    }

    func testVersionErrorStripsControlCharacters() {
        let error = HerdrVersionError(reported: "0.1.0\u{1b}[31m")
        XCTAssertFalse(error.localizedDescription.contains("\u{1b}"))
        XCTAssertTrue(error.localizedDescription.contains("0.1.0"))
    }

    // MARK: Capabilities

    func testProtocolOneServerIsNotShared() {
        let caps = HerdrServerCapabilities(HerdrControl.Capabilities(terminal_control_stream: 1, server_pid: 4, live_handoff: true, control_features: nil))
        XCTAssertTrue(caps.hasControlStream)
        XCTAssertFalse(caps.supportsSharedViewing)
        XCTAssertFalse(caps.supports(.controlList))
        XCTAssertEqual(caps.serverPid, 4)
    }

    func testFeatureListWinsOverStreamNumber() {
        let partial = HerdrServerCapabilities(HerdrControl.Capabilities(
            terminal_control_stream: 2, server_pid: nil, live_handoff: nil,
            control_features: ["shared_attach", "geometry_ownership"]))
        XCTAssertFalse(partial.supportsSharedViewing)
        let full = HerdrServerCapabilities(HerdrControl.Capabilities(
            terminal_control_stream: 2, server_pid: nil, live_handoff: nil,
            control_features: ["shared_attach", "geometry_ownership", "geometry_controller", "control_list", "mystery"]))
        XCTAssertTrue(full.supportsSharedViewing)
        XCTAssertTrue(full.supports(.controlList))
        let numberOnly = HerdrServerCapabilities(HerdrControl.Capabilities(
            terminal_control_stream: 1, server_pid: nil, live_handoff: nil,
            control_features: ["shared_attach", "geometry_ownership", "geometry_controller"]))
        XCTAssertFalse(numberOnly.supportsSharedViewing)
    }

    func testMissingCapabilitiesMeanNoStream() {
        XCTAssertFalse(HerdrServerCapabilities(nil).hasControlStream)
        XCTAssertEqual(HerdrServerCapabilities(nil), .none)
    }

    // MARK: Decoding

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try HerdrControl.decoder.decode(type, from: Data(json.utf8))
    }

    func testControlOpenedDecodesOldAndNewShapes() throws {
        let old = try decode(HerdrControl.Response<HerdrControl.ControlOpened>.self, #"""
        {"id":"c","result":{"connection_id":1099511627777,"boot_id":"b1","version":"0.9.0-rootshell.0.1.2","protocol":22,
         "capabilities":{"terminal_control_stream":1,"server_pid":12}}}
        """#).result
        XCTAssertNil(old.control_protocol)
        XCTAssertEqual(old.capabilities?.terminal_control_stream, 1)
        let new = try decode(HerdrControl.Response<HerdrControl.ControlOpened>.self, #"""
        {"id":"c","result":{"connection_id":1,"boot_id":"b2","version":"0.9.0","protocol":22,"control_protocol":2,
         "capabilities":{"terminal_control_stream":2,"control_features":["shared_attach"],"unknown_field":true},"extra":1}}
        """#).result
        XCTAssertEqual(new.control_protocol, 2)
        XCTAssertEqual(new.capabilities?.control_features, ["shared_attach"])
    }

    func testLayoutSnapshotWithAndWithoutController() throws {
        let base = #""workspace_id":"w","tab_id":"t","zoomed":false,"area":{"x":0,"y":0,"width":80,"height":24},"focused_pane_id":"p","panes":[{"pane_id":"p","focused":true,"rect":{"x":0,"y":0,"width":80,"height":24}}],"splits":[]"#
        let plain = try decode(HerdrControl.LayoutSnapshot.self, "{\(base)}")
        XCTAssertFalse(plain.carriesRealGeometry)
        XCTAssertNil(plain.geometry_controller)
        let owned = try decode(HerdrControl.LayoutSnapshot.self,
            "{\(base),\"geometry_controller\":{\"kind\":\"control\",\"connection_id\":7,\"chrome\":\"none\"}}")
        XCTAssertTrue(owned.carriesRealGeometry)
        XCTAssertEqual(owned.geometry_controller?.connection_id, 7)
        XCTAssertEqual(owned.geometry_controller?.kind, "control")
        // Ownership metadata does not make two identical layouts differ.
        XCTAssertNotEqual(plain, owned)
        XCTAssertEqual(plain.panes, owned.panes)
    }

    func testRecordsAndEventsRoute() throws {
        let layout = HerdrControl.decodeInbound(Data(#"{"type":"tab.layout","layout":{"workspace_id":"w","tab_id":"t","zoomed":false,"area":{"x":0,"y":0,"width":10,"height":5},"focused_pane_id":"p","panes":[],"splits":[],"geometry_controller":{"kind":"none"}}}"#.utf8))
        guard case .tabLayout(let snapshot)? = layout else { return XCTFail("expected tab.layout") }
        XCTAssertEqual(snapshot.geometry_controller?.kind, "none")

        let changed = HerdrControl.decodeInbound(Data(#"{"event":"tab_geometry_changed","data":{"type":"tab_geometry_changed","tab_id":"t","workspace_id":"w","geometry_controller":{"kind":"client","connection_id":3,"chrome":"server"},"previous":{"kind":"control","connection_id":9,"chrome":"none"}}}"#.utf8))
        guard case .tabGeometryChanged(let data)? = changed else { return XCTFail("expected tab_geometry_changed") }
        XCTAssertEqual(data.geometry_controller?.kind, "client")
        XCTAssertEqual(data.previous?.connection_id, 9)

        guard case .authority(let authority)? = HerdrControl.decodeInbound(Data(#"{"type":"terminal.authority","attach_id":"1-0","answers_queries":false}"#.utf8)) else {
            return XCTFail("expected terminal.authority")
        }
        XCTAssertFalse(authority.answers_queries)

        guard case .eventsGap(let gap)? = HerdrControl.decodeInbound(Data(#"{"type":"events.gap","dropped":37,"resume_sequence":9120}"#.utf8)) else {
            return XCTFail("expected events.gap")
        }
        XCTAssertEqual(gap.dropped, 37)

        guard case .unknown? = HerdrControl.decodeInbound(Data(#"{"type":"terminal.future"}"#.utf8)) else {
            return XCTFail("unknown record must not decode as something else")
        }
        XCTAssertNil(HerdrControl.decodeInbound(Data(#"{"id":"r1","result":{}}"#.utf8)))
    }

    func testControlListDecodes() throws {
        let list = try decode(HerdrControl.Response<HerdrControl.ControlListResult>.self, #"""
        {"id":"l","result":{"type":"control_list","self_connection_id":1,"connections":[
          {"connection_id":1,"control_protocol":2,"client":{"name":"rootshell","version":"1.0.13","protocol":2},
           "attaches":[{"attach_id":"1-0","terminal_id":"x","pane_id":"p","geometry":"tab","answer_queries":"client","answers_queries":true}],
           "tabs":[{"tab_id":"t","cols":120,"rows":40,"cell_width_px":8,"cell_height_px":16,"chrome":"none","controller":true}]},
          {"connection_id":2,"control_protocol":1}]}}
        """#).result
        XCTAssertEqual(list.self_connection_id, 1)
        XCTAssertEqual(list.connections.count, 2)
        XCTAssertEqual(list.connections[0].displayLabel, "rootshell 1.0.13")
        XCTAssertEqual(list.connections[0].tabs?.first?.controller, true)
        XCTAssertEqual(list.connections[1].displayLabel, "connection #2")
    }

    func testGeometryParamsOmitClaimWhenNil() throws {
        var params = HerdrControl.TabGeometryParams(tab_id: "t", cols: 1, rows: 2, cell_width_px: 3, cell_height_px: 4)
        var json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        XCTAssertFalse(json.contains("claim"))
        params.claim = false
        json = String(decoding: try JSONEncoder().encode(params), as: UTF8.self)
        XCTAssertTrue(json.contains("\"claim\":false"))
    }

    // MARK: Initial layout bootstrap

    /// A foreign owner's size stays fixed: no server layout or user input
    /// arrives to rescue a frame calculated before surface creation.
    @MainActor
    func testInitialLayoutRefreshWaitsForSurfaceMetrics() async {
        @MainActor final class SurfaceMetrics {
            var cellPixels: UInt32 = 0
        }
        let metrics = SurfaceMetrics()
        let refresh = HerdrLayoutRefresh()
        var frameWidth: CGFloat = 390
        var refreshes = 0
        let refreshed = expectation(description: "initial layout refreshed")
        refresh.request {
            refreshes += 1
            // The deferred pass can now lay out all 120 server columns
            // on the phone, overflowing its viewport until input claims.
            frameWidth = HerdrGeometry.requiredExtent(
                cells: 120, cellPixels: metrics.cellPixels, chrome: 8, scale: 3)
            refreshed.fulfill()
        }
        XCTAssertEqual(refreshes, 0)
        // Insertion creates the surface after the first frame calculation.
        metrics.cellPixels = 24
        refresh.request { XCTFail("cell callback should coalesce with insertion") }
        await fulfillment(of: [refreshed], timeout: 2)
        withExtendedLifetime(refresh) {}
        XCTAssertEqual(refreshes, 1)
        XCTAssertGreaterThan(frameWidth, 390)
        XCTAssertEqual(HerdrGeometry.cellBudget(extent: frameWidth, chrome: 8, cell: 8), 120)
    }

    @MainActor
    func testDismantledHostCancelsPendingLayoutRefresh() async {
        let refresh = HerdrLayoutRefresh()
        let refreshed = expectation(description: "replacement layout refreshed")
        refresh.request { XCTFail("a dismantled host must not refresh its old panes") }
        refresh.cancel()
        // A host reused before the old callback runs still gets its own
        // refresh; the cancelled callback cannot consume the new request.
        refresh.request { refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 2)
        withExtendedLifetime(refresh) {}
    }

    @MainActor
    func testLaterCellMetricsCanScheduleAnotherLayoutRefresh() async {
        let refresh = HerdrLayoutRefresh()
        var refreshes = 0
        for _ in 0..<2 {
            let refreshed = expectation(description: "cell metrics refreshed")
            refresh.request {
                refreshes += 1
                refreshed.fulfill()
            }
            await fulfillment(of: [refreshed], timeout: 2)
        }
        withExtendedLifetime(refresh) {}
        XCTAssertEqual(refreshes, 2)
    }

    // MARK: Tab geometry ownership

    private let size = HerdrTabGeometryState.Size(cols: 100, rows: 40, cellWidth: 8, cellHeight: 16)

    func testUnknownOwnershipBehavesLikeSoleClient() {
        var state = HerdrTabGeometryState()
        state.update(size)
        XCTAssertTrue(state.mayClaim)
        let request = state.beginRequest()
        XCTAssertNotNil(request)
        XCTAssertTrue(state.finish(request!, succeeded: true))
        XCTAssertTrue(state.isConfirmed)
    }

    func testLosingTheTabInvalidatesConfirmation() {
        var state = HerdrTabGeometryState()
        state.update(size)
        let request = state.beginRequest()!
        state.finish(request, succeeded: true)
        XCTAssertTrue(state.setOwnership(.other(connectionId: 5, kind: "control")))
        XCTAssertFalse(state.mayClaim)
        XCTAssertFalse(state.isConfirmed)
        XCTAssertEqual(state.desired, size)
        // Store-only pushes still run while owned elsewhere.
        XCTAssertNotNil(state.beginRequest())
    }

    func testRegainingTheTabRequiresAFreshPush() {
        var state = HerdrTabGeometryState()
        state.update(size)
        state.setOwnership(.other(connectionId: 5, kind: "control"))
        let stored = state.beginRequest()!
        state.finish(stored, succeeded: true)
        XCTAssertTrue(state.isConfirmed)
        XCTAssertTrue(state.setOwnership(.mine))
        XCTAssertTrue(state.mayClaim)
        XCTAssertFalse(state.isConfirmed)
        XCTAssertFalse(state.setOwnership(.mine))
    }

    func testStaleRequestCannotConfirm() {
        var state = HerdrTabGeometryState()
        state.update(size)
        let request = state.beginRequest()!
        state.setOwnership(.other(connectionId: nil, kind: nil))
        XCTAssertFalse(state.finish(request, succeeded: true))
        XCTAssertFalse(state.isConfirmed)
    }

    func testServerAppliedSizeConfirmsWithoutARequest() {
        var state = HerdrTabGeometryState()
        state.update(size)
        state.setOwnership(.other(connectionId: 1, kind: "control"))
        state.setOwnership(.mine)
        state.noteServerApplied(size)
        XCTAssertTrue(state.isConfirmed)
        XCTAssertNil(state.beginRequest())
    }

    func testMineToNoneKeepsConfirmation() {
        var state = HerdrTabGeometryState()
        state.update(size)
        state.setOwnership(.mine)
        let request = state.beginRequest()!
        state.finish(request, succeeded: true)
        state.setOwnership(.none)
        XCTAssertTrue(state.isConfirmed)
    }

    func testInvalidateForcesAFreshPush() {
        var state = HerdrTabGeometryState()
        state.update(size)
        let request = state.beginRequest()!
        state.finish(request, succeeded: true)
        XCTAssertTrue(state.isConfirmed)
        state.invalidate()
        XCTAssertFalse(state.isConfirmed)
        XCTAssertTrue(state.mayClaim)
        XCTAssertNotNil(state.beginRequest())
    }

    // MARK: Reply classification

    private func reply(_ text: String) -> Bool {
        HerdrReplyFilter.isAutomaticReply(Data(text.utf8))
    }

    func testTerminalReportsAreAutomatic() {
        XCTAssertTrue(reply("\u{1b}[?62;22c"))                    // primary DA
        XCTAssertTrue(reply("\u{1b}[>1;10;0c"))                   // secondary DA
        XCTAssertTrue(reply("\u{1b}[24;80R"))                     // CPR
        XCTAssertTrue(reply("\u{1b}[8;24;80t"))                   // window size report
        XCTAssertTrue(reply("\u{1b}[?2026;2$y"))                  // DECRPM
        XCTAssertTrue(reply("\u{1b}]11;rgb:0000/0000/0000\u{1b}\\")) // OSC colour, ST
        XCTAssertTrue(reply("\u{1b}]10;rgb:ffff/ffff/ffff\u{07}"))   // OSC colour, BEL
        XCTAssertTrue(reply("\u{1b}P1+r524742=38\u{1b}\\"))       // XTGETTCAP
        XCTAssertTrue(reply("\u{1b}_Gi=1;OK\u{1b}\\"))            // kitty graphics
        XCTAssertTrue(reply("\u{1b}[0n\u{1b}[24;80R"))            // two reports in one chunk
    }

    func testUserInputIsNotAutomatic() {
        XCTAssertFalse(reply("ls -la\r"))
        XCTAssertFalse(reply("\u{1b}[A"))                         // arrow key
        XCTAssertFalse(reply("\u{1b}[<0;10;5M"))                  // SGR mouse press
        XCTAssertFalse(reply("\u{1b}[200~pasted\u{1b}[201~"))     // bracketed paste
        XCTAssertFalse(reply("\u{1b}[24;80Rx"))                   // report followed by text
        XCTAssertFalse(reply("\u{1b}[24;80"))                     // cut short
        XCTAssertFalse(reply("\u{1b}]11;rgb:0000/0000/0000"))     // unterminated OSC
        XCTAssertFalse(reply(""))
    }

    private func tail(_ text: String) -> Int? {
        HerdrReplyFilter.incompleteTailStart([UInt8](text.utf8))
    }

    func testIncompleteTailIsDetected() {
        XCTAssertNil(tail("\u{1b}[24;80R"))
        XCTAssertNil(tail("plain text\r"))
        XCTAssertNil(tail("\u{1b}[200~paste\u{1b}[201~"))
        XCTAssertNil(tail("\u{1b}a"))                             // alt-a
        XCTAssertEqual(tail("\u{1b}"), 0)
        XCTAssertEqual(tail("\u{1b}[24;8"), 0)
        XCTAssertEqual(tail("\u{1b}[0n\u{1b}[24;8"), 4)
        XCTAssertEqual(tail("\u{1b}]11;rgb:0000/0000"), 0)
        XCTAssertEqual(tail("text\u{1b}P1+r5247"), 4)
        XCTAssertEqual(tail("\u{1b}]11;x\u{1b}"), 0)              // ESC of a pending ST
    }

    func testSplitReplyReassemblesIntoAnAutomaticReply() {
        let whole = "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\"
        let first = String(whole.prefix(9)), second = String(whole.dropFirst(9))
        XCTAssertFalse(reply(first))
        XCTAssertEqual(tail(first), 0)
        XCTAssertTrue(reply(first + second))
    }

    // MARK: Upgrade prompt

    func testHardRefusalsAreOnlyMissingAndTooOld() {
        XCTAssertTrue(HerdrUpgradePrompt.herdrMissing.isHardRefusal)
        XCTAssertTrue(HerdrUpgradePrompt.versionTooOld(reported: "0.8.0").isHardRefusal)
        XCTAssertFalse(HerdrUpgradePrompt.controlStreamMissing.isHardRefusal)
        XCTAssertFalse(HerdrUpgradePrompt.sharedViewingNeedsUpgrade.isHardRefusal)
        XCTAssertTrue(HerdrUpgradePrompt.versionTooOld(reported: "0.8.0").message.contains("0.8.0"))
    }
}
