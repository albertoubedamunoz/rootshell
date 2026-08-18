//
//  VTSequenceHandlers.swift
//  rootshell
//

import Foundation
import Darwin

enum VTSequenceHandlers {
    private static var registered = false

    static func registerAll() {
        if registered { return }
        registered = true

        let registry = VTFunctionRegistry.shared

        func reg(_ type: VTFunctionType, _ key: String, _ clearsWrap: Bool = true, _ fn: @escaping (VTFramebuffer, VTSequenceDispatcher) -> Void) {
            registry.register(type, dispatchChars: key, function: fn, clearsWrapState: clearsWrap)
        }

        // CSI EL
        reg(.csi, "K") { fb, dispatch in handleEraseLine(fb, dispatch) }
        // CSI ED
        reg(.csi, "J") { fb, dispatch in csiED(fb, dispatch) }
        // cursor movement
        reg(.csi, "A") { fb, dispatch in csiCursorMove(fb, dispatch) }
        reg(.csi, "B") { fb, dispatch in csiCursorMove(fb, dispatch) }
        reg(.csi, "C") { fb, dispatch in csiCursorMove(fb, dispatch) }
        reg(.csi, "D") { fb, dispatch in csiCursorMove(fb, dispatch) }
        reg(.csi, "H") { fb, dispatch in csiCursorMove(fb, dispatch) }
        reg(.csi, "f") { fb, dispatch in csiCursorMove(fb, dispatch) }
        // device attributes
        reg(.csi, "c") { _, dispatch in appendToHost(dispatch, "\u{1b}[?62c") }
        reg(.csi, ">c") { _, dispatch in appendToHost(dispatch, "\u{1b}[>1;10;0c") }
        // screen alignment
        reg(.escape, "#8") { fb, _ in escDECALN(fb) }
        // line feed / index / etc
        reg(.control, "\u{000A}") { fb, _ in ctrlLF(fb) }
        reg(.control, "\u{0084}") { fb, _ in ctrlLF(fb) }
        reg(.control, "\u{000B}") { fb, _ in ctrlLF(fb) }
        reg(.control, "\u{000C}") { fb, _ in ctrlLF(fb) }
        // carriage return
        reg(.control, "\u{000D}") { fb, _ in fb.cursorState.moveCol(0) }
        // backspace
        reg(.control, "\u{0008}") { fb, _ in fb.cursorState.moveCol(-1, relative: true) }
        // reverse index
        reg(.control, "\u{008D}") { fb, _ in fb.advanceCursorWithScroll(-1) }
        // NEL
        reg(.control, "\u{0085}") { fb, _ in ctrlNEL(fb) }
        // horizontal tab
        reg(.control, "\u{0009}", false) { fb, _ in ctrlHT(fb) }
        // CHT / CBT
        reg(.csi, "I", false) { fb, dispatch in csiCxT(fb, dispatch) }
        reg(.csi, "Z", false) { fb, dispatch in csiCxT(fb, dispatch) }
        // HTS
        reg(.control, "\u{0088}") { fb, _ in fb.cursorState.setTab() }
        // TBC
        reg(.csi, "g", false) { fb, dispatch in csiTBC(fb, dispatch) }
        // DECSM / DECRM
        reg(.csi, "?h", false) { fb, dispatch in csiDECSM(fb, dispatch, value: true) }
        reg(.csi, "?l", false) { fb, dispatch in csiDECSM(fb, dispatch, value: false) }
        // SM / RM
        reg(.csi, "h") { fb, dispatch in csiSM(fb, dispatch, value: true) }
        reg(.csi, "l") { fb, dispatch in csiSM(fb, dispatch, value: false) }
        // DECSTBM
        reg(.csi, "r") { fb, dispatch in csiDECSTBM(fb, dispatch) }
        // bell
        reg(.control, "\u{0007}") { fb, _ in fb.ringBell() }
        // SGR
        reg(.csi, "m", false) { fb, dispatch in handleGraphicRendition(fb, dispatch) }
        // save/restore cursor
        reg(.escape, "7") { fb, _ in fb.cursorState.saveCursor() }
        reg(.escape, "8") { fb, _ in fb.cursorState.restoreCursor() }
        // DSR
        reg(.csi, "n") { fb, dispatch in csiDSR(fb, dispatch) }
        // insert/delete lines
        reg(.csi, "L") { fb, dispatch in csiIL(fb, dispatch) }
        reg(.csi, "M") { fb, dispatch in csiDL(fb, dispatch) }
        // insert/delete chars
        reg(.csi, "@") { fb, dispatch in csiICH(fb, dispatch) }
        reg(.csi, "P") { fb, dispatch in csiDCH(fb, dispatch) }
        // VPA / HPA
        reg(.csi, "d") { fb, dispatch in csiVPA(fb, dispatch) }
        reg(.csi, "G") { fb, dispatch in csiHPA(fb, dispatch) }
        reg(.csi, "`") { fb, dispatch in csiHPA(fb, dispatch) }
        // ECH
        reg(.csi, "X") { fb, dispatch in csiECH(fb, dispatch) }
        // RIS
        reg(.escape, "c") { fb, _ in fb.reset() }
        // DECSTR
        reg(.csi, "!p") { fb, _ in fb.softReset() }
        // SD / SU
        reg(.csi, "S") { fb, dispatch in csiSD(fb, dispatch) }
        reg(.csi, "T") { fb, dispatch in csiSU(fb, dispatch) }
    }

