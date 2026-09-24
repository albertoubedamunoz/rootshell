import Foundation
import XCTest

final class HerdrEqualizationTests: XCTestCase {
    private typealias Node = HerdrControl.ExportedLayoutNode

    func testExportAndRatioResponsesDecodeFullTreeWhileZoomed() throws {
        for type in ["layout_export", "layout_split_ratio_set"] {
            let json = """
            {"id":"equalize","result":{"type":"\(type)","layout":{
              "workspace_id":"w1","tab_id":"w1:t1","zoomed":true,"focused_pane_id":"p2",
              "root":{"type":"split","direction":"right","ratio":0.8,
                "first":{"type":"pane","pane_id":"p1","cwd":"/tmp","env":{}},
                "second":{"type":"pane","pane_id":"p2"}}
            }}}
            """
            let response = try HerdrControl.decoder.decode(
                HerdrControl.Response<HerdrControl.LayoutDescriptionResult>.self, from: Data(json.utf8)
            )
            // Pane selection must validate against the full exported tree,
            // including the pane hidden by zoom, rather than visible geometry.
            XCTAssertEqual(response.result.layout.root.paneIDs, ["p1", "p2"])
            XCTAssertEqual(response.result.layout.root.equalizationRequests(tabID: "w1:t1"), [
                .init(tab_id: "w1:t1", path: [], ratio: 0.5)
            ])
        }
    }

