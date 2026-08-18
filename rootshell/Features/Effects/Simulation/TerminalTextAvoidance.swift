//
//  TerminalTextAvoidance.swift
//  rootshell
//
//  Shared "text avoidance" support for background effects (Butterflies,
//  Jellyfish): a lightweight tracker that knows where terminal text sits on
//  screen, plus the pure force math the creature simulations use to steer
//  away from it.
//
//  Two channels with very different freshness:
//  - Cursor bubble: refreshed every effect frame from ghostty_surface_ime_point
//    (cheap struct read). This is the STRONG channel — it covers the landing
//    zone of new output even between text scans.
//  - Text bands: rectangles over occupied rows, rebuilt by a debounced
//    ghostty_surface_read_text scan (acquires the terminal mutex, so never
//    per-frame). Between scans the bands are re-anchored from the live
//    scrollbar offset each frame, so they stay glued to their text while the
//    user scrolls.
//

import UIKit
import Combine
import os.log

// MARK: - Focus Registry

/// Where the tracker finds the focused terminal. The focused window installs
/// a resolver closure (rather than pushing every focus change) because
/// TabsModel is per-window and focus mutates at many sites — the closure
/// re-resolves live on every tick, so tab switches, split-focus moves, and
/// tmux focus drives all need zero extra plumbing.
@MainActor
enum TextAvoidanceFocus {
    private static var ownerWindowId: String?
    private static var currentResolver: (() -> Ghostty.TerminalView?)?

    static var resolver: (() -> Ghostty.TerminalView?)? { currentResolver }

    static func install(windowId: String, resolver: @escaping () -> Ghostty.TerminalView?) {
        ownerWindowId = windowId
        currentResolver = resolver
    }

    static func uninstall(windowId: String) {
        guard ownerWindowId == windowId else { return }
        ownerWindowId = nil
        currentResolver = nil
    }
}

// MARK: - Field Snapshot

/// What the effects consume each frame. All geometry is in the effect
/// canvas's coordinate space (points, origin top-left).
struct TextAvoidanceField {
    /// Occupied-text band rects (≤ maxBands, already padded for readability)
    var bands: [CGRect] = []
    /// Cursor-cell center and core bubble radius
    var cursorCenter: CGPoint = .zero
    var cursorRadius: CGFloat = 0
    /// Cursor bubble trustworthy (refreshed every tick)
    var hasCursor = false
    /// Occupied cells ÷ viewport cells, from the last successful scan
    var coverage: Double = 0
    /// Bands + coverage trustworthy (a scan succeeded for this terminal at
    /// the current grid). False ⇒ no band forces and the spawn gate stays
    /// OPEN — visits are never suppressed without data.
    var isValid = false

    var isActive: Bool { isValid || hasCursor }
}

// MARK: - Tracker

/// Owns the terminal-side state for one effect view. Created only by live
/// (non-preview) visit states; completely passive between visits — `tick`
/// is called from the effect's per-frame update, which only runs while
/// creatures are on screen, and there are no timers.
@MainActor
final class TextRegionTracker {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TextAvoidance")

    private(set) var field = TextAvoidanceField()

    /// Effect canvas frame in global (window) coordinates, fed by the effect
    /// view's GeometryReader. Band/cursor rects are converted terminal-local
    /// → window → canvas, so splits, sidebars, and the overlay extending
    /// behind the keyboard are all handled without shared-origin assumptions.
    var canvasFrameInGlobal: CGRect = .zero

    private weak var terminal: Ghostty.TerminalView?

    // Debounce state
    private var lastScanTime: TimeInterval = -.infinity
    private var lastChangeTime: TimeInterval = -.infinity
    private var dirty = false
    private var settleDeadline: TimeInterval = 0

    // Change-detection caches
    private var lastScrollTotal: UInt64 = 0
    private var lastScrollOffset: UInt64 = 0
    private var lastCursorCol = Int.min
    private var lastCursorRow = Int.min
    private var lastCols = 0
    private var lastRows = 0
    private var lastAltScreen = false

