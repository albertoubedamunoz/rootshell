//
//  TabExposeLayout.swift
//  rootshell
//
//  Pure grid math for the tab exposé: cells keep the terminal area's aspect
//  ratio, the column count maximizes cell size while everything fits, and
//  the grid scrolls (never paginates) when it can't.
//

import CoreGraphics
import Foundation

/// Damped spring step shared by the reveal progress and the page shift.
nonisolated struct ExposeSpring {
    static func step(value: inout CGFloat, velocity: inout CGFloat, target: CGFloat,
                     response: CGFloat, damping: CGFloat, dt: CGFloat) {
        let omega = 2 * CGFloat.pi / max(response, 0.05)
        let accel = -omega * omega * (value - target) - 2 * damping * omega * velocity
        velocity += accel * dt
        value += velocity * dt
    }
}

nonisolated struct TabExposeLayout {
    struct Metrics: Equatable {
        var margin: CGFloat
        var gutter: CGFloat
        var captionHeight: CGFloat
        var minCellWidth: CGFloat
        var headerHeight: CGFloat
        /// Cells never exceed this fraction of the available width.
        var maxCellWidthFraction: CGFloat = 0.8

        /// Constants by layout class; `compact` is phone or any width under 500.
        static func standard(compact: Bool, mac: Bool, vision: Bool,
                             showsCaptions: Bool, hasHeader: Bool) -> Metrics {
            var m: Metrics
            if vision {
                m = Metrics(margin: 24, gutter: 20, captionHeight: 26, minCellWidth: 240, headerHeight: 40)
            } else if compact {
                m = Metrics(margin: 12, gutter: 12, captionHeight: 20, minCellWidth: 110, headerHeight: 32)
            } else {
                m = Metrics(margin: mac ? 20 : 16, gutter: 16, captionHeight: 22, minCellWidth: 200, headerHeight: 36)
            }
            if !showsCaptions { m.captionHeight = 0 }
            if !hasHeader { m.headerHeight = 0 }
            return m
        }
    }

    struct Result: Equatable {
        var columns: Int
        var rows: Int
        /// Size of the preview area of one cell (caption sits below it).
        var cellSize: CGSize
        /// Outer frames (preview + caption) in the input rect's coordinate space.
        var frames: [CGRect]
        var headerFrame: CGRect
        /// Total height needed; greater than `rect.height` means scroll.
        var contentHeight: CGFloat
        var fits: Bool
        /// Cell width of the auto-fit grid (zoom 1); zoom scales from here.
        var baseCellWidth: CGFloat = 0
        /// Zoom at which the current column count exactly fills the width.
        var snappedZoom: CGFloat = 1

        static let empty = Result(columns: 1, rows: 0, cellSize: .zero, frames: [], headerFrame: .zero, contentHeight: 0, fits: true)
    }

    /// Cell width at which `columns` cells exactly fill `width`.
    static func cellWidth(fillingColumns columns: Int, width: CGFloat, metrics m: Metrics) -> CGFloat {
        (width - 2 * m.margin - CGFloat(max(columns, 1) - 1) * m.gutter) / CGFloat(max(columns, 1))
    }

    /// - Parameters:
    ///   - rect: area available for the tray (header + grid), in any coordinate space.
    ///   - count: number of cells.
    ///   - aspect: preview width / height (the terminal area's aspect).
    ///   - zoom: user scale applied to the auto-fit cell width; 1 = auto-fit.
    static func grid(in rect: CGRect, count: Int, aspect: CGFloat, metrics m: Metrics, zoom: CGFloat = 1) -> Result {
        guard count > 0, rect.width > 0, rect.height > 0 else { return .empty }
        let a = max(aspect, 0.1)
        let maxCellW = rect.width * m.maxCellWidthFraction

        func widthBound(_ c: Int) -> CGFloat {
            cellWidth(fillingColumns: c, width: rect.width, metrics: m)
        }
        func heightBound(_ c: Int) -> CGFloat {
            let rows = CGFloat((count + c - 1) / c)
            let available = rect.height - 2 * m.margin - m.headerHeight
                - (rows - 1) * m.gutter - rows * m.captionHeight
            return a * available / rows
        }

        var best: (columns: Int, width: CGFloat)?
        var fitting: [(columns: Int, width: CGFloat)] = []
        for c in 1...count {
            let w = min(widthBound(c), heightBound(c), maxCellW)
            guard w >= m.minCellWidth else { continue }
            fitting.append((c, w))
            if best == nil || w > best!.width { best = (c, w) }
        }

        var columns: Int
        var cellW: CGFloat
        var fits = true
        if let best {
            // Among layouts nearly as large as the best, prefer fewer rows.
            let threshold = best.width * 0.7
            let candidates = fitting.filter { $0.width >= threshold }
            let fewestRows = candidates.min { lhs, rhs in
                let lr = (count + lhs.columns - 1) / lhs.columns
                let rr = (count + rhs.columns - 1) / rhs.columns
                return lr != rr ? lr < rr : lhs.width > rhs.width
            } ?? best
            columns = fewestRows.columns
            cellW = fewestRows.width
        } else {
            // Nothing fits the height: fix columns by width and scroll.
            fits = false
            columns = 1
            for c in 1...count where widthBound(c) >= m.minCellWidth { columns = c }
            cellW = min(widthBound(columns), maxCellW)
        }

        // Zoom scales the auto-fit width and re-derives the column count;
        // the grid scrolls when the taller result no longer fits.
        let baseCellW = cellW
        let z = zoom.isFinite ? max(zoom, 0.05) : 1
        if z != 1 {
            let floorW = min(m.minCellWidth * 0.5, baseCellW)
            cellW = min(max(baseCellW * z, floorW), maxCellW)
            columns = 1
            for c in 1...count where widthBound(c) >= cellW { columns = c }
        }
        let snappedZoom = baseCellW > 0 ? min(widthBound(columns), maxCellW) / baseCellW : 1

        let cellH = cellW / a
        let rows = (count + columns - 1) / columns
        let pitchY = cellH + m.captionHeight + m.gutter
        let contentHeight = 2 * m.margin + m.headerHeight
            + CGFloat(rows) * (cellH + m.captionHeight) + CGFloat(rows - 1) * m.gutter
        if z != 1 { fits = contentHeight <= rect.height + 0.5 }
        let verticalSlack = fits ? max(0, (rect.height - contentHeight) / 2) : 0

        let headerFrame = CGRect(x: rect.minX + m.margin,
                                 y: rect.minY + m.margin + verticalSlack,
                                 width: rect.width - 2 * m.margin,
                                 height: m.headerHeight)

        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let col = index % columns
            let row = index / columns
            let rowCount = row == rows - 1 ? count - row * columns : columns
            let rowW = CGFloat(rowCount) * cellW + CGFloat(rowCount - 1) * m.gutter
            let x = rect.minX + (rect.width - rowW) / 2 + CGFloat(col) * (cellW + m.gutter)
            let y = rect.minY + m.margin + m.headerHeight + verticalSlack + CGFloat(row) * pitchY
            frames.append(CGRect(x: x, y: y, width: cellW, height: cellH + m.captionHeight))
        }

        return Result(columns: columns, rows: rows, cellSize: CGSize(width: cellW, height: cellH),
                      frames: frames, headerFrame: headerFrame, contentHeight: contentHeight, fits: fits,
                      baseCellWidth: baseCellW, snappedZoom: snappedZoom)
    }
}