    private static func appendToHost(_ dispatcher: VTSequenceDispatcher, _ string: String) {
        dispatcher.hostResponseBuffer.append(contentsOf: string.utf8)
    }

    private static func clearLine(_ fb: VTFramebuffer, row: Int, start: Int, end: Int) {
        let r = row == -1 ? fb.cursorState.getCursorRow() : row
        let rowRef = fb.ensureUniqueRow(r)
        let limit = min(end, rowRef.cells.count - 1)
        if start > limit { return }
        for col in start...limit {
            var cell = rowRef.cells[col]
            cell.reset(backgroundColor: fb.cursorState.getBackgroundRendition())
            rowRef.cells[col] = cell
        }
    }

    private static func handleEraseLine(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        switch dispatch.getParam(0, default: 0) {
        case 0:
            clearLine(fb, row: -1, start: fb.cursorState.getCursorCol(), end: fb.cursorState.getWidth() - 1)
        case 1:
            clearLine(fb, row: -1, start: 0, end: fb.cursorState.getCursorCol())
        case 2:
            fb.resetRow(fb.ensureUniqueRow(-1))
        default:
            break
        }
    }

    private static func csiED(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        switch dispatch.getParam(0, default: 0) {
        case 0:
            clearLine(fb, row: -1, start: fb.cursorState.getCursorCol(), end: fb.cursorState.getWidth() - 1)
            if fb.cursorState.getCursorRow() + 1 < fb.cursorState.getHeight() {
                for y in (fb.cursorState.getCursorRow() + 1)..<fb.cursorState.getHeight() {
                    fb.resetRow(fb.ensureUniqueRow(y))
                }
            }
        case 1:
            if fb.cursorState.getCursorRow() > 0 {
                for y in 0..<fb.cursorState.getCursorRow() {
                    fb.resetRow(fb.ensureUniqueRow(y))
                }
            }
            clearLine(fb, row: -1, start: 0, end: fb.cursorState.getCursorCol())
        case 2:
            for y in 0..<fb.cursorState.getHeight() {
                fb.resetRow(fb.ensureUniqueRow(y))
            }
        default:
            break
        }
    }

    private static func csiCursorMove(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        guard let ch = dispatch.getDispatchChars().first else { return }
        let num = dispatch.getParam(0, default: 1)
        switch ch {
        case "A":
            fb.cursorState.moveRow(-num, relative: true)
        case "B":
            fb.cursorState.moveRow(num, relative: true)
        case "C":
            fb.cursorState.moveCol(num, relative: true)
        case "D":
            fb.cursorState.moveCol(-num, relative: true)
        case "H", "f":
            fb.cursorState.moveRow(dispatch.getParam(0, default: 1) - 1)
            fb.cursorState.moveCol(dispatch.getParam(1, default: 1) - 1)
        default:
            break
        }
    }

