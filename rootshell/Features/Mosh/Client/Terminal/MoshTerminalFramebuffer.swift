//
//  VTFramebuffer.swift
//  rootshell
//

import Foundation

final class VTFramebuffer: Equatable, @unchecked Sendable {
    typealias TitleType = [UnicodeScalar]

    private var rows: [VTRow]
    private var iconName: TitleType
    private var windowTitle: TitleType
    private var clipboard: TitleType
    private var bellCount: UInt32
    private var titleInitialized: Bool

    var cursorState: VTCursorState

    init(width: Int, height: Int) {
        precondition(width > 0 && height > 0)
        let background: UInt32 = 0
        let row = VTRow(width: width, backgroundColor: background)
        self.rows = Array(repeating: row, count: height)
        self.iconName = []
        self.windowTitle = []
        self.clipboard = []
        self.bellCount = 0
        self.titleInitialized = false
        self.cursorState = VTCursorState(width: width, height: height)
    }

    func copy() -> VTFramebuffer {
        let fb = VTFramebuffer(width: cursorState.getWidth(), height: cursorState.getHeight())
        fb.rows = rows
        fb.iconName = iconName
        fb.windowTitle = windowTitle
        fb.clipboard = clipboard
        fb.bellCount = bellCount
        fb.titleInitialized = titleInitialized
        fb.cursorState = cursorState
        return fb
    }

    func getRows() -> [VTRow] { rows }

    func scroll(_ n: Int) {
        if n >= 0 {
            deleteLine(at: cursorState.getScrollingRegionTopRow(), count: n)
        } else {
            insertLine(beforeRow: cursorState.getScrollingRegionTopRow(), count: -n)
        }
    }

    func advanceCursorWithScroll(_ rowsToMove: Int) {
        if cursorState.getCursorRow() < cursorState.getScrollingRegionTopRow() || cursorState.getCursorRow() > cursorState.getScrollingRegionBottomRow() {
            cursorState.moveRow(rowsToMove, relative: true)
            return
        }

        if cursorState.getCursorRow() + rowsToMove > cursorState.getScrollingRegionBottomRow() {
            let n = cursorState.getCursorRow() + rowsToMove - cursorState.getScrollingRegionBottomRow()
            scroll(n)
            cursorState.moveRow(-n, relative: true)
        } else if cursorState.getCursorRow() + rowsToMove < cursorState.getScrollingRegionTopRow() {
            let n = cursorState.getCursorRow() + rowsToMove - cursorState.getScrollingRegionTopRow()
            scroll(n)
            cursorState.moveRow(-n, relative: true)
        }

        cursorState.moveRow(rowsToMove, relative: true)
    }

    func getRow(_ row: Int) -> VTRow {
        let r = row == -1 ? cursorState.getCursorRow() : row
        return rows[r]
    }

    func getCell(row: Int = -1, col: Int = -1) -> VTCell {
        let r = row == -1 ? cursorState.getCursorRow() : row
        let c = col == -1 ? cursorState.getCursorCol() : col
        return rows[r].cells[c]
    }

    func ensureUniqueRow(_ row: Int) -> VTRow {
        let r = row == -1 ? cursorState.getCursorRow() : row
        var rowRef = rows[r]
        if !isKnownUniquelyReferenced(&rowRef) {
            rowRef = rowRef.copy()
            rows[r] = rowRef
        }
        return rowRef
    }

    func getMutableCell(row: Int = -1, col: Int = -1) -> VTCell {
        let r = row == -1 ? cursorState.getCursorRow() : row
        let c = col == -1 ? cursorState.getCursorCol() : col
        let rowRef = ensureUniqueRow(r)
        return rowRef.cells[c]
    }

    func setMutableCell(_ cell: VTCell, row: Int = -1, col: Int = -1) {
        let r = row == -1 ? cursorState.getCursorRow() : row
        let c = col == -1 ? cursorState.getCursorCol() : col
        let rowRef = ensureUniqueRow(r)
        rowRef.cells[c] = cell
    }

    func getCombiningCell() -> VTCell? {
        let col = cursorState.getCombiningCharCol()
        let row = cursorState.getCombiningCharRow()
        if col < 0 || row < 0 || col >= cursorState.getWidth() || row >= cursorState.getHeight() {
            return nil
        }
        return getMutableCell(row: row, col: col)
    }

    func applyRenditionsToCell(_ cell: inout VTCell?) {
        if cell == nil {
            var c = getMutableCell()
            c.setRenditions(cursorState.getRenditions())
            setMutableCell(c)
            cell = c
            return
        }
        cell?.setRenditions(cursorState.getRenditions())
    }

