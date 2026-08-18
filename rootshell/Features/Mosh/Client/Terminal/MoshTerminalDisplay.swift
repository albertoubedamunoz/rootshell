//
//  VTDisplayRenderer.swift
//  rootshell
//

import Foundation

final class VTRenderContext {
    var str: String
    var cursorX: Int
    var cursorY: Int
    var currentRendition: VTRenditions
    var cursorVisible: Bool
    let lastFrame: VTFramebuffer

    init(last: VTFramebuffer) {
        self.str = ""
        self.cursorX = 0
        self.cursorY = 0
        self.currentRendition = VTRenditions(backgroundColor: 0)
        self.cursorVisible = last.cursorState.cursorVisible
        self.lastFrame = last
        str.reserveCapacity(last.cursorState.getWidth() * last.cursorState.getHeight() * 4)
    }

    func append(_ c: Character) { str.append(c) }
    func append(_ count: Int, _ c: Character) {
        // Append character directly without intermediate String allocation
        for _ in 0..<count {
            str.append(c)
        }
    }
    func appendScalar(_ scalar: UInt32) {
        if let uni = UnicodeScalar(scalar) {
            str.append(Character(uni))
        }
    }
    func append(_ s: String) { str.append(s) }

    func appendCell(_ cell: VTCell) {
        // Append directly to str to avoid temp allocation
        cell.appendVisualContent(to: &str)
    }

    func moveCursorHidden(y: Int, x: Int) {
        if cursorX == x && cursorY == y { return }
        if cursorVisible {
            append("\u{1b}[?25l")
            cursorVisible = false
        }
        appendMove(y: y, x: x)
    }

    func appendMove(y: Int, x: Int) {
        let lastX = cursorX
        let lastY = cursorY
        cursorX = x
        cursorY = y
        if lastX != -1 && lastY != -1 {
            if x == 0 && y - lastY >= 0 && y - lastY < 5 {
                if lastX != 0 { append("\r") }
                append(y - lastY, "\n")
                return
            }
            if y == lastY && x - lastX < 0 && x - lastX > -5 {
                append(lastX - x, "\u{08}")
                return
            }
        }
        append("\u{1b}[\(y + 1);\(x + 1)H")
    }

    func updateRendition(_ r: VTRenditions, force: Bool = false) {
        if force || currentRendition != r {
            append(r.sgr())
            currentRendition = r
        }
    }
}

final class VTDisplayRenderer {
    private let hasECH: Bool
    private let hasBCE: Bool
    private let hasTitle: Bool
    private let smcup: String?
    private let rmcup: String?

    init(useEnvironment: Bool) {
        // iOS does not expose terminfo; use conservative defaults
        let hasECH = true
        let hasBCE = true
        var hasTitle = true
        // Enter the alternate screen on session open and restore the primary
        // screen on close. This isolates mosh's rendering from anything
        // Ghostty already had on screen (restored scrollback, local-shell
        // content for the shell-launched-mosh case, etc.) so
        // localFramebuffer can't diverge from Ghostty's actual grid. Users
        // can opt out via Roam Settings → Mosh Settings → Use Alternate
        // Screen, which falls back to the legacy primary-screen behavior.
        let altScreenEnabled = MoshConfig.altScreenEnabled
        var smcup: String? = altScreenEnabled ? "\u{1b}[?1049h" : nil
        var rmcup: String? = altScreenEnabled ? "\u{1b}[?1049l" : nil

        if useEnvironment {
            let env = ProcessInfo.processInfo.environment
            if let term = env["TERM"] {
                let titlePrefixes = ["xterm", "rxvt", "kterm", "Eterm", "alacritty", "screen", "tmux"]
                hasTitle = titlePrefixes.contains { term.hasPrefix($0) }
            } else {
                hasTitle = false
            }

            if env["MOSH_NO_TERM_INIT"] != nil {
                smcup = nil
                rmcup = nil
            }
        }

        self.hasECH = hasECH
        self.hasBCE = hasBCE
        self.hasTitle = hasTitle
        self.smcup = smcup
        self.rmcup = rmcup
    }

    func open() -> String {
        return (smcup ?? "") + "\u{1b}[?1h"
    }

    func close() -> String {
        return "\u{1b}[?1l\u{1b}[0m\u{1b}[?25h"
            + "\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1001l\u{1b}[?1000l"
            + "\u{1b}[?1015l\u{1b}[?1006l\u{1b}[?1005l"
            + (rmcup ?? "")
    }

