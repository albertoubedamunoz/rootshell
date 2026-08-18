//
//  VTCursorState.swift
//  rootshell
//

import Foundation

struct VTSavedCursor: Equatable, Sendable {
    var cursorCol: Int
    var cursorRow: Int
    var renditions: VTRenditions
    var autoWrapMode: Bool
    var originMode: Bool

    init() {
        cursorCol = 0
        cursorRow = 0
        renditions = VTRenditions(backgroundColor: 0)
        autoWrapMode = true
        originMode = false
    }
}

struct VTCursorState: Equatable, Sendable {
    enum MouseReportingMode: Int {
        case none = 0
        case x10 = 9
        case vt220 = 1000
        case vt220Hilite = 1001
        case btnEvent = 1002
        case anyEvent = 1003
    }

    enum MouseEncodingMode: Int {
        case `default` = 0
        case utf8 = 1005
        case sgr = 1006
        case urxvt = 1015
    }

    private var width: Int
    private var height: Int

    private var cursorCol: Int
    private var cursorRow: Int
    private var combiningCharCol: Int
    private var combiningCharRow: Int

    private var defaultTabs: Bool
    private var tabs: [Bool]

    private var scrollingRegionTopRow: Int
    private var scrollingRegionBottomRow: Int

    private var renditions: VTRenditions
    private var save: VTSavedCursor

    var nextPrintWillWrap: Bool
    var originMode: Bool
    var autoWrapMode: Bool
    var insertMode: Bool
    var cursorVisible: Bool
    var reverseVideo: Bool
    var bracketedPaste: Bool

    var mouseReportingMode: MouseReportingMode
    var mouseFocusEvent: Bool
    var mouseAlternateScroll: Bool
    var mouseEncodingMode: MouseEncodingMode

