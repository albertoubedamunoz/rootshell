#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// ANSI renderer that converts an RFCellBuffer into escape sequence output.
/// Also serves as the compositor: draws all UI elements into the cell buffer.
@MainActor
final class RFDisplay {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "rf-display")

    let buffer: RFCellBuffer
    let layout: RFLayout
    private(set) var theme: RFTheme
    let output: @Sendable (Data) -> Void

    init(cols: Int, rows: Int, theme: RFTheme, output: @escaping @Sendable (Data) -> Void) {
        self.buffer = RFCellBuffer(cols: cols, rows: rows)
        self.layout = RFLayout(cols: cols, rows: rows)
        self.theme = theme
        self.output = output
    }

    func resize(cols: Int, rows: Int) {
        buffer.resize(cols: cols, rows: rows)
        layout.resize(cols: cols, rows: rows)
    }

    func updateTheme(_ theme: RFTheme) {
        self.theme = theme
        buffer.invalidate()
    }

    // MARK: - Rendering

    /// Render the buffer and emit the ANSI output.
    func render() {
        let ansi: String
        if buffer.needsFullRedraw {
            ansi = renderFull()
        } else {
            ansi = renderDiff()
        }
        buffer.commitFrame()
        if !ansi.isEmpty {
            output(Data(ansi.utf8))
        }
    }

    /// Full screen render — all rows.
    private func renderFull() -> String {
        var out = String()
        out.reserveCapacity(buffer.cols * buffer.rows * 12)

        // Begin synchronized output
        out += "\u{1b}[?2026h"
        out += "\u{1b}[?25l" // hide cursor

        var currentStyle = TUIStyle.plain

        for row in 0..<buffer.rows {
            // Move cursor to start of row (1-indexed)
            out += "\u{1b}[\(row + 1);1H"

            for col in 0..<buffer.cols {
                let cell = buffer.cell(row: row, col: col)
                // Trailing half of a wide glyph: emit nothing, the preceding
                // wide glyph already advanced the terminal cursor by 2.
                if cell.isContinuation { continue }
                appendStyleTransition(from: currentStyle, to: cell.style, into: &out)
                currentStyle = cell.style
                out.append(cell.character)
            }
        }

        out += "\u{1b}[0m" // reset
        out += "\u{1b}[?2026l" // end synchronized output
        return out
    }

    /// Differential render — only dirty rows.
    private func renderDiff() -> String {
        let dirty = buffer.modifiedRows
        guard !dirty.isEmpty else { return "" }

        var out = String()
        out.reserveCapacity(dirty.count * buffer.cols * 12)

        out += "\u{1b}[?2026h"
        out += "\u{1b}[?25l"

        var currentStyle = TUIStyle.plain

        for row in dirty.sorted() {
            // Move to row start, clear line
            out += "\u{1b}[\(row + 1);1H\u{1b}[2K"

            for col in 0..<buffer.cols {
                let cell = buffer.cell(row: row, col: col)
                if cell.isContinuation { continue }
                appendStyleTransition(from: currentStyle, to: cell.style, into: &out)
                currentStyle = cell.style
                out.append(cell.character)
            }
        }

        out += "\u{1b}[0m"
        out += "\u{1b}[?2026l"
        return out
    }

    /// Append the ANSI escape sequence to transition from one style to another.
    private func appendStyleTransition(from prev: TUIStyle, to next: TUIStyle, into out: inout String) {
        guard prev != next else { return }

        // Reset and reapply is simpler and more reliable than tracking individual changes
        out += "\u{1b}[0"

        if next.attrs.contains(.bold) { out += ";1" }
        if next.attrs.contains(.dim) { out += ";2" }
        if next.attrs.contains(.italic) { out += ";3" }
        if next.attrs.contains(.underline) { out += ";4" }
        if next.attrs.contains(.reverse) { out += ";7" }
        if next.attrs.contains(.strikethrough) { out += ";9" }

        if let fg = next.fg {
            out += ";38;2;\(fg.0);\(fg.1);\(fg.2)"
        }
        if let bg = next.bg {
            out += ";48;2;\(bg.0);\(bg.1);\(bg.2)"
        }

        out += "m"
    }

    // MARK: - Terminal Setup/Teardown

    /// Enter rf: alternate screen, mouse capture, hide cursor.
    func enterScreen() {
        var seq = ""
        seq += "\u{1b}[?1049h" // alternate screen
        seq += "\u{1b}[?1000h" // button events
        seq += "\u{1b}[?1002h" // button+motion (drag)
        seq += "\u{1b}[?1006h" // SGR mouse encoding
        seq += "\u{1b}[?25l"   // hide cursor
        output(Data(seq.utf8))
    }

    /// Exit rf: restore screen, mouse, cursor.
    func exitScreen() {
        var seq = ""
        seq += "\u{1b}[?1006l" // disable SGR mouse
        seq += "\u{1b}[?1002l" // disable motion tracking
        seq += "\u{1b}[?1000l" // disable button events
        seq += "\u{1b}[?25h"   // show cursor
        seq += "\u{1b}[?1049l" // exit alternate screen
        output(Data(seq.utf8))
    }

    // MARK: - Compositor: Draw UI Elements

    /// Draw the tab bar. Returns without drawing if only 1 tab.
    func drawTabBar(tabs: [(id: Int, name: String)], activeIndex: Int) {
        let region = layout.tabBarRegion
        guard region.height > 0 else { return }

        // Fill background
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.tabInactiveBg))
        buffer.fillRow(region.row, cell: bgCell)

        var col = 0
        for (i, tab) in tabs.enumerated() {
            let isActive = i == activeIndex
            let style: TUIStyle
            if isActive {
                style = TUIStyle(fg: theme.tabActiveFg, bg: theme.tabActiveBg, attrs: .bold)
            } else {
                style = TUIStyle(fg: theme.tabInactiveFg, bg: theme.tabInactiveBg)
            }

            let label = " \(i + 1):\(tab.name) "
            col = buffer.write(row: region.row, col: col, label, style: style)
            if col >= layout.cols { break }
        }
    }

    /// Draw the header/breadcrumb bar.
    func drawHeader(path: String, filterText: String?) {
        let region = layout.headerRegion

        // Fill background
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.headerBg))
        buffer.fillRow(region.row, cell: bgCell)

        let dimStyle = TUIStyle(fg: theme.dimmed, bg: theme.headerBg)
        let boldStyle = TUIStyle(fg: theme.headerFg, bg: theme.headerBg, attrs: .bold)

        // Split path into components
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var col = 1 // 1 cell padding

        if components.isEmpty || path == "/" {
            col = buffer.write(row: region.row, col: col, "/", style: boldStyle)
        } else {
            // Show path with bold last component
            let prefix: String
            let lastComponent: String
            if components.count <= 1 {
                prefix = ""
                lastComponent = path
            } else {
                let parentPath = components.dropLast().joined(separator: "/")
                prefix = (parentPath.isEmpty ? "/" : parentPath + "/")
                lastComponent = String(components.last ?? "")
            }

            // Truncate prefix from left if too long
            let maxPrefixWidth = layout.cols - RFWidth.width(of: lastComponent) - 4
            if RFWidth.width(of: prefix) > maxPrefixWidth, maxPrefixWidth > 3 {
                // Accumulate from the right by display width, leaving 1 cell for "…".
                var used = 0
                var suffix: [Character] = []
                for ch in prefix.reversed() {
                    let w = RFWidth.width(of: ch)
                    if used + w > maxPrefixWidth - 1 { break }
                    suffix.append(ch)
                    used += w
                }
                let truncated = "…" + String(suffix.reversed())
                col = buffer.write(row: region.row, col: col, truncated, style: dimStyle)
            } else {
                col = buffer.write(row: region.row, col: col, prefix, style: dimStyle)
            }
            col = buffer.write(row: region.row, col: col, lastComponent, style: boldStyle)
        }

        // Show filter indicator if active
        if let filterText, !filterText.isEmpty {
            let filterStyle = TUIStyle(fg: theme.inputPromptColor, bg: theme.headerBg)
            let indicator = "  [filter: \(filterText)]"
            buffer.write(row: region.row, col: col + 1, indicator, style: filterStyle)
        }
    }

    /// Draw a file list in a column region with powerline pill highlight on cursor row.
    func drawFileList(
        entries: [RFDisplayEntry],
        cursorIndex: Int,
        scrollOffset: Int,
        region: TUIRegion,
        isActive: Bool,
        highlightName: String? = nil,
        selectedPaths: Set<String> = [],
        yankInfo: (paths: Set<String>, isCut: Bool)? = nil
    ) {
        // Clear region
        buffer.fill(row: region.row, col: region.col, width: region.width, height: region.height)

        let visibleCount = region.height
        // Clamp the scroll offset against the real viewport height. The caller's
        // scrollOffset can be stale (e.g. the list shrank from a live filter or
        // reload before adjustScroll re-ran), which would otherwise make
        // startIndex..<endIndex an inverted range and trap.
        let maxOffset = max(0, entries.count - visibleCount)
        let startIndex = min(max(0, scrollOffset), maxOffset)
        let endIndex = min(startIndex + visibleCount, entries.count)

        for i in startIndex..<endIndex {
            let displayRow = region.row + (i - startIndex)
            let entry = entries[i]
            let isCursor = (i == cursorIndex)
            let isHighlighted = (entry.name == highlightName)
            let isSelected = selectedPaths.contains(entry.path)
            let isYanked = yankInfo?.paths.contains(entry.path) ?? false
            let isYankCut = isYanked && (yankInfo?.isCut ?? false)

            // Determine if this row gets the pill highlight
            let bg: (UInt8, UInt8, UInt8)?
            let isPill: Bool
            if isCursor && isActive {
                bg = theme.selectionBg
                isPill = true
            } else if isHighlighted && !isActive {
                bg = theme.selectionBg
                isPill = true
            } else {
                bg = nil
                isPill = false
            }

            // Pill rows: fill full width with selectionBg, draw rounded caps
            if isPill, let pillBg = bg {
                let fillCell = TUICell(character: " ", style: TUIStyle(bg: pillBg))
                for c in (region.col + 1)..<(region.col + region.width - 1) {
                    buffer.setCell(row: displayRow, col: c, fillCell)
                }
                // Left rounded cap (half-circle, filled on right)
                buffer.setCell(row: displayRow, col: region.col,
                    TUICell(character: "\u{e0b6}", style: TUIStyle(fg: pillBg)))
                // Right rounded cap (half-circle, filled on left)
                buffer.setCell(row: displayRow, col: region.col + region.width - 1,
                    TUICell(character: "\u{e0b4}", style: TUIStyle(fg: pillBg)))
            }

            // Determine foreground and extra attributes for yank state
            let baseFg: (UInt8, UInt8, UInt8)
            var extraAttrs: TUIAttributes = []
            if !isActive {
                baseFg = theme.dimmed
            } else if isYanked {
                baseFg = theme.yankIndicator
                if isYankCut {
                    extraAttrs = [.dim, .strikethrough]
                }
            } else {
                baseFg = entry.color
            }
            let textFg = bg.map { theme.readableTextColor(baseFg, on: $0) } ?? baseFg
            let iconFg = bg.map { theme.readableDecorativeColor(entry.iconColor, on: $0) } ?? entry.iconColor
            let markerFg = bg.map { theme.readableDecorativeColor(theme.selectedMarker, on: $0) } ?? theme.selectedMarker

            // Content starts after left margin (1 char for cap/padding)
            var col = region.col + 1

            // Selection marker
            if isSelected {
                let markerStyle = TUIStyle(fg: markerFg, bg: bg)
                col = buffer.write(row: displayRow, col: col, "* ", style: markerStyle)
            } else {
                col += 2 // padding to align with selected entries
            }

            // Icon (uses per-icon color from Nerd Font registry)
            let iconStyle = TUIStyle(fg: iconFg, bg: bg)
            col = buffer.write(row: displayRow, col: col, entry.icon + " ", style: iconStyle)

            // Name
            var nameAttrs: TUIAttributes = entry.isDirectory ? .bold : []
            nameAttrs.formUnion(extraAttrs)
            let nameStyle = TUIStyle(fg: textFg, bg: bg, attrs: nameAttrs)
            let nameWidth = region.width - (col - region.col) - RFWidth.width(of: entry.rightText) - 2
            if nameWidth > 0 {
                col = buffer.writeTruncated(
                    row: displayRow, col: col, entry.name,
                    style: nameStyle, maxWidth: nameWidth
                )
            }

            // Git indicator + right-aligned info
            if !entry.rightText.isEmpty {
                let rightCol = region.col + region.width - RFWidth.width(of: entry.rightText) - 1
                if rightCol > col {
                    let rawRightColor = entry.rightColor ?? theme.dimmed
                    let rightColor = bg.map { theme.readableDecorativeColor(rawRightColor, on: $0) } ?? rawRightColor
                    let rightStyle = TUIStyle(fg: rightColor, bg: bg)
                    buffer.write(row: displayRow, col: rightCol, entry.rightText, style: rightStyle)
                }
            }
        }

        // Scroll indicators (inset by 1 to avoid right cap overlap)
        if startIndex > 0 {
            let style = TUIStyle(fg: theme.dimmed)
            buffer.write(row: region.row, col: region.col + region.width - 2, "▲", style: style)
        }
        if endIndex < entries.count {
            let bottomRow = region.row + region.height - 1
            let style = TUIStyle(fg: theme.dimmed)
            buffer.write(row: bottomRow, col: region.col + region.width - 2, "▼", style: style)
        }
    }

    /// Draw vertical separators.
    func drawSeparators(hoverCol: Int = -1, isDragging: Bool = false) {
        let bodyTop = layout.parentRegion.row
        let bodyHeight = layout.parentRegion.height

        let sep1Active = (hoverCol == layout.separator1Col) || isDragging
        let sep2Active = (hoverCol == layout.separator2Col) || isDragging

        let sep1Color = sep1Active ? theme.separatorHoverColor : theme.separatorColor
        let sep2Color = sep2Active ? theme.separatorHoverColor : theme.separatorColor

        for row in bodyTop..<(bodyTop + bodyHeight) {
            buffer.setCell(row: row, col: layout.separator1Col,
                          TUICell(character: "│", style: TUIStyle(fg: sep1Color)))
            buffer.setCell(row: row, col: layout.separator2Col,
                          TUICell(character: "│", style: TUIStyle(fg: sep2Color)))
        }
    }

    /// Draw the status bar.
    func drawStatusBar(left: String, right: String) {
        let region = layout.statusBarRegion
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.statusBg))
        buffer.fillRow(region.row, cell: bgCell)

        let leftStyle = TUIStyle(fg: theme.statusFg, bg: theme.statusBg)
        buffer.write(row: region.row, col: 1, left, style: leftStyle)

        if !right.isEmpty {
            let rightCol = max(0, layout.cols - RFWidth.width(of: right) - 1)
            buffer.write(row: region.row, col: rightCol, right, style: leftStyle)
        }
    }

    /// Draw a powerline-style status bar with colored segments.
    func drawPowerlineStatusBar(left: [RFStatusSegment], right: [RFStatusSegment]) {
        let region = layout.statusBarRegion
        // Clear with default bg
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.bg))
        buffer.fillRow(region.row, cell: bgCell)

        var col = 0

        // Left segments
        for (i, seg) in left.enumerated() {
            let style = TUIStyle(fg: seg.fg, bg: seg.bg, attrs: seg.bold ? .bold : [])
            col = buffer.write(row: region.row, col: col, seg.text, style: style)

            // Powerline separator after each segment
            let nextBg: (UInt8, UInt8, UInt8)?
            if i + 1 < left.count {
                nextBg = left[i + 1].bg
            } else {
                nextBg = theme.bg
            }
            let sepStyle = TUIStyle(fg: seg.bg, bg: nextBg)
            col = buffer.write(row: region.row, col: col, "\u{e0b0}", style: sepStyle)
        }

        // Right segments (rendered right-to-left)
        if !right.isEmpty {
            // Calculate total width of right segments
            var totalWidth = 0
            for seg in right {
                totalWidth += RFWidth.width(of: seg.text) + 1 // +1 for separator
            }

            var rCol = max(col + 1, layout.cols - totalWidth)

            for (i, seg) in right.enumerated() {
                // Separator before segment
                let prevBg: (UInt8, UInt8, UInt8)?
                if i == 0 {
                    prevBg = theme.bg
                } else {
                    prevBg = right[i - 1].bg
                }
                let sepStyle = TUIStyle(fg: seg.bg, bg: prevBg)
                rCol = buffer.write(row: region.row, col: rCol, "\u{e0b2}", style: sepStyle)

                let style = TUIStyle(fg: seg.fg, bg: seg.bg, attrs: seg.bold ? .bold : [])
                rCol = buffer.write(row: region.row, col: rCol, seg.text, style: style)
            }
        }
    }

    /// Draw an input line in the status bar (for filter, search, rename, etc.).
    /// Text longer than the row scrolls by whole graphemes to keep the cursor
    /// visible. All offsets are display cells, so wide glyphs count double.
    func drawInputLine(prompt: String, text: String, cursorPos: Int) {
        let region = layout.statusBarRegion
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.statusBg))
        buffer.fillRow(region.row, cell: bgCell)

        let promptStyle = TUIStyle(fg: theme.inputPromptColor, bg: theme.statusBg, attrs: .bold)
        let textStart = buffer.write(row: region.row, col: 1, prompt + ": ", style: promptStyle)

        let textStyle = TUIStyle(fg: theme.fg, bg: theme.statusBg)
        let cursorStyle = TUIStyle(fg: theme.bg, bg: theme.inputCursorColor)
        let chars = Array(text)
        let cursor = min(max(cursorPos, 0), chars.count)

        // offsets[i] is the cell the i-th character starts at; the last entry
        // is the end of the text.
        var offsets: [Int] = [0]
        offsets.reserveCapacity(chars.count + 1)
        var used = 0
        for char in chars {
            used += RFWidth.width(of: char)
            offsets.append(used)
        }

        // The cursor needs a cell of its own, including when it sits at the end.
        let available = max(1, buffer.cols - textStart)
        let cursorEnd = cursor < chars.count ? offsets[cursor + 1] : offsets[cursor] + 1

        var first = 0
        while first < cursor, cursorEnd - offsets[first] > available {
            first += 1
        }

        var col = textStart
        for i in first..<chars.count {
            guard col < buffer.cols else { break }
            let style = (i == cursor) ? cursorStyle : textStyle
            col = buffer.write(row: region.row, col: col, String(chars[i]), style: style)
        }

        if cursor >= chars.count, col < buffer.cols {
            buffer.write(row: region.row, col: col, " ", style: cursorStyle)
        }
    }

    /// Draw a status message in the status bar (no input cursor, no ": " suffix).
    /// Optionally prefixes a spinner character for waiting states.
    func drawStatusMessage(_ message: String, spinnerChar: Character? = nil) {
        let region = layout.statusBarRegion
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.statusBg))
        buffer.fillRow(region.row, cell: bgCell)

        let promptStyle = TUIStyle(fg: theme.inputPromptColor, bg: theme.statusBg, attrs: .bold)
        var col = 1

        if let spinner = spinnerChar {
            let spinnerStyle = TUIStyle(fg: theme.inputCursorColor, bg: theme.statusBg, attrs: .bold)
            col = buffer.write(row: region.row, col: col, String(spinner), style: spinnerStyle)
            col = buffer.write(row: region.row, col: col, " ", style: promptStyle)
        }

        buffer.write(row: region.row, col: col, message, style: promptStyle)
    }

    /// Draw a chord/confirmation prompt (block cursor at end, no ": " suffix).
    func drawChordPrompt(_ prompt: String) {
        let region = layout.statusBarRegion
        let bgCell = TUICell(character: " ", style: TUIStyle(bg: theme.statusBg))
        buffer.fillRow(region.row, cell: bgCell)

        let promptStyle = TUIStyle(fg: theme.inputPromptColor, bg: theme.statusBg, attrs: .bold)
        let col = buffer.write(row: region.row, col: 1, prompt + " ", style: promptStyle)

        let cursorStyle = TUIStyle(fg: theme.bg, bg: theme.inputCursorColor)
        buffer.write(row: region.row, col: col, " ", style: cursorStyle)
    }

    /// Draw a preview region with pre-parsed ANSI cells.
    func drawPreviewCells(cells: [[TUICell]], region: TUIRegion) {
        // Clear preview region first
        buffer.fill(row: region.row, col: region.col, width: region.width, height: region.height)

        for (lineIdx, line) in cells.enumerated() {
            guard lineIdx < region.height else { break }
            let row = region.row + lineIdx
            for (colIdx, cell) in line.enumerated() {
                guard colIdx < region.width else { break }
                // Cached cells may have been parsed for a wider region. A wide
                // glyph at the final column would lose its continuation cell and
                // spill past the region edge — leave it blank (region was filled).
                if !cell.isContinuation, colIdx + 1 >= region.width, RFWidth.width(of: cell.character) == 2 {
                    break
                }
                buffer.setCell(row: row, col: region.col + colIdx, cell)
            }
        }
    }

    /// Draw a centered message in a region (for empty/binary/loading states).
    func drawCenteredMessage(_ message: String, region: TUIRegion) {
        buffer.fill(row: region.row, col: region.col, width: region.width, height: region.height)
        let msgRow = region.row + region.height / 2
        let msgCol = region.col + max(0, (region.width - RFWidth.width(of: message)) / 2)
        let style = TUIStyle(fg: theme.dimmed)
        buffer.write(row: msgRow, col: msgCol, message, style: style)
    }
}

/// Display-ready file entry with pre-computed display properties.
struct RFDisplayEntry: Sendable {
    let name: String
    let path: String
    let icon: String
    let iconColor: (UInt8, UInt8, UInt8)  // Per-icon RGB color
    let color: (UInt8, UInt8, UInt8)      // Name color (theme-dependent)
    let isDirectory: Bool
    let rightText: String       // Size, git indicator, etc.
    let rightColor: (UInt8, UInt8, UInt8)?
}

/// A single powerline status bar segment.
struct RFStatusSegment: Sendable {
    let text: String
    let fg: (UInt8, UInt8, UInt8)
    let bg: (UInt8, UInt8, UInt8)
    let bold: Bool
}

#endif