    private static func escDECALN(_ fb: VTFramebuffer) {
        for y in 0..<fb.cursorState.getHeight() {
            for x in 0..<fb.cursorState.getWidth() {
                var cell = fb.getMutableCell(row: y, col: x)
                cell.reset(backgroundColor: fb.cursorState.getBackgroundRendition())
                cell.append(UInt32(UnicodeScalar("E").value))
                fb.setMutableCell(cell, row: y, col: x)
            }
        }
    }

    private static func ctrlLF(_ fb: VTFramebuffer) {
        fb.advanceCursorWithScroll(1)
    }

    private static func ctrlNEL(_ fb: VTFramebuffer) {
        fb.cursorState.moveCol(0)
        fb.advanceCursorWithScroll(1)
    }

    private static func ctrlHT(_ fb: VTFramebuffer) {
        advanceToTabStop(fb, count: 1)
    }

    private static func advanceToTabStop(_ fb: VTFramebuffer, count: Int) {
        var col = fb.cursorState.getNextTab(count)
        if col == -1 {
            col = fb.cursorState.getWidth() - 1
        }
        let wrapState = fb.cursorState.nextPrintWillWrap
        fb.cursorState.moveCol(col, relative: false)
        fb.cursorState.nextPrintWillWrap = wrapState
    }

    private static func csiCxT(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let param = dispatch.getParam(0, default: 1)
        guard let ch = dispatch.getDispatchChars().first else { return }
        let count = ch == "Z" ? -param : param
        if count == 0 { return }
        advanceToTabStop(fb, count: count)
    }

    private static func csiTBC(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let param = dispatch.getParam(0, default: 0)
        switch param {
        case 0:
            fb.cursorState.clearTab(fb.cursorState.getCursorCol())
        case 3:
            fb.cursorState.clearDefaultTabs()
            for x in 0..<fb.cursorState.getWidth() {
                fb.cursorState.clearTab(x)
            }
        default:
            break
        }
    }

    private static func csiDECSM(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher, value: Bool) {
        for i in 0..<dispatch.paramCount() {
            let param = dispatch.getParam(i, default: 0)
            if param == 9 || (1000...1003).contains(param) {
                if value {
                    fb.cursorState.mouseReportingMode = VTCursorState.MouseReportingMode(rawValue: param) ?? .none
                } else {
                    fb.cursorState.mouseReportingMode = .none
                }
            } else if param == 1005 || param == 1006 || param == 1015 {
                if value {
                    fb.cursorState.mouseEncodingMode = VTCursorState.MouseEncodingMode(rawValue: param) ?? .default
                } else {
                    fb.cursorState.mouseEncodingMode = .default
                }
            } else {
                setDecMode(fb, param: param, value: value)
            }
        }
    }

    private static func setDecMode(_ fb: VTFramebuffer, param: Int, value: Bool) {
        switch param {
        case 1:
            fb.cursorState.applicationModeCursorKeys = value
        case 3:
            fb.cursorState.moveRow(0)
            fb.cursorState.moveCol(0)
            for y in 0..<fb.cursorState.getHeight() {
                fb.resetRow(fb.ensureUniqueRow(y))
            }
        case 5:
            fb.cursorState.reverseVideo = value
        case 6:
            fb.cursorState.moveRow(0)
            fb.cursorState.moveCol(0)
            fb.cursorState.originMode = value
        case 7:
            fb.cursorState.autoWrapMode = value
        case 25:
            fb.cursorState.cursorVisible = value
        case 1004:
            fb.cursorState.mouseFocusEvent = value
        case 1007:
            fb.cursorState.mouseAlternateScroll = value
        case 2004:
            fb.cursorState.bracketedPaste = value
        default:
            break
        }
    }

    private static func csiSM(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher, value: Bool) {
        for i in 0..<dispatch.paramCount() {
            let param = dispatch.getParam(i, default: 0)
            if param == 4 {
                fb.cursorState.insertMode = value
            }
        }
    }