    /// Scan result anchored in viewport-row space at scan time; canvas rects
    /// are re-derived (not incrementally shifted) so scrolling can't
    /// accumulate float drift.
    private struct RowBand {
        var rowStart: Int
        var rowEnd: Int
        var colStart: Int
        var colEnd: Int
    }
    private var bandRows: [RowBand] = []
    private var scanScrollOffset: UInt64 = 0

    enum Debounce {
        /// Trailing quiet period after the last detected change — one scan
        /// per output burst, not one per chunk
        static let settleDelay: TimeInterval = 0.4
        /// Floor between scans: at most ~1 terminal-mutex acquisition per second
        static let minScanInterval: TimeInterval = 1.0
        /// Continuous churn (builds, TUIs) never settles, so force a rescan
        /// at this staleness. Safe because bands are re-anchored from the
        /// scroll offset every frame and the cursor bubble is always live.
        static let maxStaleness: TimeInterval = 2.5
        /// A scan this fresh is reused by scanForSpawn instead of re-reading
        static let spawnReuseWindow: TimeInterval = 0.25
        /// Beat after a pane/tab focus switch before the first scan
        static let focusSettleDelay: TimeInterval = 0.2
    }

    enum CoverageGate {
        /// Above this occupied-cell fraction, visits pause (nowhere text-free to fly)
        static let suppress = 0.85
        /// Once paused, resume only below this (hysteresis against flapping)
        static let resume = 0.80
    }

    private enum Scan {
        static let maxBands = 16
        static let chunkRows = 4       // initial sub-band height (own col bounds each)
        static let padPoints = 6.0     // readability margin around each band
    }

    // MARK: Per-frame cheap path

    /// Called once per effect frame while creatures are on screen. Reads only
    /// cheap synchronous surface state (size, ime point, scrollbar); decides
    /// when the heavy text scan is due.
    func tick(now: TimeInterval) {
        guard let resolved = TextAvoidanceFocus.resolver?() else {
            terminal = nil
            bandRows = []
            field = TextAvoidanceField()
            return
        }
        if resolved !== terminal {
            // Focus moved to a different pane/tab: drop the old field
            // immediately and let the switch settle before scanning.
            terminal = resolved
            bandRows = []
            field = TextAvoidanceField()
            dirty = true
            lastChangeTime = now
            settleDeadline = now + Debounce.focusSettleDelay
        }
        guard let terminal, terminal.window != nil, let surface = terminal.surface else {
            field = TextAvoidanceField()
            return
        }

        let sizeInfo = ghostty_surface_size(surface)
        let cols = Int(sizeInfo.columns)
        let rows = Int(sizeInfo.rows)
        let scale = Double(terminal.contentScaleFactor)
        guard cols > 0, rows > 0, scale > 0 else {
            field.isValid = false
            field.hasCursor = false
            return
        }
        let cellW = Double(sizeInfo.cell_width_px) / scale
        let cellH = Double(sizeInfo.cell_height_px) / scale
        guard cellW > 0, cellH > 0 else {
            field.isValid = false
            field.hasCursor = false
            return
        }
        if cols != lastCols || rows != lastRows {
            // Grid resize (rotation, font change): band geometry is stale
            lastCols = cols
            lastRows = rows
            bandRows = []
            field.bands = []
            field.coverage = 0
            field.isValid = false
            dirty = true
            lastChangeTime = now
        }

        // Cursor bubble: live every tick (the strong channel). ime_point
        // returns the caret cell's midpoint-x and bottom-y in points.
        var imeX = 0.0, imeY = 0.0, imeW = 0.0, imeH = 0.0
        ghostty_surface_ime_point(surface, &imeX, &imeY, &imeW, &imeH)
        let effCellH = imeH > 0 ? imeH : cellH
        field.cursorCenter = convertToCanvas(
            CGPoint(x: imeX, y: imeY - effCellH / 2), from: terminal)
        field.cursorRadius = max(2.2 * effCellH, 44)
        field.hasCursor = canvasFrameInGlobal.width > 0

        let cursorCol = Int((imeX / max(cellW, 1)).rounded(.down))
        let cursorRow = Int(((imeY - 1) / max(effCellH, 1)).rounded(.down))
        if cursorCol != lastCursorCol || cursorRow != lastCursorRow {
            lastCursorCol = cursorCol
            lastCursorRow = cursorRow
            dirty = true
            lastChangeTime = now
        }

        // Scrollbar: total changes on new output, offset on scroll
        var scrollbar = ghostty_action_scrollbar_s()
        if ghostty_surface_display_scrollbar(surface, &scrollbar) {
            if scrollbar.total != lastScrollTotal {
                lastScrollTotal = scrollbar.total
                dirty = true
                lastChangeTime = now
            }
            if scrollbar.offset != lastScrollOffset {
                lastScrollOffset = scrollbar.offset
                dirty = true
                lastChangeTime = now
            }
        }

        let altScreen = ghostty_surface_is_alternate_active(surface)
        if altScreen != lastAltScreen {
            lastAltScreen = altScreen
            dirty = true
            lastChangeTime = now
        }

        // Re-anchor band rects from row space every frame so they track
        // scrolling (including sub-cell smooth scroll via viewportPadY).
        rebuildCanvasRects(cellW: cellW, cellH: cellH)

        let scanDue = dirty
            && now >= settleDeadline
            && now - lastScanTime >= Debounce.minScanInterval
            && (now - lastChangeTime >= Debounce.settleDelay
                || now - lastScanTime >= Debounce.maxStaleness)
        if scanDue {
            performScan(now: now, cols: cols, rows: rows, cellW: cellW, cellH: cellH)
        }
    }

