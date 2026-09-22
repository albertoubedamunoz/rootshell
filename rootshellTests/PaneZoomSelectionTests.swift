import XCTest

final class PaneZoomSelectionTests: XCTestCase {
    func testRejectsSinglePaneAndDuplicateIDs() {
        for ids in [[], [1], [1, 1]] {
            XCTAssertNil(PaneZoomSelection(paneIDs: ids))
        }
    }

    func testLabelsSelectStableIDsInDisplayOrder() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7, 91]))
        XCTAssertEqual(selection.labels, ["1", "2", "3"])
        XCTAssertEqual(selection.consume("2"), .selected(7))
    }

    func testStringPaneIDsAreOpaqueAndKeepDisplayOrder() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: ["workspace:tab:p9", "workspace:tab:p2"]))
        XCTAssertEqual(selection.labels, ["1", "2"])
        XCTAssertEqual(selection.consume("2"), .selected("workspace:tab:p2"))
        XCTAssertNil(PaneZoomSelection(paneIDs: ["same", "same"]))
    }

    func testViewIDsRemainFrozenWhenSourceOrderChanges() throws {
        var ids = (0..<12).map { _ in UUID() }
        let selected = ids[10]
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: ids))
        ids.reverse()
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("1"), .selected(selected))
    }

    func testTenPanesUseUnambiguousPaddedLabels() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(20..<30)))
        XCTAssertEqual(selection.labels.first, "01")
        XCTAssertEqual(selection.labels.last, "10")
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("0"), .selected(29))
    }

    func testLeadingZeroSelectsFirstPane() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(20..<30)))
        XCTAssertEqual(selection.consume("0"), .pending)
        XCTAssertEqual(selection.consume("1"), .selected(20))
    }

    func testHundredPanesRemainUnambiguous() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<100)))
        XCTAssertEqual(selection.labels.first, "001")
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("0"), .pending)
        XCTAssertEqual(selection.consume("0"), .selected(99))
    }

    func testOtherInputCancelsIncludingPasteAndModifiedDigits() throws {
        for input in ["", "a", "\u{1b}", "\r", "\t", "٣", "１２", "12", "0", "9"] {
            var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
            XCTAssertEqual(selection.consume(input), .cancelled, input)
        }
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(selection.consume("1", modified: true), .cancelled)
    }

    func testInvalidPrefixCancelsImmediately() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<12)))
        XCTAssertEqual(selection.consume("2"), .cancelled)
    }

    func testFinishedSelectionCannotChange() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(selection.consume("1"), .selected(8))
        XCTAssertEqual(selection.consume("2"), .selected(8))
        var cancelled = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(cancelled.consume("x"), .cancelled)
        XCTAssertEqual(cancelled.consume("1"), .cancelled)
    }

    @MainActor
    func testZoomQueriesServerAndScopesEveryTarget() async throws {
        for alreadyZoomed in [false, true] {
            var commands: [String] = []
            try await TmuxPaneZoomCommand.zoom(windowID: 4, paneID: 17) { command in
                commands.append(command)
                return command.hasPrefix("display-message") ? (alreadyZoomed ? "1\n" : "0\n") : ""
            }
            var expected = ["select-pane -Z -t @4.%17", "display-message -p -t @4.%17 '#{window_zoomed_flag}'"]
            if !alreadyZoomed { expected.append("resize-pane -Z -t @4.%17") }
            XCTAssertEqual(commands, expected)
        }
    }

    @MainActor
    func testMalformedReplyDoesNotToggleZoom() async {
        var commands: [String] = []
        do {
            try await TmuxPaneZoomCommand.zoom(windowID: 4, paneID: 17) { command in
                commands.append(command)
                return "bad reply"
            }
            XCTFail("Must reject malformed zoom state")
        } catch { }
        XCTAssertEqual(commands.count, 2)
    }

    @MainActor
    func testInvalidTargetSendsNothing() async {
        for (window, pane) in [(-1, 17), (4, -1)] {
            do {
                try await TmuxPaneZoomCommand.zoom(windowID: window, paneID: pane) { _ in
                    XCTFail("Invalid target must not send a command")
                    return ""
                }
                XCTFail("Must reject invalid target")
            } catch { }
        }
    }
}