    private static func csiDECSTBM(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let top = dispatch.getParam(0, default: 1)
        let bottom = dispatch.getParam(1, default: fb.cursorState.getHeight())
        if bottom <= top || top > fb.cursorState.getHeight() || (top == 0 && bottom == 1) {
            return
        }
        fb.cursorState.setScrollingRegion(top: top - 1, bottom: bottom - 1)
        fb.cursorState.moveRow(0)
        fb.cursorState.moveCol(0)
    }

    private static func handleGraphicRendition(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        var i = 0
        let count = dispatch.paramCount()
        while i < count {
            let rendition = dispatch.getParam(i, default: 0)
            if (rendition == 38 || rendition == 48) && (count - i >= 3) && dispatch.getParam(i + 1, default: -1) == 5 {
                let color = dispatch.getParam(i + 2, default: 0)
                if rendition == 38 {
                    fb.cursorState.setForegroundColor(color)
                } else {
                    fb.cursorState.setBackgroundColor(color)
                }
                i += 3
                continue
            }
            if (rendition == 38 || rendition == 48) && (count - i >= 5) && dispatch.getParam(i + 1, default: -1) == 2 {
                let red = dispatch.getParam(i + 2, default: 0)
                let green = dispatch.getParam(i + 3, default: 0)
                let blue = dispatch.getParam(i + 4, default: 0)
                let color = VTRenditions.makeTrueColor(UInt32(red), UInt32(green), UInt32(blue))
                if rendition == 38 {
                    fb.cursorState.setForegroundColor(Int(color))
                } else {
                    fb.cursorState.setBackgroundColor(Int(color))
                }
                i += 5
                continue
            }
            fb.cursorState.addRendition(UInt32(rendition))
            i += 1
        }
    }

    private static func csiDSR(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let param = dispatch.getParam(0, default: 0)
        switch param {
        case 5:
            appendToHost(dispatch, "\u{1b}[0n")
        case 6:
            let row = fb.cursorState.getCursorRow() + 1
            let col = fb.cursorState.getCursorCol() + 1
            appendToHost(dispatch, "\u{1b}[\(row);\(col)R")
        default:
            break
        }
    }

    private static func csiIL(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let lines = dispatch.getParam(0, default: 1)
        fb.insertLine(beforeRow: fb.cursorState.getCursorRow(), count: lines)
        fb.cursorState.moveCol(0)
    }

    private static func csiDL(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let lines = dispatch.getParam(0, default: 1)
        fb.deleteLine(at: fb.cursorState.getCursorRow(), count: lines)
        fb.cursorState.moveCol(0)
    }

    private static func csiICH(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let cells = dispatch.getParam(0, default: 1)
        for _ in 0..<cells {
            fb.insertCell(row: fb.cursorState.getCursorRow(), col: fb.cursorState.getCursorCol())
        }
    }

    private static func csiDCH(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let cells = dispatch.getParam(0, default: 1)
        for _ in 0..<cells {
            fb.deleteCell(row: fb.cursorState.getCursorRow(), col: fb.cursorState.getCursorCol())
        }
    }

    private static func csiVPA(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let row = dispatch.getParam(0, default: 1)
        fb.cursorState.moveRow(row - 1)
    }

    private static func csiHPA(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let col = dispatch.getParam(0, default: 1)
        fb.cursorState.moveCol(col - 1)
    }

    private static func csiECH(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        let num = dispatch.getParam(0, default: 1)
        var limit = fb.cursorState.getCursorCol() + num - 1
        if limit >= fb.cursorState.getWidth() { limit = fb.cursorState.getWidth() - 1 }
        clearLine(fb, row: -1, start: fb.cursorState.getCursorCol(), end: limit)
    }

    private static func csiSD(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        fb.scroll(dispatch.getParam(0, default: 1))
    }

    private static func csiSU(_ fb: VTFramebuffer, _ dispatch: VTSequenceDispatcher) {
        fb.scroll(-dispatch.getParam(0, default: 1))
    }
}