    // MARK: Spawn-time scan

    /// Synchronous fresh field for spawn-time lane selection and the coverage
    /// gate. Ignores the settle/interval debounce (one scan per visit is
    /// cheap) unless a scan just ran.
    func scanForSpawn(now: TimeInterval) {
        guard UIApplication.shared.applicationState != .background else { return }
        tick(now: now)
        guard let terminal, terminal.window != nil, let surface = terminal.surface else { return }
        guard now - lastScanTime >= Debounce.spawnReuseWindow else { return }

        let sizeInfo = ghostty_surface_size(surface)
        let cols = Int(sizeInfo.columns)
        let rows = Int(sizeInfo.rows)
        let scale = Double(terminal.contentScaleFactor)
        guard cols > 0, rows > 0, scale > 0 else { return }
        let cellW = Double(sizeInfo.cell_width_px) / scale
        let cellH = Double(sizeInfo.cell_height_px) / scale
        guard cellW > 0, cellH > 0 else { return }
        performScan(now: now, cols: cols, rows: rows, cellW: cellW, cellH: cellH)
    }

    // MARK: Heavy scan

    /// Read the viewport text and rebuild the occupied-row bands and coverage.
    /// The only path that touches ghostty_surface_read_text (terminal mutex).
    private func performScan(now: TimeInterval, cols: Int, rows: Int, cellW: Double, cellH: Double) {
        lastScanTime = now
        dirty = false
        guard let terminal, terminal.window != nil, let surface = terminal.surface else {
            field.isValid = false
            return
        }
        guard let text = Ghostty.Surface.readTopRows(rows, cols: cols, surface: surface) else {
            field.isValid = false
            return
        }

        // Per-row occupied column ranges. Character offset ≈ column: wide
        // glyphs (CJK, emoji) undercount the trailing edge; the ±1-cell band
        // padding in rebuildCanvasRects absorbs the common cases.
        var rowCols = [(start: Int, end: Int)?](repeating: nil, count: rows)
        var occupiedCells = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for row in 0..<min(rows, lines.count) {
            var colStart = -1
            var colEnd = -1
            var col = 0
            for ch in lines[row] {
                if !ch.isWhitespace {
                    if colStart < 0 { colStart = col }
                    colEnd = col
                    occupiedCells += 1
                }
                col += 1
            }
            if colStart >= 0 {
                rowCols[row] = (colStart, colEnd)
            }
        }

        // Merge occupied rows into sub-bands of bounded height, each with its
        // own column bounds (so butterflies can use the space right of short
        // lines). Grow the chunk height if the cap would be exceeded; when
        // that can't help (many separate runs, e.g. alternating blank rows),
        // merge adjacent bands across the gaps instead.
        var chunk = Scan.chunkRows
        var bands = Self.buildBands(rowCols: rowCols, chunkRows: chunk)
        while bands.count > Scan.maxBands, chunk < rows {
            chunk *= 2
            bands = Self.buildBands(rowCols: rowCols, chunkRows: chunk)
        }
        if bands.count > Scan.maxBands {
            bands = Self.mergeAdjacent(bands, maxCount: Scan.maxBands)
        }
        bandRows = bands
        scanScrollOffset = lastScrollOffset
        field.coverage = Double(occupiedCells) / Double(cols * rows)
        field.isValid = true
        rebuildCanvasRects(cellW: cellW, cellH: cellH)

        let bandCount = bands.count
        let coveragePct = Int(field.coverage * 100)
        Self.logger.debug("Scan: \(bandCount) bands, \(coveragePct)% coverage")
    }

