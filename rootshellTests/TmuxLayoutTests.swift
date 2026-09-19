import XCTest

@MainActor
final class TmuxLayoutTests: XCTestCase {
    private func pane(_ id: Int, width: Int = 20, height: Int = 24) -> TmuxLayoutNode {
        .pane(paneId: id, width: width, height: height, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        let width = axis == .horizontal ? children.reduce(0) { $0 + $1.width } + children.count - 1 : children.map(\.width).max() ?? 1
        let height = axis == .vertical ? children.reduce(0) { $0 + $1.height } + children.count - 1 : children.map(\.height).max() ?? 1
        return .split(direction: axis, children: children, width: width, height: height, x: 0, y: 0)
    }

    private func columns(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [[1, 10], [7, 13], [11, 12]].map { ids in
            split(.vertical, ids.map { pane($0, width: width) })
        })
    }

    private func pair(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [pane(0, width: width), pane(2, width: width)])
    }

    private var constrained: TmuxLayoutNode {
        split(.horizontal, [pane(0, width: 2, height: 5),
            split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 1, height: 2) }),
                pane(4, width: 5, height: 2)
            ])
        ])
    }

    private func wireLayout(_ node: TmuxLayoutNode) -> String {
        func body(_ node: TmuxLayoutNode) -> String {
            let prefix = "\(node.width)x\(node.height),0,0"
            switch node {
            case let .pane(id, _, _, _, _): return "\(prefix),\(id)"
            case let .split(axis, children, _, _, _, _):
                let brackets = axis == .horizontal ? ("{", "}") : ("[", "]")
                return prefix + brackets.0 + children.map(body).joined(separator: ",") + brackets.1
            }
        }
        let value = body(node)
        var sum: UInt16 = 0
        for byte in value.utf8 { sum = ((sum >> 1) | (sum << 15)) &+ UInt16(byte) }
        let hex = String(sum, radix: 16)
        return String(repeating: "0", count: 4 - hex.count) + hex + "," + value
    }

    private func reply(_ node: TmuxLayoutNode, zoom: Int? = nil, status: String = "off", scrollbars: String = "off") -> String {
        "\(wireLayout(node))|\(zoom == nil ? 0 : 1)|%\(zoom ?? node.paneIDs[0])|\(status)|\(scrollbars)\r\n"
    }

    func testTopologyAllowsGeometryChangesButRejectsMovedOrReplacedPanes() {
        let original = pair()
        XCTAssertTrue(original.hasSameTopology(as: pair(width: 60)))
        XCTAssertFalse(original.hasSameTopology(as: split(.horizontal, [pane(2), pane(0)])))
        XCTAssertFalse(original.hasSameTopology(as: split(.horizontal, [pane(0), pane(8)])))
        XCTAssertFalse(original.hasSameTopology(as: split(.vertical, [pane(0), pane(2)])))
        XCTAssertFalse(original.hasSameTopology(as: pane(0)))
    }

    func testServerLayoutParserRejectsUncheckedGeometry() {
        XCTAssertEqual(TmuxLayoutNode.parseServerLayout("b25d,80x24,0,0,0"), pane(0, width: 80, height: 24))
        XCTAssertNil(TmuxLayoutNode.parseServerLayout("0000,80x24,0,0,0"))
        XCTAssertNil(TmuxLayoutNode.parseServerLayout("unknown-format"))
        XCTAssertEqual(TmuxLayoutNode.parseServerLayout(wireLayout(constrained)), constrained)
        XCTAssertNil(TmuxLayoutNode.parseServerLayout(wireLayout(split(.horizontal, [pane(0), pane(0)]))))
        let malformed = TmuxLayoutNode.split(direction: .horizontal, children: [pane(0), pane(2)], width: 2, height: 24, x: 0, y: 0)
        XCTAssertNil(TmuxLayoutNode.parseServerLayout(wireLayout(malformed)))
    }

    func testPerpendicularGroupRetainsMinimumWidth() async {
        XCTAssertEqual(constrained.width, 8)
        XCTAssertFalse(constrained.permitsNativeEqualization)
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: constrained) { command in
                commands.append(command)
                return self.reply(self.constrained, zoom: 0)
            }
            XCTFail("Root spreading would shrink the five-column subtree to three")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].hasPrefix("display-message"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSafetyIncludesAncestorShrinkAndBothAxes() {
        let deep = split(.vertical, [constrained, pane(5, width: 8, height: 5)])
        XCTAssertFalse(deep.permitsNativeEqualization)
        func transpose(_ node: TmuxLayoutNode) -> TmuxLayoutNode {
            switch node {
            case let .pane(id, w, h, _, _): return pane(id, width: h, height: w)
            case let .split(axis, children, _, _, _, _):
                return split(axis == .horizontal ? .vertical : .horizontal, children.map(transpose))
            }
        }
        XCTAssertFalse(transpose(constrained).permitsNativeEqualization)
        XCTAssertTrue(columns().permitsNativeEqualization)
    }

    func testSixPaneLayoutWaitsForServerGeometryToSettle() async throws {
        var spreads = 0
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 4, layout: columns()) { command in
            commands.append(command)
            if command.hasPrefix("display-message") {
                return self.reply(self.columns(width: 20 + min((spreads + 5) / 6, 2)))
            }
            spreads += 1
            return ""
        }
        XCTAssertEqual(spreads, 18)
        XCTAssertEqual(commands.filter { $0.hasPrefix("select-layout") }, Array(repeating: [1, 10, 7, 13, 11, 12].map {
            "select-layout -E -t @4.%\($0)"
        }, count: 3).flatMap { $0 })
        XCTAssertTrue(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
        XCTAssertEqual(commands.filter { $0.hasPrefix("display-message") }.count, spreads + 1)
    }

    func testZoomedPaneZeroIsRestoredWithItsOwnCommandAfterConvergence() async throws {
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            commands.append(command)
            return command.hasPrefix("display-message") ? self.reply(self.pair(), zoom: commands.count == 1 ? 0 : nil) : ""
        }
        XCTAssertEqual(commands.last, "resize-pane -Z -t @9.%0")
        XCTAssertEqual(commands.filter { $0.hasPrefix("resize-pane") }.count, 1)
        XCTAssertTrue(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
    }

    func testExistingZoomIsNotToggledOffDuringRestoration() async throws {
        var reads = 0
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            XCTAssertFalse(command.hasPrefix("resize-pane"))
            guard command.hasPrefix("display-message") else { return "" }
            reads += 1
            return self.reply(self.pair(), zoom: reads == 1 ? 0 : (reads == 4 ? 2 : nil))
        }
        XCTAssertEqual(reads, 4)
    }

    func testFailureStopsSpreadingAndRestoresZoom() async {
        var reads = 0
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
                commands.append(command)
                if command.hasPrefix("display-message") {
                    reads += 1
                    return self.reply(self.pair(), zoom: reads == 1 ? 0 : nil)
                }
                if command.hasPrefix("select-layout") { throw TmuxSplitEqualizer.Failure.layoutChanged }
                return ""
            }
            XCTFail("Expected failure")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            XCTAssertEqual(commands.filter { $0.hasPrefix("select-layout") }.count, 1)
            XCTAssertEqual(commands.last, "resize-pane -Z -t @9.%0")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testServerGeometryIsRecheckedBeforeEverySpread() async {
        let roomy = TmuxLayoutNode.split(direction: .horizontal,
            children: [pane(0, width: 6, height: 5), split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 2, height: 2) }),
                pane(4, width: 8, height: 2)
            ])], width: 15, height: 5, x: 0, y: 0)
        XCTAssertTrue(roomy.permitsNativeEqualization)
        var spreads = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: roomy) { command in
                if command.hasPrefix("display-message") { return self.reply(spreads == 0 ? roomy : self.constrained) }
                spreads += 1
                return ""
            }
            XCTFail("Must stop when the server layout becomes constrained")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(spreads, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDecorationsFailClosedInsteadOfUndercountingMinimumCells() async {
        for (status, scrollbars) in [("top", "off"), ("off", "on")] {
            var calls = 0
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: pair()) { _ in
                    calls += 1
                    return self.reply(self.pair(), status: status, scrollbars: scrollbars)
                }
                XCTFail("Decoration minima must not be ignored")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(calls, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInvalidSnapshotDoesNotMutateServer() async {
        var calls = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { _ in calls += 1; return "malformed" }
            XCTFail("Expected invalid snapshot")
        } catch TmuxSplitEqualizer.Failure.invalidSnapshot {
            XCTAssertEqual(calls, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testConcurrentResizesCannotLoopForever() async {
        var reads = 0
        let layout = pair()
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: layout) { command in
                guard command.hasPrefix("display-message") else { return "" }
                reads += 1
                return self.reply(self.pair(width: 20 + reads))
            }
            XCTFail("Expected bounded failure")
        } catch TmuxSplitEqualizer.Failure.didNotConverge {
            XCTAssertEqual(reads, 1 + layout.paneIDs.count * (2 * layout.depth + 1))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSinglePaneNeedsNoCommands() async throws {
        try await TmuxSplitEqualizer.run(windowID: 0, layout: pane(0)) { _ in
            XCTFail("A single pane is already equalized")
            return ""
        }
    }

    func testDuplicatePaneIDsAreRejectedBeforeSending() async {
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: split(.horizontal, [pane(0), pane(0)])) { _ in
                XCTFail("Malformed topology must not reach the server")
                return ""
            }
            XCTFail("Expected malformed topology to fail")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