    var applicationModeCursorKeys: Bool

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        cursorCol = 0
        cursorRow = 0
        combiningCharCol = 0
        combiningCharRow = 0
        defaultTabs = true
        tabs = Array(repeating: false, count: width)
        scrollingRegionTopRow = 0
        scrollingRegionBottomRow = height - 1
        renditions = VTRenditions(backgroundColor: 0)
        save = VTSavedCursor()
        nextPrintWillWrap = false
        originMode = false
        autoWrapMode = true
        insertMode = false
        cursorVisible = true
        reverseVideo = false
        bracketedPaste = false
        mouseReportingMode = .none
        mouseFocusEvent = false
        mouseAlternateScroll = false
        mouseEncodingMode = .default
        applicationModeCursorKeys = false
        reinitializeTabs(start: 0)
    }

    mutating func reinitializeTabs(start: Int) {
        guard defaultTabs else { return }
        if start >= tabs.count {
            return
        }
        for i in start..<tabs.count {
            tabs[i] = (i % 8) == 0
        }
    }

    mutating func markCombiningPosition() {
        combiningCharCol = cursorCol
        combiningCharRow = cursorRow
    }

    mutating func clampCursorToViewport() {
        if cursorRow < limitTop() { cursorRow = limitTop() }
        if cursorRow > limitBottom() { cursorRow = limitBottom() }
        if cursorCol < 0 { cursorCol = 0 }
        if cursorCol >= width { cursorCol = width - 1 }
    }

    mutating func moveRow(_ n: Int, relative: Bool = false) {
        if relative {
            cursorRow += n
        } else {
            cursorRow = n + limitTop()
        }
        clampCursorToViewport()
        markCombiningPosition()
        nextPrintWillWrap = false
    }

    mutating func moveCol(_ n: Int, relative: Bool = false, implicit: Bool = false) {
        if implicit {
            markCombiningPosition()
        }
        if relative {
            cursorCol += n
        } else {
            cursorCol = n
        }
        if implicit {
            nextPrintWillWrap = cursorCol >= width
        }
        clampCursorToViewport()
        if !implicit {
            markCombiningPosition()
            nextPrintWillWrap = false
        }
    }

    func getCursorCol() -> Int { cursorCol }
    func getCursorRow() -> Int { cursorRow }
    func getCombiningCharCol() -> Int { combiningCharCol }
    func getCombiningCharRow() -> Int { combiningCharRow }
    func getWidth() -> Int { width }
    func getHeight() -> Int { height }

    mutating func setTab() {
        if cursorCol >= 0 && cursorCol < tabs.count {
            tabs[cursorCol] = true
        }
    }

    mutating func clearTab(_ col: Int) {
        if col >= 0 && col < tabs.count {
            tabs[col] = false
        }
    }

    mutating func clearDefaultTabs() { defaultTabs = false }

    func getNextTab(_ count: Int) -> Int {
        if count >= 0 {
            var remaining = count
            var i = cursorCol + 1
            while i < width {
                if tabs[i] {
                    remaining -= 1
                    if remaining == 0 { return i }
                }
                i += 1
            }
            return -1
        }
        var remaining = count
        var i = cursorCol - 1
        while i > 0 {
            if tabs[i] {
                remaining += 1
                if remaining == 0 { return i }
            }
            i -= 1
        }
        return 0
    }

    mutating func setScrollingRegion(top: Int, bottom: Int) {
        guard height >= 1 else { return }
        scrollingRegionTopRow = top
        scrollingRegionBottomRow = bottom

        if scrollingRegionTopRow < 0 { scrollingRegionTopRow = 0 }
        if scrollingRegionBottomRow >= height { scrollingRegionBottomRow = height - 1 }
        if scrollingRegionBottomRow < scrollingRegionTopRow {
            scrollingRegionBottomRow = scrollingRegionTopRow
        }

        if originMode {
            clampCursorToViewport()
            markCombiningPosition()
        }
    }

    func getScrollingRegionTopRow() -> Int { scrollingRegionTopRow }
    func getScrollingRegionBottomRow() -> Int { scrollingRegionBottomRow }

    func limitTop() -> Int { originMode ? scrollingRegionTopRow : 0 }
    func limitBottom() -> Int { originMode ? scrollingRegionBottomRow : height - 1 }

    mutating func setForegroundColor(_ num: Int) { renditions.setForegroundColor(num) }
    mutating func setBackgroundColor(_ num: Int) { renditions.setBackgroundColor(num) }
    mutating func addRendition(_ num: UInt32) { renditions.setRendition(num) }
    func getRenditions() -> VTRenditions { renditions }
    mutating func setRenditions(_ r: VTRenditions) { renditions = r }
    func getBackgroundRendition() -> UInt32 { renditions.getBackgroundRendition() }

    mutating func saveCursor() {
        save.cursorCol = cursorCol
        save.cursorRow = cursorRow
        save.renditions = renditions
        save.autoWrapMode = autoWrapMode
        save.originMode = originMode
    }

    mutating func restoreCursor() {
        cursorCol = save.cursorCol
        cursorRow = save.cursorRow
        renditions = save.renditions
        autoWrapMode = save.autoWrapMode
        originMode = save.originMode
        clampCursorToViewport()
        markCombiningPosition()
    }

    mutating func clearSavedCursor() { save = VTSavedCursor() }

    mutating func resize(width: Int, height: Int) {
        if self.width != width || self.height != height {
            scrollingRegionTopRow = 0
            scrollingRegionBottomRow = height - 1
        }

        tabs = Array(tabs.prefix(width))
        if tabs.count < width { tabs.append(contentsOf: Array(repeating: false, count: width - tabs.count)) }
        if defaultTabs {
            reinitializeTabs(start: self.width)
        }

        self.width = width
        self.height = height

        clampCursorToViewport()

        if combiningCharCol >= width || combiningCharRow >= height {
            combiningCharCol = -1
            combiningCharRow = -1
        }
    }

    static func == (lhs: VTCursorState, rhs: VTCursorState) -> Bool {
        return lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.cursorCol == rhs.cursorCol
            && lhs.cursorRow == rhs.cursorRow
            && lhs.cursorVisible == rhs.cursorVisible
            && lhs.reverseVideo == rhs.reverseVideo
            && lhs.renditions == rhs.renditions
            && lhs.bracketedPaste == rhs.bracketedPaste
            && lhs.mouseReportingMode == rhs.mouseReportingMode
            && lhs.mouseFocusEvent == rhs.mouseFocusEvent
            && lhs.mouseAlternateScroll == rhs.mouseAlternateScroll
            && lhs.mouseEncodingMode == rhs.mouseEncodingMode
    }
}