    func testRatioRequestEncodesExplicitTabAndBooleanPath() throws {
        let request = HerdrControl.Request(id: "equalize", method: "layout.set_split_ratio",
            params: HerdrControl.LayoutSetSplitRatioParams(tab_id: "w1:t2", path: [false, true], ratio: 0.5))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "layout.set_split_ratio")
        XCTAssertEqual(params["tab_id"] as? String, "w1:t2")
        XCTAssertEqual(params["path"] as? [Bool], [false, true])
        XCTAssertEqual(params["ratio"] as? Double, 0.5)
        XCTAssertNil(params["pane_id"])
    }

    func testThreePanesBecomeEqualThirdsAlongEitherAxis() {
        for axis in [Node.Direction.right, .down] {
            let root = Node.split(direction: axis, ratio: 0.7, first: .pane("a"),
                second: .split(direction: axis, ratio: 0.7, first: .pane("b"), second: .pane("c")))
            let requests = root.equalizationRequests(tabID: "tab")
            XCTAssertEqual(requests.map(\.path), [[], [true]])
            XCTAssertEqual(requests.map(\.ratio), [1.0 / 3.0, 0.5])
            XCTAssertTrue(requests.allSatisfy { $0.tab_id == "tab" })
        }
    }

    func testPerpendicularGroupCountsAsOneAndBothChildrenAreEqualized() {
        let root = Node.split(direction: .right, ratio: 0.8,
            first: .split(direction: .down, ratio: 0.8, first: .pane("a"), second: .pane("b")),
            second: .split(direction: .right, ratio: 0.8, first: .pane("c"), second: .pane("d")))
        let requests = root.equalizationRequests(tabID: "tab")
        XCTAssertEqual(requests.map(\.path), [[], [false], [true]])
        XCTAssertEqual(requests.map(\.ratio), [1.0 / 3.0, 0.5, 0.5])
    }

    func testSinglePaneAndAlreadyEqualFloatRatiosNeedNoWrites() {
        XCTAssertTrue(Node.pane("a").equalizationRequests(tabID: "tab").isEmpty)
        let root = Node.split(direction: .right, ratio: Double(Float(1.0 / 3.0)), first: .pane("a"),
            second: .split(direction: .right, ratio: 0.5, first: .pane("b"), second: .pane("c")))
        XCTAssertTrue(root.equalizationRequests(tabID: "tab").isEmpty)
    }

    func testEqualizationRespectsServerRatioLimits() {
        let row = (1...10).reduce(Node.pane("0")) { first, index in
            .split(direction: .right, ratio: 0.5, first: first, second: .pane(String(index)))
        }
        let leftHeavy = Node.split(direction: .right, ratio: 0.5, first: row, second: .pane("last"))
        let rightHeavy = Node.split(direction: .right, ratio: 0.5, first: .pane("first"), second: row)
        XCTAssertEqual(leftHeavy.equalizationRequests(tabID: "tab").first?.ratio, 0.9)
        XCTAssertEqual(rightHeavy.equalizationRequests(tabID: "tab").first?.ratio, 0.1)
    }

    func testTopologyComparisonIgnoresRatiosButDetectsChangedPathsAndTargets() {
        let root = Node.split(direction: .right, ratio: 0.8, first: .pane("a"), second: .pane("b"))
        let equalized = Node.split(direction: .right, ratio: 0.5, first: .pane("a"), second: .pane("b"))
        XCTAssertTrue(root.hasSameTopology(as: equalized))
        XCTAssertFalse(root.hasSameTopology(as: .pane("a")))
        XCTAssertFalse(root.hasSameTopology(as: .split(direction: .down, ratio: 0.8, first: .pane("a"), second: .pane("b"))))
        XCTAssertFalse(root.hasSameTopology(as: .split(direction: .right, ratio: 0.8, first: .pane("b"), second: .pane("a"))))
        let layout = HerdrControl.LayoutDescription(workspace_id: "workspace", tab_id: "tab", root: root)
        XCTAssertTrue(layout.hasSameTopology(as: .init(workspace_id: "workspace", tab_id: "tab", root: equalized)))
        XCTAssertFalse(layout.hasSameTopology(as: .init(workspace_id: "workspace", tab_id: "other", root: root)))
        XCTAssertFalse(layout.hasSameTopology(as: .init(workspace_id: "other", tab_id: "tab", root: root)))
    }

    func testExportedPaneOrderIncludesNestedHiddenPanes() {
        let root = Node.split(direction: .right, ratio: 0.5, first: .pane("p9"),
            second: .split(direction: .down, ratio: 0.5, first: .pane("p2"), second: .pane("p7")))
        XCTAssertEqual(root.paneIDs, ["p9", "p2", "p7"])
    }

    func testMalformedExportedTreesAreRejected() {
        for json in [
            #"{"type":"unknown"}"#,
            #"{"type":"pane"}"#,
            #"{"type":"split","direction":"left","ratio":0.5,"first":{"type":"pane","pane_id":"a"},"second":{"type":"pane","pane_id":"b"}}"#,
            #"{"type":"split","direction":"right","ratio":2,"first":{"type":"pane","pane_id":"a"},"second":{"type":"pane","pane_id":"b"}}"#
        ] {
            XCTAssertThrowsError(try HerdrControl.decoder.decode(Node.self, from: Data(json.utf8)))
        }
    }
}

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

    // MARK: Query authority

    func testAuthorityHandoffKeepsOldRepliesAndDropsNewFollowerReplies() {
        var authority = HerdrQueryAuthority()
        let oldReply = Data("\u{1b}[24;1R".utf8)
        let newReply = Data("\u{1b}[12;1R".utf8)
        // The pipe is delayed until after the network has handed control
        // away. Both replies land in one read around the parser marker.
        let segments = authority.consume(oldReply + Data("\u{1b}[?15998;0$y".utf8) + newReply)
        XCTAssertEqual(segments.map(\.bytes), [oldReply, newReply])
        XCTAssertEqual(segments.map(\.answersQueries), [true, false])
        XCTAssertFalse(authority.answersQueries)
    }

    func testTwoClientsAnswerExactlyOnceAcrossRepeatedHandoffs() {
        var desktop = HerdrQueryAuthority()
        var phone = HerdrQueryAuthority()
        _ = phone.consume(Data("\u{1b}[?15998;0$y".utf8))
        for phoneOwns in [true, false, true, false] {
            let desktopMarker = Data("\u{1b}[?\(phoneOwns ? 15998 : 15999);0$y".utf8)
            let phoneMarker = Data("\u{1b}[?\(phoneOwns ? 15999 : 15998);0$y".utf8)
            let before = Data("\u{1b}[24;1R".utf8)
            let after = Data("\u{1b}[12;1R".utf8)
            // Different pipe timings: desktop batches the handoff; phone
            // drains the outstanding answer separately from the marker.
            let a = desktop.consume(before + desktopMarker + after)
            let b = phone.consume(before) + phone.consume(phoneMarker) + phone.consume(after)
            let answers = (a + b).filter(\.answersQueries).map(\.bytes)
            XCTAssertEqual(answers.filter { $0 == before }.count, 1)
            XCTAssertEqual(answers.filter { $0 == after }.count, 1)
        }
    }

    func testAuthorityMarkersSurviveEveryResponseReadSplit() {
        let bytes = Data("\u{1b}[24;1R\u{1b}[?15998;0$y\u{1b}[12;1R\u{1b}[?15999;0$y\u{1b}[8;1R".utf8)
        for split in 0...bytes.count {
            var authority = HerdrQueryAuthority()
            var carry = Data()
            var forwarded = Data()
            for read in [Data(bytes.prefix(split)), Data(bytes.dropFirst(split))] {
                var pending = carry + read
                carry = Data()
                if let start = HerdrReplyFilter.incompleteTailStart(Array(pending)) {
                    carry = Data(pending.dropFirst(start))
                    pending = Data(pending.prefix(start))
                }
                for segment in authority.consume(pending) where segment.answersQueries {
                    forwarded.append(segment.bytes)
                }
            }
            XCTAssertTrue(carry.isEmpty, "split \(split)")
            XCTAssertEqual(forwarded, Data("\u{1b}[24;1R\u{1b}[8;1R".utf8), "split \(split)")
        }
    }

    func testFollowerInputAndLocalFenceAcknowledgementsArePreserved() throws {
        var authority = HerdrQueryAuthority()
        var fence = HerdrParserFence()
        let probe = try XCTUnwrap(fence.issue())
        _ = authority.consume(Data("\u{1b}[?15998;0$y".utf8))
        let input = Data("paste\u{1b}[A".utf8)
        let localReply = Data("\u{1b}[?\(probe.id);0$y".utf8)
        let segments = authority.consume(localReply + input)
        let segment = try XCTUnwrap(segments.first)
        let filtered = fence.consume(segment.bytes)
        XCTAssertFalse(segment.answersQueries)
        XCTAssertEqual(filtered.acknowledged, [probe.id])
        XCTAssertEqual(filtered.forward, input)
        XCTAssertFalse(HerdrReplyFilter.isAutomaticReply(filtered.forward))
        // A connection without authority records retains protocol 1 behavior.
        var legacy = HerdrQueryAuthority()
        XCTAssertTrue(try XCTUnwrap(legacy.consume(Data("\u{1b}[1;1R".utf8)).first).answersQueries)
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

    func testLayoutSnapshotRejectsGeometryOutsideHerdrWireRange() throws {
        func layout(x: Int, width: Int) -> String {
            "{\"workspace_id\":\"w\",\"tab_id\":\"t\",\"zoomed\":false,\"area\":{\"x\":0,\"y\":0,\"width\":65535,\"height\":24},\"focused_pane_id\":\"p\",\"panes\":[{\"pane_id\":\"p\",\"focused\":true,\"rect\":{\"x\":\(x),\"y\":0,\"width\":\(width),\"height\":24}}],\"splits\":[]}"
        }

        XCTAssertThrowsError(try decode(HerdrControl.LayoutSnapshot.self, layout(x: -1, width: 80)))
        XCTAssertThrowsError(try decode(HerdrControl.LayoutSnapshot.self, layout(x: 0, width: 65_536)))
        XCTAssertNoThrow(try decode(HerdrControl.LayoutSnapshot.self, layout(x: 0, width: 65_535)))
        XCTAssertThrowsError(try decode(HerdrControl.LayoutSnapshot.self, layout(x: 65_535, width: 1)))
    }

    func testLayoutSnapshotRejectsInvalidSplitAndDuplicatePaneIDs() throws {
        let invalidRatio = #"{"workspace_id":"w","tab_id":"t","zoomed":false,"area":{"x":0,"y":0,"width":80,"height":24},"focused_pane_id":"p","panes":[{"pane_id":"p","focused":true,"rect":{"x":0,"y":0,"width":80,"height":24}}],"splits":[{"id":"s","direction":"right","ratio":1e300,"rect":{"x":0,"y":0,"width":80,"height":24}}]}"#
        let duplicatePanes = #"{"workspace_id":"w","tab_id":"t","zoomed":false,"area":{"x":0,"y":0,"width":80,"height":24},"focused_pane_id":"p","panes":[{"pane_id":"p","focused":true,"rect":{"x":0,"y":0,"width":40,"height":24}},{"pane_id":"p","focused":false,"rect":{"x":40,"y":0,"width":40,"height":24}}],"splits":[]}"#

        XCTAssertThrowsError(try decode(HerdrControl.LayoutSnapshot.self, invalidRatio))
        XCTAssertThrowsError(try decode(HerdrControl.LayoutSnapshot.self, duplicatePanes))
    }

    func testSessionSnapshotPreservesCollapsedPaneGeometry() throws {
        let snapshot = try decode(HerdrControl.SessionSnapshot.self, #"""
        {"version":"0.9.0","protocol":2,"focused_workspace_id":"w","focused_tab_id":"t","focused_pane_id":"visible",
         "workspaces":[{"workspace_id":"w","label":"one","number":1,"focused":true,"active_tab_id":"t","agent_status":"idle"}],
         "tabs":[{"tab_id":"t","workspace_id":"w","number":1,"label":"one","focused":true,"pane_count":2,"agent_status":"idle"}],
         "panes":[
           {"pane_id":"collapsed","terminal_id":"tc","workspace_id":"w","tab_id":"t","focused":false,"agent_status":"idle"},
           {"pane_id":"visible","terminal_id":"tv","workspace_id":"w","tab_id":"t","focused":true,"agent_status":"idle"}],
         "layouts":[{"workspace_id":"w","tab_id":"t","zoomed":false,"area":{"x":0,"y":0,"width":4,"height":2},"focused_pane_id":"visible",
           "panes":[
             {"pane_id":"collapsed","focused":false,"rect":{"x":0,"y":0,"width":0,"height":0}},
             {"pane_id":"visible","focused":true,"rect":{"x":0,"y":0,"width":4,"height":2}}],
           "splits":[{"id":"s","direction":"right","ratio":0.1,"rect":{"x":0,"y":0,"width":4,"height":2}}]}],
         "agents":[]}
        """#)

        XCTAssertEqual(snapshot.layouts.first?.panes.first?.rect.width, 0)
        XCTAssertEqual(snapshot.layouts.first?.panes.first?.rect.height, 0)
    }

    func testSessionSnapshotRejectsDuplicateTopologyIDs() throws {
        let duplicateWorkspaces = #"""
        {"version":"0.9.0","protocol":2,"workspaces":[
          {"workspace_id":"w","label":"one","number":1,"focused":true,"active_tab_id":"","agent_status":"idle"},
          {"workspace_id":"w","label":"two","number":2,"focused":false,"active_tab_id":"","agent_status":"idle"}],
         "tabs":[],"panes":[],"layouts":[],"agents":[]}
        """#
        XCTAssertThrowsError(try decode(HerdrControl.SessionSnapshot.self, duplicateWorkspaces))
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
            // on the phone, overflowing its viewport until this client claims.
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

    // MARK: Parser confirmation across handoffs

    func testReturningToEarlierGridRequiresNewParserReply() {
        var state = HerdrParserGrid()
        let ipad = HerdrParserGrid.Grid(cols: 95, rows: 45)
        let iphone = HerdrParserGrid.Grid(cols: 52, rows: 28)
        state.request(ipad)
        _ = state.probe()
        _ = state.consume(Data("\u{1b}[8;45;95t".utf8))
        XCTAssertEqual(state.confirmed, ipad)

        state.invalidate()
        state.request(iphone)
        _ = state.probe()
        state.invalidate()
        state.request(ipad)
        XCTAssertNil(state.confirmed)
        XCTAssertTrue(state.needsProbe)

        // The phone-layout probe ran while Ghostty still had the earlier
        // iPad grid. Its delayed reply must not acknowledge this handoff.
        _ = state.probe()
        XCTAssertTrue(state.consume(Data("\u{1b}[8;45;95t".utf8)).grids.isEmpty)
        XCTAssertTrue(state.needsProbe)
        XCTAssertEqual(state.consume(Data("\u{1b}[8;45;95t".utf8)).grids, [ipad])
        XCTAssertFalse(state.needsProbe)
    }

    func testLayoutInvalidationRetiresSplitRepliesAndPreservesInput() {
        let reply = Data("\u{1b}[8;45;95t".utf8)
        for split in 1..<reply.count {
            var state = HerdrParserGrid()
            let ipad = HerdrParserGrid.Grid(cols: 95, rows: 45)
            state.request(ipad)
            _ = state.probe()
            _ = state.consume(reply.prefix(split))
            state.invalidate()
            state.request(ipad)
            _ = state.probe()
            let old = state.consume(reply.suffix(from: split) + Data("x".utf8))
            XCTAssertTrue(old.grids.isEmpty)
            XCTAssertEqual(old.forward, Data("x".utf8))
            XCTAssertTrue(state.needsProbe)
            XCTAssertEqual(state.consume(reply).grids, [ipad])
        }
    }

    func testLatestParserReplyWinsWithinOneRead() {
        var state = HerdrParserGrid()
        state.request(.init(cols: 95, rows: 45))
        _ = state.probe()
        _ = state.probe()
        let result = state.consume(Data("\u{1b}[8;45;95t\u{1b}[8;28;52t".utf8))
        XCTAssertEqual(result.grids, [.init(cols: 52, rows: 28)])
        XCTAssertTrue(state.needsProbe)
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

    /// `hasPendingClaim` is what lets a Take Control claim size a tab this
    /// window is not showing, so it must not outlive the one request it arms.
    func testPendingClaimIsVisibleUntilTheRequestGoesOut() throws {
        var state = HerdrTabGeometryState()
        state.update(size)
        XCTAssertFalse(state.hasPendingClaim)
        state.requestClaim()
        XCTAssertTrue(state.hasPendingClaim)
        let request = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(request.claim)
        XCTAssertFalse(state.hasPendingClaim)
        state.finish(request, succeeded: false)
        XCTAssertFalse(state.hasPendingClaim)
    }

    // MARK: Reply classification

    func testRoutineResizeCannotReclaimWithStaleOwnership() throws {
        var state = HerdrTabGeometryState()
        state.update(size)
        let initial = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(initial.claim)
        state.finish(initial, succeeded: true)
        state.setOwnership(.mine)
        // The other client claims on the server before our notification
        // arrives. A keyboard/window change must not undo that claim.
        state.update(.init(cols: 60, rows: 20, cellWidth: 8, cellHeight: 16))
        let resize = try XCTUnwrap(state.beginRequest())
        XCTAssertFalse(resize.claim)
        state.finish(resize, succeeded: false)
        XCTAssertFalse(try XCTUnwrap(state.beginRequest()).claim)
    }

    func testExplicitClaimIsConsumedOnceEvenWhenResponseIsLost() throws {
        var state = HerdrTabGeometryState()
        state.update(size)
        state.setOwnership(.other(connectionId: 5, kind: "control"))
        state.requestClaim()
        let requested = try XCTUnwrap(state.beginRequest())
        XCTAssertTrue(requested.claim)
        state.finish(requested, succeeded: false)
        let retry = try XCTUnwrap(state.beginRequest())
        XCTAssertFalse(retry.claim)
        state.finish(retry, succeeded: true)
        // Another explicit action is still allowed, even at the same size.
        state.requestClaim()
        XCTAssertTrue(try XCTUnwrap(state.beginRequest()).claim)
    }

    func testMobileClaimStillRunsAfterSameSizeWasConfirmed() throws {
        var state = HerdrTabGeometryState()
        state.update(size)
        state.setOwnership(.other(connectionId: 5, kind: "control"))
        let stored = try XCTUnwrap(state.beginRequest())
        state.finish(stored, succeeded: true)
        XCTAssertTrue(state.isConfirmed)
        let activation = try XCTUnwrap(state.beginRequest(claim: true))
        XCTAssertTrue(activation.claim)
        state.finish(activation, succeeded: true)
        XCTAssertNil(state.beginRequest())
    }

    func testFocusReportsFromSnapshotReplayCannotClaimGeometry() {
        XCTAssertTrue(reply("\u{1b}[I"))
        XCTAssertTrue(reply("\u{1b}[O"))
        XCTAssertTrue(reply("\u{1b}[I\u{1b}[24;80R"))
        XCTAssertTrue(reply("\u{1b}[?15998;0$y\u{1b}[O"))
        XCTAssertFalse(reply("\u{1b}[2I"))
        XCTAssertFalse(reply("\u{1b}[Ix")) // A real keystroke still counts.
        var follower = HerdrQueryAuthority()
        _ = follower.consume(Data("\u{1b}[?15998;0$y".utf8))
        let reports = follower.consume(Data("\u{1b}[I\u{1b}[O".utf8))
        XCTAssertTrue(reports.allSatisfy { !$0.answersQueries && HerdrReplyFilter.isAutomaticReply($0.bytes) })
    }

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
    // MARK: Activation

    func testACancelledPaneStaysCancelledThroughTheHandoff() {
        var state = HerdrActivation()
        XCTAssertTrue(state.select("a", panes: ["p", "q"]))
        // The user scrolls while the claim is still in flight.
        state.cancelPane("p")
        XCTAssertEqual(state.pendingPanes, ["q"])
        // The handoff answering that claim arrives late and must not re-arm it.
        state.expectReturnToLive(tabID: "a", panes: ["p", "q"])
        XCTAssertEqual(state.pendingPanes, ["q"])
        // A new activation is the user arriving again, so it starts clean.
        state.suspend()
        XCTAssertTrue(state.select("a", panes: ["p", "q"]))
        XCTAssertEqual(state.pendingPanes, ["p", "q"])
    }

    func testExpectingReturnToLiveNeverClaimsATab() {
        var state = HerdrActivation()
        // A handoff earned by typing: the tab is ours, nothing was asked for.
        state.expectReturnToLive(tabID: "a", panes: ["p"])
        XCTAssertFalse(state.needsClaim)
        XCTAssertEqual(state.tabID, "a")
        XCTAssertEqual(state.pendingPanes, ["p"])
        // Panes accumulate on the same tab; a different tab starts over.
        state.expectReturnToLive(tabID: "a", panes: ["q"])
        XCTAssertEqual(state.pendingPanes, ["p", "q"])
        state.expectReturnToLive(tabID: "b", panes: ["r"])
        XCTAssertEqual(state.pendingPanes, ["r"])
        XCTAssertFalse(state.needsClaim)
        // It also must not consume the first real activation of that tab.
        XCTAssertTrue(state.select("b", panes: ["r"]))
        XCTAssertTrue(state.needsClaim)
    }

    func testActivationIsOneShotUntilSelectionOrResume() {
        var state = HerdrActivation()
        XCTAssertTrue(state.select("a", panes: ["p", "q"]))
        let first = state.generation
        XCTAssertTrue(state.needsClaim)
        // Repeated topology/layout callbacks do not manufacture a handoff.
        XCTAssertFalse(state.select("a", panes: ["p", "q"]))
        state.claimed(generation: first)
        state.finishPane("p")
        XCTAssertFalse(state.needsClaim)
        XCTAssertEqual(state.pendingPanes, ["q"])
        XCTAssertFalse(state.select("a", panes: ["p", "q"]))
        XCTAssertEqual(state.generation, first)
        state.suspend()
        XCTAssertTrue(state.pendingPanes.isEmpty)
        XCTAssertTrue(state.select("a", panes: ["p", "q"]))
        XCTAssertTrue(state.needsClaim)
        XCTAssertNotEqual(state.generation, first)
    }

    func testLateClaimCannotCompleteAnotherSelectionOrReconnection() {
        var state = HerdrActivation()
        state.select("a", panes: ["p"])
        let old = state.generation
        state.select("b", panes: ["q"])
        state.claimed(generation: old)
        XCTAssertTrue(state.needsClaim)
        XCTAssertEqual(state.pendingPanes, ["q"])
        let beforeReconnect = state.generation
        state.suspend()
        state.select("b", panes: ["q"])
        state.claimed(generation: beforeReconnect)
        XCTAssertTrue(state.needsClaim)
        state.claimed(generation: state.generation)
        XCTAssertFalse(state.needsClaim)
    }

    func testGatewayRestoreAndUserScrollCancellation() {
        var state = HerdrActivation()
        XCTAssertFalse(state.select(nil, panes: []))
        XCTAssertTrue(state.select("restored", panes: ["p", "q"]))
        // Failed claims leave intent pending; user scrolling cancels only
        // that pane's viewport jump, not the tab's requested sizing.
        state.finishPane("p")
        XCTAssertTrue(state.needsClaim)
        XCTAssertEqual(state.pendingPanes, ["q"])
        XCTAssertFalse(state.select("restored", panes: ["p", "q"]))
        XCTAssertEqual(state.pendingPanes, ["q"])
        state.select(nil, panes: [])
        XCTAssertFalse(state.needsClaim)
        XCTAssertTrue(state.pendingPanes.isEmpty)
        XCTAssertTrue(state.select("restored", panes: ["p", "q"]))
    }

    // MARK: Live resize

    func testLiveResizeKeepsTheCommittedGridUntilServerLayoutArrives() {
        for scale: CGFloat in [1, 2, 3] {
            let cellPixels = UInt32(8 * scale)
            let chrome: CGFloat = 16
            // The host negotiates its new budget from these bounds, while
            // the pane still renders output for the server's 100 columns.
            for viewport: CGFloat in [336, 656, 815, 817, 976] {
                let drawable = HerdrGeometry.clampedExtent(
                    viewport, cells: 100, cellPixels: cellPixels,
                    chrome: chrome, scale: scale, preserveGrid: true)
                XCTAssertEqual(HerdrGeometry.cellBudget(extent: drawable, chrome: chrome, cell: 8), 100)
                XCTAssertEqual(Int((drawable * scale).rounded(.down) - chrome * scale) / Int(cellPixels), 100)
            }
            // The committed layout finally changes; only now may the pane
            // shrink to 80 columns, independently of the continuing drag.
            let resized = HerdrGeometry.clampedExtent(
                620, cells: 80, cellPixels: cellPixels,
                chrome: chrome, scale: scale, preserveGrid: true)
            XCTAssertEqual(HerdrGeometry.cellBudget(extent: resized, chrome: chrome, cell: 8), 80)
        }
    }

    func testPinnedGridPreservesPartialCellsAndOtherModesStillShrink() {
        let pinned = HerdrGeometry.clampedExtent(
            819, cells: 100, cellPixels: 16, chrome: 16, scale: 2, preserveGrid: true)
        XCTAssertEqual(pinned, 819)
        let unpinned = HerdrGeometry.clampedExtent(
            656, cells: 100, cellPixels: 16, chrome: 16, scale: 2)
        XCTAssertEqual(unpinned, 656)
    }

    func testResizeRepairRequiresSnapshotRequestedAfterTheLatestGridChange() {
        let wide = TerminalGridReports.Grid(cols: 100, rows: 40)
        let narrow = TerminalGridReports.Grid(cols: 80, rows: 30)
        let oldRequest = UUID(), narrowRequest = UUID(), finalRequest = UUID()
        var recovery = HerdrResizeRecovery(grid: wide)
        recovery.requestedSnapshot(oldRequest)
        recovery = HerdrResizeRecovery(grid: narrow)
        XCTAssertFalse(recovery.acceptsSnapshot(requestID: oldRequest, grid: narrow))
        XCTAssertFalse(recovery.acceptsSnapshot(requestID: nil, grid: narrow))
        recovery.requestedSnapshot(narrowRequest)
        XCTAssertFalse(recovery.acceptsSnapshot(requestID: narrowRequest, grid: wide))
        XCTAssertTrue(recovery.acceptsSnapshot(requestID: narrowRequest, grid: narrow))
        // A -> B -> A does not make the first snapshot fresh again.
        recovery = HerdrResizeRecovery(grid: wide)
        XCTAssertFalse(recovery.acceptsSnapshot(requestID: oldRequest, grid: wide))
        XCTAssertFalse(recovery.acceptsSnapshot(requestID: narrowRequest, grid: narrow))
        recovery.requestedSnapshot(finalRequest)
        XCTAssertTrue(recovery.acceptsSnapshot(requestID: finalRequest, grid: wide))
    }

    // MARK: Snapshot record deadlines

    @MainActor
    func testSnapshotAcknowledgedBeforeBackgroundStillExpiresOnResume() async throws {
        let request = UUID()
        var foregroundRecoveryActive = false
        var waited = false
        let expired = try await HerdrSnapshotRecordDeadline.waitForExpiry(
            requestID: request,
            pendingRequest: { request },
            wait: {
                // The RPC was acknowledged with no recovery active. The
                // pushed record never arrives, even though health pings do.
                XCTAssertFalse(foregroundRecoveryActive)
                waited = true
                foregroundRecoveryActive = true
            }
        )
        XCTAssertTrue(waited)
        XCTAssertTrue(foregroundRecoveryActive)
        XCTAssertTrue(expired)
    }

    @MainActor
    func testSnapshotRecordDeadlineIgnoresArrivedAndReplacedRequests() async throws {
        let request = UUID()
        // A record arrives, the pane detaches, or the stream changes while
        // waiting; an old deadline must not tear down the current stream.
        for replacement: UUID? in [nil, UUID()] {
            var pending: UUID? = request
            let expired = try await HerdrSnapshotRecordDeadline.waitForExpiry(
                requestID: request,
                pendingRequest: { pending },
                wait: { pending = replacement }
            )
            XCTAssertFalse(expired)
        }
        let alreadyArrived = try await HerdrSnapshotRecordDeadline.waitForExpiry(
            requestID: request,
            pendingRequest: { nil },
            wait: { XCTFail("A record already received needs no deadline") }
        )
        XCTAssertFalse(alreadyArrived)
    }

    // MARK: Ordered local parser acknowledgements

    func testParserFenceConsumesEveryPossibleSplitWithoutLeakingToServer() throws {
        let reply = Data("\u{1b}[?16000;0$y".utf8)
        for cut in 0...reply.count {
            var fence = HerdrParserFence()
            let probe = try XCTUnwrap(fence.issue())
            XCTAssertEqual(probe.bytes, Data("\u{1b}[?16000$p".utf8))
            let a = fence.consume(Data("before".utf8) + reply.prefix(cut))
            let b = fence.consume(reply.suffix(reply.count - cut) + Data("after".utf8))
            XCTAssertEqual(a.forward + b.forward, Data("beforeafter".utf8))
            XCTAssertEqual(a.acknowledged + b.acknowledged, [probe.id])
        }
    }

    func testParserFenceKeepsOldAndReplacementAcknowledgementsDistinct() throws {
        var fence = HerdrParserFence()
        let old = try XCTUnwrap(fence.issue())
        let replacement = try XCTUnwrap(fence.issue())
        let oldReply = fence.consume(Data("\u{1b}[?\(old.id);0$y".utf8))
        XCTAssertEqual(oldReply.acknowledged, [old.id])
        XCTAssertNotEqual(old.id, replacement.id)
        XCTAssertTrue(oldReply.forward.isEmpty)
        let newReply = fence.consume(Data("\u{1b}[?\(replacement.id);0$y".utf8))
        XCTAssertEqual(newReply.acknowledged, [replacement.id])
        XCTAssertTrue(newReply.forward.isEmpty)
    }

    func testParserFencePreservesUnrelatedReportsAndInput() throws {
        var fence = HerdrParserFence()
        _ = try XCTUnwrap(fence.issue())
        let unrelated = Data("x\u{1b}[8;24;80t\u{1b}[?25;1$y\u{1b}[?16001;0$y\u{1b}]10;rgb:ff/ff/ff\u{7}\u{1b}[A".utf8)
        var forwarded = Data()
        for byte in unrelated {
            let result = fence.consume(Data([byte]))
            forwarded.append(result.forward)
            XCTAssertTrue(result.acknowledged.isEmpty)
        }
        XCTAssertEqual(forwarded, unrelated)
    }

    func testRepeatedResizeFencesReuseOnlyAcknowledgedIDs() throws {
        var fence = HerdrParserFence()
        // This cancelled probe can reply at any time, even after the ID
        // range has been used up by successful resizes.
        let delayed = try XCTUnwrap(fence.issue())
        for _ in 0..<20_000 {
            let resize = try XCTUnwrap(fence.issue())
            XCTAssertNotEqual(resize.id, delayed.id)
            let result = fence.consume(Data("\u{1b}[?\(resize.id);0$y".utf8))
            XCTAssertEqual(result.acknowledged, [resize.id])
            XCTAssertTrue(result.forward.isEmpty)
        }
        let replacement = try XCTUnwrap(fence.issue())
        let late = fence.consume(Data("\u{1b}[?\(delayed.id);0$y".utf8))
        XCTAssertEqual(late.acknowledged, [delayed.id])
        XCTAssertNotEqual(replacement.id, delayed.id)
    }

}