    func insertLine(beforeRow: Int, count: Int) {
        if beforeRow < cursorState.getScrollingRegionTopRow() || beforeRow > cursorState.getScrollingRegionBottomRow() + 1 {
            return
        }

        var scroll = cursorState.getScrollingRegionBottomRow() + 1 - beforeRow
        if count < scroll { scroll = count }
        if scroll == 0 { return }

        let start = cursorState.getScrollingRegionBottomRow() + 1 - scroll
        rows.removeSubrange(start..<start + scroll)
        let blank = newRow()
        rows.insert(contentsOf: Array(repeating: blank, count: scroll), at: beforeRow)
    }

    func deleteLine(at row: Int, count: Int) {
        if row < cursorState.getScrollingRegionTopRow() || row > cursorState.getScrollingRegionBottomRow() {
            return
        }

        var scroll = cursorState.getScrollingRegionBottomRow() + 1 - row
        if count < scroll { scroll = count }
        if scroll == 0 { return }

        rows.removeSubrange(row..<row + scroll)
        let blank = newRow()
        let insertAt = cursorState.getScrollingRegionBottomRow() + 1 - scroll
        rows.insert(contentsOf: Array(repeating: blank, count: scroll), at: insertAt)
    }

    func insertCell(row: Int, col: Int) {
        ensureUniqueRow(row).insertCell(at: col, backgroundColor: cursorState.getBackgroundRendition())
    }

    func deleteCell(row: Int, col: Int) {
        ensureUniqueRow(row).deleteCell(at: col, backgroundColor: cursorState.getBackgroundRendition())
    }

    func reset() {
        let width = cursorState.getWidth()
        let height = cursorState.getHeight()
        cursorState = VTCursorState(width: width, height: height)
        rows = Array(repeating: newRow(), count: height)
        windowTitle.removeAll(keepingCapacity: true)
        clipboard.removeAll(keepingCapacity: true)
    }

    func softReset() {
        cursorState.insertMode = false
        cursorState.originMode = false
        cursorState.cursorVisible = true
        cursorState.applicationModeCursorKeys = false
        cursorState.setScrollingRegion(top: 0, bottom: cursorState.getHeight() - 1)
        cursorState.addRendition(0)
        cursorState.clearSavedCursor()
    }

    func resize(width: Int, height: Int) {
        precondition(width > 0 && height > 0)

        let oldHeight = cursorState.getHeight()
        let oldWidth = cursorState.getWidth()
        cursorState.resize(width: width, height: height)

        let blankRow = newRow()
        if oldHeight != height {
            if rows.count < height {
                rows.append(contentsOf: Array(repeating: blankRow, count: height - rows.count))
            } else if rows.count > height {
                rows.removeLast(rows.count - height)
            }
        }
        if oldWidth == width {
            return
        }
        for index in rows.indices {
            if rows[index] === blankRow { continue }
            let rowCopy = rows[index].copy()
            rowCopy.setWrap(false)
            if rowCopy.cells.count < width {
                rowCopy.cells.append(contentsOf: Array(repeating: VTCell(backgroundColor: cursorState.getBackgroundRendition()), count: width - rowCopy.cells.count))
            } else if rowCopy.cells.count > width {
                rowCopy.cells.removeLast(rowCopy.cells.count - width)
            }
            rows[index] = rowCopy
        }
    }

    func resetCell(_ cell: inout VTCell) {
        cell.reset(backgroundColor: cursorState.getBackgroundRendition())
    }

    func resetRow(_ row: VTRow) {
        row.reset(backgroundColor: cursorState.getBackgroundRendition())
    }

    func ringBell() { bellCount += 1 }

    func getBellCount() -> UInt32 { bellCount }

    func setTitleInitialized() { titleInitialized = true }
    func isTitleInitialized() -> Bool { titleInitialized }

    func setIconName(_ title: TitleType) { iconName = title }
    func setWindowTitle(_ title: TitleType) { windowTitle = title }
    func setClipboard(_ title: TitleType) { clipboard = title }

    func getIconName() -> TitleType { iconName }
    func getWindowTitle() -> TitleType { windowTitle }
    func getClipboard() -> TitleType { clipboard }

    func prefixWindowTitle(_ prefix: TitleType) {
        if iconName == windowTitle {
            iconName.insert(contentsOf: prefix, at: 0)
        }
        windowTitle.insert(contentsOf: prefix, at: 0)
    }

    private func newRow() -> VTRow {
        let w = cursorState.getWidth()
        let c = cursorState.getBackgroundRendition()
        return VTRow(width: w, backgroundColor: c)
    }

    static func == (lhs: VTFramebuffer, rhs: VTFramebuffer) -> Bool {
        if lhs.rows.count != rhs.rows.count { return false }
        for (a, b) in zip(lhs.rows, rhs.rows) {
            if a !== b { return false }
        }
        return lhs.windowTitle == rhs.windowTitle
            && lhs.clipboard == rhs.clipboard
            && lhs.bellCount == rhs.bellCount
            && lhs.cursorState == rhs.cursorState
    }
}