    private static func buildBands(rowCols: [(start: Int, end: Int)?], chunkRows: Int) -> [RowBand] {
        var bands: [RowBand] = []
        var current: RowBand?
        for (row, cols) in rowCols.enumerated() {
            guard let cols else {
                if let band = current { bands.append(band) }
                current = nil
                continue
            }
            if var band = current {
                band.rowEnd = row
                band.colStart = min(band.colStart, cols.start)
                band.colEnd = max(band.colEnd, cols.end)
                if band.rowEnd - band.rowStart + 1 >= chunkRows {
                    bands.append(band)
                    current = nil
                } else {
                    current = band
                }
            } else {
                current = RowBand(rowStart: row, rowEnd: row, colStart: cols.start, colEnd: cols.end)
            }
        }
        if let band = current { bands.append(band) }
        return bands
    }

    /// Pairwise-merge neighbors (bridging the blank gaps between them) until
    /// under the cap. Conservative: a bridged gap is treated as occupied.
    private static func mergeAdjacent(_ bands: [RowBand], maxCount: Int) -> [RowBand] {
        var result = bands
        while result.count > maxCount {
            var merged: [RowBand] = []
            merged.reserveCapacity((result.count + 1) / 2)
            var i = 0
            while i < result.count {
                if i + 1 < result.count {
                    let a = result[i]
                    let b = result[i + 1]
                    merged.append(RowBand(
                        rowStart: a.rowStart,
                        rowEnd: b.rowEnd,
                        colStart: min(a.colStart, b.colStart),
                        colEnd: max(a.colEnd, b.colEnd)))
                    i += 2
                } else {
                    merged.append(result[i])
                    i += 1
                }
            }
            result = merged
        }
        return result
    }

    // MARK: Coordinate conversion

    /// Row-space bands → canvas rects at the current scroll position.
    private func rebuildCanvasRects(cellW: Double, cellH: Double) {
        guard let terminal else { return }
        guard !bandRows.isEmpty, canvasFrameInGlobal.width > 0 else {
            field.bands = []
            return
        }
        let padY = terminal.viewportPadY(cellHeight: cellH) ?? 0
        let scrollDelta = Int(Int64(lastScrollOffset) - Int64(scanScrollOffset))

        var rects: [CGRect] = []
        rects.reserveCapacity(bandRows.count)
        for band in bandRows {
            let r0 = band.rowStart - scrollDelta
            let r1 = band.rowEnd - scrollDelta
            guard r1 >= -1, r0 <= lastRows + 1 else { continue }   // scrolled away
            let local = CGRect(
                x: Double(band.colStart - 1) * cellW - Scan.padPoints,
                y: padY + Double(r0) * cellH - Scan.padPoints,
                width: Double(band.colEnd - band.colStart + 3) * cellW + 2 * Scan.padPoints,
                height: Double(r1 - r0 + 1) * cellH + 2 * Scan.padPoints)
            let windowRect = terminal.convert(local, to: nil)
            rects.append(windowRect.offsetBy(
                dx: -canvasFrameInGlobal.origin.x,
                dy: -canvasFrameInGlobal.origin.y))
        }
        field.bands = rects
    }

