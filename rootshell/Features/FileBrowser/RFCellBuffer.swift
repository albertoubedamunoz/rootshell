#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - Cell Types

/// Text attributes for a terminal cell.
nonisolated struct TUIAttributes: OptionSet, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let bold          = TUIAttributes(rawValue: 1 << 0)
    static let dim           = TUIAttributes(rawValue: 1 << 1)
    static let italic        = TUIAttributes(rawValue: 1 << 2)
    static let underline     = TUIAttributes(rawValue: 1 << 3)
    static let reverse       = TUIAttributes(rawValue: 1 << 4)
    static let strikethrough = TUIAttributes(rawValue: 1 << 5)
}

/// Style for a terminal cell: foreground, background, and text attributes.
/// nil fg/bg means "use terminal default" (no color escape emitted).
nonisolated struct TUIStyle: Equatable, Sendable {
    var fg: (UInt8, UInt8, UInt8)?
    var bg: (UInt8, UInt8, UInt8)?
    var attrs: TUIAttributes

    static let plain = TUIStyle(fg: nil, bg: nil, attrs: [])

    init(fg: (UInt8, UInt8, UInt8)? = nil, bg: (UInt8, UInt8, UInt8)? = nil, attrs: TUIAttributes = []) {
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
    }

    static func == (lhs: TUIStyle, rhs: TUIStyle) -> Bool {
        lhs.attrs == rhs.attrs
            && lhs.fg?.0 == rhs.fg?.0 && lhs.fg?.1 == rhs.fg?.1 && lhs.fg?.2 == rhs.fg?.2
            && lhs.bg?.0 == rhs.bg?.0 && lhs.bg?.1 == rhs.bg?.1 && lhs.bg?.2 == rhs.bg?.2
    }
}

/// A single cell in the terminal buffer.
nonisolated struct TUICell: Equatable, Sendable {
    var character: Character
    var style: TUIStyle
    /// True for the trailing half of a wide (2-cell) glyph. The renderer emits
    /// nothing for these — the preceding wide glyph already advanced the cursor.
    var isContinuation: Bool = false

    static let empty = TUICell(character: " ", style: .plain)

    /// The trailing half of a wide glyph occupying the previous column.
    static func continuation(style: TUIStyle) -> TUICell {
        TUICell(character: " ", style: style, isContinuation: true)
    }

    static func == (lhs: TUICell, rhs: TUICell) -> Bool {
        lhs.character == rhs.character && lhs.style == rhs.style && lhs.isContinuation == rhs.isContinuation
    }
}

// MARK: - Cell Buffer

/// 2D cell grid with row-level dirty tracking for efficient differential rendering.
/// Row-major layout: cells[row * cols + col].
@MainActor
final class RFCellBuffer {
    private(set) var cols: Int
    private(set) var rows: Int

    /// Current frame buffer
    private var cells: [TUICell]

    /// Previous frame buffer (for diffing)
    private var prevCells: [TUICell]

    /// Dirty rows that need re-rendering
    private var dirtyRows: Set<Int>

    /// Whether a full redraw is needed (resize, initial)
    private(set) var needsFullRedraw: Bool = true

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        let count = cols * rows
        self.cells = Array(repeating: .empty, count: count)
        self.prevCells = Array(repeating: .empty, count: count)
        self.dirtyRows = Set(0..<rows)
    }

    /// Resize the buffer. Clears all content and forces full redraw.
    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        let count = cols * rows
        self.cells = Array(repeating: .empty, count: count)
        self.prevCells = Array(repeating: .empty, count: count)
        self.dirtyRows = Set(0..<rows)
        self.needsFullRedraw = true
    }

    /// Set a single cell. Marks its row dirty.
    func setCell(row: Int, col: Int, _ cell: TUICell) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        cells[row * cols + col] = cell
        dirtyRows.insert(row)
    }

    /// Write a string starting at (row, col) with the given style.
    /// Characters beyond the right edge are clipped.
    /// Returns the column after the last written character.
    @discardableResult
    func write(row: Int, col: Int, _ text: String, style: TUIStyle) -> Int {
        guard row >= 0, row < rows else { return col }
        var c = col
        for char in text {
            guard c < cols else { break }
            let w = RFWidth.width(of: char)
            if w == 2 && c + 1 >= cols {
                // No room for the trailing half of a wide glyph; clip with a space.
                if c >= 0 { cells[row * cols + c] = TUICell(character: " ", style: style) }
                c += 1
                break
            }
            if c >= 0 {
                cells[row * cols + c] = TUICell(character: char, style: style)
                if w == 2 {
                    cells[row * cols + c + 1] = TUICell.continuation(style: style)
                }
            }
            c += w
        }
        if c > col { dirtyRows.insert(row) }
        return c
    }

    /// Write a string, truncating with ellipsis if it exceeds maxWidth.
    /// maxWidth is measured in display cells. Returns the column after the last
    /// written cell.
    @discardableResult
    func writeTruncated(row: Int, col: Int, _ text: String, style: TUIStyle, maxWidth: Int) -> Int {
        guard row >= 0, row < rows, maxWidth > 0 else { return col }
        if RFWidth.width(of: text) <= maxWidth {
            return write(row: row, col: col, text, style: style)
        }
        // Truncate by display width, leaving 1 cell for the ellipsis.
        var used = 0
        var truncated = ""
        for char in text {
            let w = RFWidth.width(of: char)
            if used + w > maxWidth - 1 { break }
            truncated.append(char)
            used += w
        }
        truncated.append("…")
        return write(row: row, col: col, truncated, style: style)
    }

    /// Fill a rectangular region with a cell.
    func fill(row: Int, col: Int, width: Int, height: Int, cell: TUICell = .empty) {
        for r in row..<min(row + height, rows) {
            guard r >= 0 else { continue }
            for c in col..<min(col + width, cols) {
                guard c >= 0 else { continue }
                cells[r * cols + c] = cell
            }
            dirtyRows.insert(r)
        }
    }

    /// Fill an entire row with a cell.
    func fillRow(_ row: Int, cell: TUICell = .empty) {
        guard row >= 0, row < rows else { return }
        for c in 0..<cols {
            cells[row * cols + c] = cell
        }
        dirtyRows.insert(row)
    }

    /// Clear the entire buffer to empty cells. Forces full redraw.
    func clear() {
        cells = Array(repeating: .empty, count: cols * rows)
        dirtyRows = Set(0..<rows)
        needsFullRedraw = true
    }

    /// Read a cell value.
    func cell(row: Int, col: Int) -> TUICell {
        guard row >= 0, row < rows, col >= 0, col < cols else { return .empty }
        return cells[row * cols + col]
    }

    /// The set of rows modified since last commitFrame().
    var modifiedRows: Set<Int> { dirtyRows }

    /// Snapshot current frame as "previous". Call after rendering.
    func commitFrame() {
        prevCells = cells
        dirtyRows.removeAll()
        needsFullRedraw = false
    }

    /// Force a full redraw on next render.
    func invalidate() {
        needsFullRedraw = true
        dirtyRows = Set(0..<rows)
    }
}

#endif
