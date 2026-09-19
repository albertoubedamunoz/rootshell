/// A node in a tmux window's layout tree, decoded from the opaque
/// `ghostty_tmux_layout_*` accessors. Geometry is in terminal cells.
///
/// `nonisolated`: built by `TmuxReconcileDecoder.decode` on the off-main action
/// callback thread (see that type), so it must NOT pick up the project's default
/// `@MainActor` isolation. A pure value type — safe to construct/read anywhere.
nonisolated indirect enum TmuxLayoutNode: Equatable {
    case pane(paneId: Int, width: Int, height: Int, x: Int, y: Int)
    case split(direction: Direction, children: [TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)

    enum Direction: Equatable { case horizontal, vertical }

    var width: Int {
        switch self {
        case let .pane(_, w, _, _, _): return w
        case let .split(_, _, w, _, _, _): return w
        }
    }

    var height: Int {
        switch self {
        case let .pane(_, _, h, _, _): return h
        case let .split(_, _, _, h, _, _): return h
        }
    }
}

extension TmuxLayoutNode {
    var paneIDs: [Int] {
        switch self {
        case let .pane(id, _, _, _, _): return [id]
        case let .split(_, children, _, _, _, _): return children.flatMap(\.paneIDs)
        }
    }

    var depth: Int {
        switch self {
        case .pane: return 1
        case let .split(_, children, _, _, _, _): return 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    /// Geometry and zoom may change during equalization; pane placement must not.
    func hasSameTopology(as other: TmuxLayoutNode) -> Bool {
        switch (self, other) {
        case let (.pane(a, _, _, _, _), .pane(b, _, _, _, _)):
            return a == b
        case let (.split(a, lhs, _, _, _, _), .split(b, rhs, _, _, _, _)):
            return a == b && lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.hasSameTopology(as: pair.1)
            }
        default:
            return false
        }
    }
}

extension TmuxLayoutNode {
    /// tmux 3.6's layout_spread_cell bypasses layout_resize_check. A shrink
    /// below these recursive minima can trap layout_resize_adjust forever.
    /// Dividers cost one cell; additional status lines/scrollbars are excluded.
    var permitsNativeEqualization: Bool {
        permitsNativeEqualization(width: width, height: height)
    }

    private func minimumSize(along direction: Direction) -> Int {
        switch self {
        case .pane: return 1
        case let .split(axis, children, _, _, _, _):
            let sizes = children.map { $0.minimumSize(along: direction) }
            return axis == direction ? sizes.reduce(0, +) + max(0, children.count - 1) : sizes.max() ?? 1
        }
    }

    private func permitsNativeEqualization(width: Int, height: Int) -> Bool {
        guard width >= minimumSize(along: .horizontal),
              height >= minimumSize(along: .vertical) else { return false }
        guard case let .split(direction, children, _, _, _, _) = self else { return true }
        guard children.count >= 2 else { return false }
        let horizontal = direction == .horizontal
        let available = (horizontal ? width : height) - children.count + 1
        guard available >= children.count else { return false }
        for (index, child) in children.enumerated() {
            let share = available / children.count + (index < available % children.count ? 1 : 0)
            // Check descendants at the smaller of their current and eventual
            // size: -E may reach them before OR after spreading an ancestor.
            guard child.permitsNativeEqualization(
                width: min(child.width, horizontal ? share : width),
                height: min(child.height, horizontal ? height : share)
            ) else { return false }
        }
        return true
    }

    /// Parse the legacy window_layout emitted to control clients (including
    /// while zoomed). Unknown formats fail closed; never spread an unchecked tree.
    static func parseServerLayout(_ value: String) -> TmuxLayoutNode? {
        let bytes = Array(value.utf8)
        guard bytes.count > 5, bytes.count <= 131_072, bytes[4] == 44,
              let expected = UInt16(String(decoding: bytes.prefix(4), as: UTF8.self), radix: 16) else { return nil }
        var checksum: UInt16 = 0
        for byte in bytes.dropFirst(5) {
            checksum = (checksum >> 1) | (checksum << 15)
            checksum = checksum &+ UInt16(byte)
        }
        guard checksum == expected else { return nil }
        var parser = ServerLayoutParser(bytes: bytes)
        guard let node = parser.node(depth: 0), parser.index == bytes.count,
              Set(node.paneIDs).count == node.paneIDs.count else { return nil }
        return node
    }
}

private nonisolated struct ServerLayoutParser {
    let bytes: [UInt8]
    var index = 5
    var nodes = 0

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func number() -> Int? {
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard index > start, index - start <= 10 else { return nil }
        return Int(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func node(depth: Int) -> TmuxLayoutNode? {
        nodes += 1
        guard depth < 64, nodes <= 2048,
              let width = number(), width > 0, consume(120),
              let height = number(), height > 0, consume(44),
              let x = number(), consume(44), let y = number() else { return nil }
        if consume(44) {
            guard let id = number() else { return nil }
            return .pane(paneId: id, width: width, height: height, x: x, y: y)
        }
        let direction: TmuxLayoutNode.Direction
        let close: UInt8
        if consume(123) { direction = .horizontal; close = 125 }
        else if consume(91) { direction = .vertical; close = 93 }
        else { return nil }
        var children: [TmuxLayoutNode] = []
        repeat {
            guard let child = node(depth: depth + 1) else { return nil }
            children.append(child)
        } while consume(44)
        guard consume(close), children.count >= 2 else { return nil }
        // Reject inconsistent geometry instead of trusting it for the safety check.
        let extent = children.reduce(0) { $0 + (direction == .horizontal ? $1.width : $1.height) } + children.count - 1
        guard extent == (direction == .horizontal ? width : height),
              children.allSatisfy({ direction == .horizontal ? $0.height == height : $0.width == width }) else { return nil }
        return .split(direction: direction, children: children, width: width, height: height, x: x, y: y)
    }
}
