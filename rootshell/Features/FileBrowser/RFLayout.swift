#if !targetEnvironment(macCatalyst)

import Foundation

/// A rectangular region in the terminal grid (0-indexed).
struct TUIRegion: Sendable, Equatable {
    let row: Int
    let col: Int
    let width: Int
    let height: Int

    static let zero = TUIRegion(row: 0, col: 0, width: 0, height: 0)

    func contains(row r: Int, col c: Int) -> Bool {
        r >= row && r < row + height && c >= col && c < col + width
    }

    /// Convert a terminal-absolute row to a region-relative row.
    func relativeRow(_ absRow: Int) -> Int {
        absRow - row
    }
}

/// Miller column layout calculator with draggable separator support.
@MainActor
final class RFLayout {
    private(set) var cols: Int
    private(set) var rows: Int

    /// Column width ratios. Must sum to ~1.0.
    private var ratios: (Double, Double, Double) = (0.20, 0.35, 0.45)

    /// Minimum column width in cells.
    private static let minColumnWidth = 8

    // Computed regions
    private(set) var tabBarRegion: TUIRegion = .zero
    private(set) var headerRegion: TUIRegion = .zero
    private(set) var parentRegion: TUIRegion = .zero
    private(set) var currentRegion: TUIRegion = .zero
    private(set) var previewRegion: TUIRegion = .zero
    private(set) var statusBarRegion: TUIRegion = .zero

    /// Separator column positions (absolute terminal column index)
    private(set) var separator1Col: Int = 0
    private(set) var separator2Col: Int = 0

    /// Whether to show the tab bar (>1 tab)
    var showTabBar: Bool = false {
        didSet {
            if oldValue != showTabBar { recalculate() }
        }
    }

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        recalculate()
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        recalculate()
    }

    // MARK: - Separator Dragging

    /// Move a separator to a new column position.
    /// index 0 = left separator, 1 = right separator.
    func moveSeparator(index: Int, toCol newCol: Int) {
        let usableWidth = cols - 2  // 2 separator columns
        let minW = Self.minColumnWidth

        switch index {
        case 0:
            // Dragging left separator: adjust parent and current widths
            let parentW = max(minW, min(newCol, usableWidth - 2 * minW))
            let previewW = Int(Double(usableWidth) * ratios.2)
            let currentW = max(minW, usableWidth - parentW - max(minW, previewW))
            let actualPreviewW = max(minW, usableWidth - parentW - currentW)
            let total = Double(usableWidth)
            ratios.0 = Double(parentW) / total
            ratios.1 = Double(currentW) / total
            ratios.2 = Double(actualPreviewW) / total

        case 1:
            // Dragging right separator: adjust current and preview widths
            let parentW = Int(Double(usableWidth) * ratios.0)
            let actualParentW = max(minW, parentW)
            let currentW = max(minW, min(newCol - actualParentW - 1, usableWidth - actualParentW - minW))
            let previewW = max(minW, usableWidth - actualParentW - currentW)
            let total = Double(usableWidth)
            ratios.0 = Double(actualParentW) / total
            ratios.1 = Double(currentW) / total
            ratios.2 = Double(previewW) / total

        default: break
        }

        recalculate()
    }

    // MARK: - Hit Testing

    enum HitTarget: Equatable {
        case tabBar
        case header
        case parentColumn
        case currentColumn
        case previewColumn
        case statusBar
        case separator(Int)  // 0 = left, 1 = right
        case none
    }

    func hitTest(row: Int, col: Int) -> HitTarget {
        if tabBarRegion.height > 0, tabBarRegion.contains(row: row, col: col) { return .tabBar }
        if headerRegion.contains(row: row, col: col) { return .header }
        if statusBarRegion.contains(row: row, col: col) { return .statusBar }

        // Check separators (in body area only)
        let bodyTop = headerRegion.row + headerRegion.height
        let bodyBottom = statusBarRegion.row
        if row >= bodyTop, row < bodyBottom {
            if col == separator1Col { return .separator(0) }
            if col == separator2Col { return .separator(1) }
        }

        if parentRegion.contains(row: row, col: col) { return .parentColumn }
        if currentRegion.contains(row: row, col: col) { return .currentColumn }
        if previewRegion.contains(row: row, col: col) { return .previewColumn }
        return .none
    }

    // MARK: - Private

    private func recalculate() {
        guard cols > 0, rows > 0 else { return }

        // Layout rows:
        // [tabBar if shown] [header] [body columns] [statusBar]
        var currentRow = 0

        if showTabBar {
            tabBarRegion = TUIRegion(row: currentRow, col: 0, width: cols, height: 1)
            currentRow += 1
        } else {
            tabBarRegion = .zero
        }

        headerRegion = TUIRegion(row: currentRow, col: 0, width: cols, height: 1)
        currentRow += 1

        statusBarRegion = TUIRegion(row: rows - 1, col: 0, width: cols, height: 1)

        let bodyHeight = max(1, rows - 1 - currentRow)

        // Distribute width: cols - 2 (for separator columns) among 3 columns
        let usableWidth = max(3 * Self.minColumnWidth, cols - 2)
        let minW = Self.minColumnWidth

        let parentW = max(minW, Int(Double(usableWidth) * ratios.0))
        let previewW = max(minW, Int(Double(usableWidth) * ratios.2))
        var currentW = max(minW, usableWidth - parentW - previewW)

        // Ensure total doesn't exceed usable
        let totalW = parentW + currentW + previewW
        if totalW > usableWidth {
            let excess = totalW - usableWidth
            currentW = max(minW, currentW - excess)
        }

        separator1Col = parentW
        separator2Col = parentW + 1 + currentW

        parentRegion = TUIRegion(row: currentRow, col: 0, width: parentW, height: bodyHeight)
        currentRegion = TUIRegion(row: currentRow, col: parentW + 1, width: currentW, height: bodyHeight)
        previewRegion = TUIRegion(row: currentRow, col: separator2Col + 1, width: cols - separator2Col - 1, height: bodyHeight)
    }
}

#endif