    private func convertToCanvas(_ point: CGPoint, from terminal: Ghostty.TerminalView) -> CGPoint {
        let windowPoint = terminal.convert(point, to: nil)
        return CGPoint(
            x: windowPoint.x - canvasFrameInGlobal.origin.x,
            y: windowPoint.y - canvasFrameInGlobal.origin.y)
    }
}

// MARK: - Force Math

/// Pure, unit-strength avoidance forces; each effect multiplies by its own
/// tuned constants so butterflies can dart while jellyfish lean.
enum TextAvoidanceForce {
    struct Sample {
        var bandFx = 0.0
        var bandFy = 0.0
        var cursorFx = 0.0
        var cursorFy = 0.0
        var agitation = 0.0
    }

    /// Evaluate the field at a creature position. Band forces need a valid
    /// scan; the cursor bubble only needs the live per-tick cursor.
    static func evaluate(
        at p: CGPoint,
        field: TextAvoidanceField,
        bandRadius: Double,
        cursorInfluenceScale: Double,
        seed: Int
    ) -> Sample {
        var s = Sample()
        if field.isValid {
            for rect in field.bands {
                accumulateBand(&s, p: p, rect: rect, radius: bandRadius)
            }
        }
        if field.hasCursor {
            accumulateCursor(
                &s, p: p, center: field.cursorCenter,
                core: Double(field.cursorRadius),
                influence: Double(field.cursorRadius) * cursorInfluenceScale,
                seed: seed)
        }
        return s
    }

    private static func accumulateBand(_ s: inout Sample, p: CGPoint, rect: CGRect, radius: Double) {
        let cx = min(max(p.x, rect.minX), rect.maxX)
        let cy = min(max(p.y, rect.minY), rect.maxY)
        let dx = Double(p.x - cx)
        let dy = Double(p.y - cy)
        let d2 = dx * dx + dy * dy
        if d2 > 0 {
            let d = d2.squareRoot()
            guard d < radius else { return }
            let w = 1 - d / radius
            let mag = w * w
            s.bandFx += mag * dx / d
            s.bandFy += mag * dy / d
            s.agitation = max(s.agitation, 0.25 * w)
        } else {
            // Inside a band: push along the edge normals blended by inverse
            // distance — matches the nearest edge when one clearly wins but
            // stays continuous across the rect's medial axes (a hard nearest-
            // edge pick flips sign there, which reads as jitter while a lane
            // drifts past the midline). Vertical escape still naturally wins
            // over a wide text band, and there's no distance blow-up.
            let dLeft = Double(p.x - rect.minX)
            let dRight = Double(rect.maxX - p.x)
            let dTop = Double(p.y - rect.minY)
            let dBottom = Double(rect.maxY - p.y)
            let eps = 6.0
            var nx = 1 / (dRight + eps) - 1 / (dLeft + eps)
            var ny = 1 / (dBottom + eps) - 1 / (dTop + eps)
            let norm = (nx * nx + ny * ny).squareRoot()
            if norm > 1e-6 {
                nx /= norm
                ny /= norm
            } else {
                nx = 0; ny = -1   // dead center: escape upward
            }
            // Ramp 1 → 1.5 over the first few points of depth so the
            // magnitude is also continuous across the band boundary
            // (the outside falloff reaches w = 1 there).
            let mag = 1.0 + 0.5 * min(1, min(dLeft, dRight, dTop, dBottom) / 12)
            s.bandFx += mag * nx
            s.bandFy += mag * ny
            s.agitation = max(s.agitation, 0.25)
        }
    }