    func renderDelta(initialized: Bool, last: VTFramebuffer, f: VTFramebuffer) -> String {
        var initialized = initialized
        let frame = VTRenderContext(last: last)
        var tmp: String

        if f.getBellCount() != frame.lastFrame.getBellCount() {
            frame.append("\u{07}")
        }

        if hasTitle && f.isTitleInitialized() && (!initialized || f.getIconName() != frame.lastFrame.getIconName() || f.getWindowTitle() != frame.lastFrame.getWindowTitle()) {
            if f.getIconName() == f.getWindowTitle() {
                frame.append("\u{1b}]0;")
                for s in f.getWindowTitle() { frame.appendScalar(s.value) }
                frame.append("\u{07}")
            } else {
                frame.append("\u{1b}]1;")
                for s in f.getIconName() { frame.appendScalar(s.value) }
                frame.append("\u{07}")

                frame.append("\u{1b}]2;")
                for s in f.getWindowTitle() { frame.appendScalar(s.value) }
                frame.append("\u{07}")
            }
        }

        if f.getClipboard() != frame.lastFrame.getClipboard() {
            frame.append("\u{1b}]52;c;")
            for s in f.getClipboard() { frame.appendScalar(s.value) }
            frame.append("\u{07}")
        }

        if !initialized || f.cursorState.reverseVideo != frame.lastFrame.cursorState.reverseVideo {
            tmp = "\u{1b}[?5" + (f.cursorState.reverseVideo ? "h" : "l")
            frame.append(tmp)
        }

        if !initialized || f.cursorState.getWidth() != frame.lastFrame.cursorState.getWidth() || f.cursorState.getHeight() != frame.lastFrame.cursorState.getHeight() {
            frame.append("\u{1b}[r")
            frame.append("\u{1b}[0m\u{1b}[H\u{1b}[2J")
            initialized = false
            frame.cursorX = 0
            frame.cursorY = 0
            frame.currentRendition = VTRenditions(backgroundColor: 0)
        } else {
            frame.cursorX = frame.lastFrame.cursorState.getCursorCol()
            frame.cursorY = frame.lastFrame.cursorState.getCursorRow()
            frame.currentRendition = frame.lastFrame.cursorState.getRenditions()
        }

        if !initialized {
            frame.cursorVisible = false
            frame.append("\u{1b}[?25l")
        }

        var frameY = 0
        var blankRow: VTRow? = nil
        var rows = frame.lastFrame.getRows()

        if frame.lastFrame.cursorState.getWidth() < f.cursorState.getWidth() {
            for idx in rows.indices {
                let row = rows[idx].copy()
                if row.cells.count < f.cursorState.getWidth() {
                    row.cells.append(contentsOf: Array(repeating: VTCell(backgroundColor: f.cursorState.getBackgroundRendition()), count: f.cursorState.getWidth() - row.cells.count))
                }
                rows[idx] = row
            }
        }
        if rows.count < f.cursorState.getHeight() {
            let w = f.cursorState.getWidth()
            let c: UInt32 = 0
            blankRow = VTRow(width: w, backgroundColor: c)
            rows.append(contentsOf: Array(repeating: blankRow!, count: f.cursorState.getHeight() - rows.count))
        }

        if initialized {
            var linesScrolled = 0
            var scrollHeight = 0

            for row in 0..<f.cursorState.getHeight() {
                let newRow = f.getRow(0)
                let oldRow = rows[row]
                if !(newRow === oldRow || newRow == oldRow) {
                    continue
                }
                if row == 0 { break }
                linesScrolled = row
                scrollHeight = 1
                for regionHeight in 1..<(f.cursorState.getHeight() - linesScrolled) {
                    if f.getRow(regionHeight) == rows[linesScrolled + regionHeight] {
                        scrollHeight = regionHeight + 1
                    } else {
                        break
                    }
                }
                break
            }

            if scrollHeight > 0 {
                frameY = scrollHeight
                if linesScrolled > 0 {
                    if blankRow == nil {
                        blankRow = VTRow(width: f.cursorState.getWidth(), backgroundColor: 0)
                    }
                    frame.updateRendition(VTRenditions(backgroundColor: 0), force: true)

                    let topMargin = 0
                    let bottomMargin = topMargin + linesScrolled + scrollHeight - 1

                    if scrollHeight + linesScrolled == f.cursorState.getHeight() && frame.cursorY + 1 == f.cursorState.getHeight() {
                        frame.append("\r")
                        frame.append(linesScrolled, "\n")
                        frame.cursorX = 0
                    } else {
                        frame.append("\u{1b}[\(topMargin + 1);\(bottomMargin + 1)r")
                        frame.cursorX = -1
                        frame.cursorY = -1
                        frame.moveCursorHidden(y: bottomMargin, x: 0)
                        frame.append(linesScrolled, "\n")
                        frame.append("\u{1b}[r")
                        frame.cursorX = -1
                        frame.cursorY = -1
                    }

                    for i in topMargin...bottomMargin {
                        if i + linesScrolled <= bottomMargin {
                            rows[i] = rows[i + linesScrolled]
                        } else {
                            rows[i] = blankRow!
                        }
                    }
                }
            }
        }

        var wrap = false
        while frameY < f.cursorState.getHeight() {
            wrap = renderRow(initialized: initialized, frame: frame, f: f, frameY: frameY, oldRow: rows[frameY], wrap: wrap)
            frameY += 1
        }

        if !initialized || f.cursorState.getCursorRow() != frame.cursorY || f.cursorState.getCursorCol() != frame.cursorX {
            frame.appendMove(y: f.cursorState.getCursorRow(), x: f.cursorState.getCursorCol())
        }

        if !initialized || f.cursorState.cursorVisible != frame.cursorVisible {
            frame.append(f.cursorState.cursorVisible ? "\u{1b}[?25h" : "\u{1b}[?25l")
        }

        frame.updateRendition(f.cursorState.getRenditions(), force: !initialized)

        if !initialized || f.cursorState.bracketedPaste != frame.lastFrame.cursorState.bracketedPaste {
            frame.append(f.cursorState.bracketedPaste ? "\u{1b}[?2004h" : "\u{1b}[?2004l")
        }

        if !initialized || f.cursorState.mouseReportingMode != frame.lastFrame.cursorState.mouseReportingMode {
            if f.cursorState.mouseReportingMode == .none {
                frame.append("\u{1b}[?1003l")
                frame.append("\u{1b}[?1002l")
                frame.append("\u{1b}[?1001l")
                frame.append("\u{1b}[?1000l")
            } else {
                if frame.lastFrame.cursorState.mouseReportingMode != .none {
                    frame.append("\u{1b}[?\(frame.lastFrame.cursorState.mouseReportingMode.rawValue)l")
                }
                frame.append("\u{1b}[?\(f.cursorState.mouseReportingMode.rawValue)h")
            }
        }

        if !initialized || f.cursorState.mouseFocusEvent != frame.lastFrame.cursorState.mouseFocusEvent {
            frame.append(f.cursorState.mouseFocusEvent ? "\u{1b}[?1004h" : "\u{1b}[?1004l")
        }

        if !initialized || f.cursorState.mouseEncodingMode != frame.lastFrame.cursorState.mouseEncodingMode {
            if f.cursorState.mouseEncodingMode == .default {
                frame.append("\u{1b}[?1015l")
                frame.append("\u{1b}[?1006l")
                frame.append("\u{1b}[?1005l")
            } else {
                if frame.lastFrame.cursorState.mouseEncodingMode != .default {
                    frame.append("\u{1b}[?\(frame.lastFrame.cursorState.mouseEncodingMode.rawValue)l")
                }
                frame.append("\u{1b}[?\(f.cursorState.mouseEncodingMode.rawValue)h")
            }
        }

        return frame.str
    }

    private func renderRow(initialized: Bool, frame: VTRenderContext, f: VTFramebuffer, frameY: Int, oldRow: VTRow, wrap: Bool) -> Bool {
        var frameX = 0
        let row = f.getRow(frameY)
        let cells = row.cells
        let oldCells = oldRow.cells

        if wrap {
            let cell = cells[0]
            frame.updateRendition(cell.getRenditions())
            frame.appendCell(cell)
            frameX += cell.getWidth()
            frame.cursorX += cell.getWidth()
        }

        if initialized && row === oldRow {
            return false
        }

        let wrapThis = row.getWrap()
        let rowWidth = f.cursorState.getWidth()
        var clearCount = 0
        var wroteLastCell = false
        var blankRenditions = VTRenditions(backgroundColor: 0)

        while frameX < rowWidth {
            let cell = cells[frameX]

            if initialized && clearCount == 0 && cell == oldCells[frameX] {
                frameX += cell.getWidth()
                continue
            }

            if cell.isEmpty {
                if clearCount == 0 {
                    blankRenditions = cell.getRenditions()
                }
                if cell.getRenditions() == blankRenditions {
                    clearCount += 1
                    frameX += 1
                    continue
                }
            }

            if clearCount > 0 {
                frame.moveCursorHidden(y: frameY, x: frameX - clearCount)
                frame.updateRendition(blankRenditions)
                let canUseErase = hasBCE || frame.currentRendition == VTRenditions(backgroundColor: 0)
                if canUseErase && hasECH && clearCount > 4 {
                    frame.append("\u{1b}[\(clearCount)X")
                } else {
                    frame.append(clearCount, " ")
                    frame.cursorX = frameX
                }
                clearCount = 0
                if cell.isEmpty {
                    blankRenditions = cell.getRenditions()
                    clearCount = 1
                    frameX += 1
                    continue
                }
            }

            let cellWidth = cell.getWidth()
            if wrapThis && frameX + cellWidth >= rowWidth {
                frame.cursorX = -1
                frame.cursorY = -1
            }
            frame.moveCursorHidden(y: frameY, x: frameX)
            frame.updateRendition(cell.getRenditions())
            frame.appendCell(cell)
            frameX += cellWidth
            frame.cursorX += cellWidth
            if frameX >= rowWidth {
                wroteLastCell = true
            }
        }

        if clearCount > 0 {
            frame.moveCursorHidden(y: frameY, x: frameX - clearCount)
            frame.updateRendition(blankRenditions)
            let canUseErase = hasBCE || frame.currentRendition == VTRenditions(backgroundColor: 0)
            if canUseErase && !wrapThis {
                frame.append("\u{1b}[K")
            } else {
                frame.append(clearCount, " ")
                frame.cursorX = frameX
                wroteLastCell = true
            }
        }

        if !(wroteLastCell && frameY < f.cursorState.getHeight() - 1) {
            return false
        }
        if wrapThis {
            frame.cursorX = 0
            frame.cursorY += 1
            return true
        }
        frame.append("\r\n")
        frame.cursorX = 0
        frame.cursorY += 1
        return false
    }
}