    private static func accumulateCursor(
        _ s: inout Sample, p: CGPoint, center: CGPoint,
        core: Double, influence: Double, seed: Int
    ) {
        var dx = Double(p.x - center.x)
        var dy = Double(p.y - center.y)
        var d = (dx * dx + dy * dy).squareRoot()
        if d < 0.5 {
            // Degenerate overlap: deterministic tie-break direction
            let h = Double(seed & 0xffff) / 65535.0 * 2 * .pi
            dx = cos(h)
            dy = sin(h)
            d = 1
        }
        guard d < influence else { return }
        let w = d <= core ? 1.0 : 1 - (d - core) / max(influence - core, 1)
        let mag = w * w
        s.cursorFx += mag * dx / d
        s.cursorFy += mag * dy / d
        s.agitation = max(s.agitation, 0.8 * w)
    }

    // MARK: Lane scoring

    /// How badly a straight crossing lane collides with the field. Sampled
    /// along the on-screen span; a perch point (where the creature lingers)
    /// counts triple. `tMax` < 1 scores only the early part of the lane
    /// (jellyfish that sink out mid-crossing never reach the far side).
    static func lanePenalty(
        entryY: Double,
        exitYDrift: Double,
        entryFromLeft: Bool,
        perchProgress: Double? = nil,
        tMax: Double = 1.0,
        in size: CGSize,
        field: TextAvoidanceField
    ) -> Double {
        guard field.isActive, size.width > 1, size.height > 1 else { return 0 }
        let laneRadius = 40.0
        let cursorInfluence = Double(field.cursorRadius) * 2

        func penalty(at t: Double) -> Double {
            let xFrac = entryFromLeft ? t : 1 - t
            let p = CGPoint(x: size.width * xFrac,
                            y: size.height * (entryY + exitYDrift * t))
            var pen = 0.0
            if field.isValid {
                for rect in field.bands {
                    let cx = min(max(p.x, rect.minX), rect.maxX)
                    let cy = min(max(p.y, rect.minY), rect.maxY)
                    let dx = Double(p.x - cx)
                    let dy = Double(p.y - cy)
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < laneRadius {
                        let w = 1 - d / laneRadius
                        pen += w * w
                    }
                }
            }
            if field.hasCursor, cursorInfluence > 0 {
                let dx = Double(p.x - field.cursorCenter.x)
                let dy = Double(p.y - field.cursorCenter.y)
                let d = (dx * dx + dy * dy).squareRoot()
                if d < cursorInfluence {
                    let w = 1 - d / cursorInfluence
                    pen += 3 * w * w
                }
            }
            return pen
        }

        let samples = 12
        var total = 0.0
        for i in 0..<samples {
            total += penalty(at: (Double(i) + 0.5) / Double(samples) * tMax)
        }
        if let perchProgress, perchProgress <= tMax {
            total += penalty(at: perchProgress) * 3
        }
        return total
    }

    /// Spawn-time lane selection: draw a handful of candidate entry heights,
    /// score each lane against the field, and pick randomly among the
    /// near-best so lanes stay varied instead of converging on one corridor.
    static func pickEntryY(
        in range: ClosedRange<Double>,
        entryFromLeft: Bool,
        field: TextAvoidanceField?,
        viewSize: CGSize
    ) -> Double {
        let fallback = Double.random(in: range)
        guard let field, field.isActive, viewSize.width > 1 else { return fallback }
        var candidates = [fallback]
        for _ in 0..<5 {
            candidates.append(Double.random(in: range))
        }
        let scored = candidates.map { y in
            (y, lanePenalty(entryY: y, exitYDrift: 0, entryFromLeft: entryFromLeft,
                            in: viewSize, field: field))
        }
        guard let best = scored.min(by: { $0.1 < $1.1 })?.1 else { return fallback }
        return scored.filter { $0.1 <= best + 0.15 }.randomElement()?.0 ?? fallback
    }
}
