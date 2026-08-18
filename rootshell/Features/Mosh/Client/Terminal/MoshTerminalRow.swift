//
//  VTRow.swift
//  rootshell
//

import Foundation

final class VTRow: Equatable, @unchecked Sendable {
    var cells: [VTCell]
    var generation: UInt64

    private static var genCounter: UInt64 = 0

    init(width: Int, backgroundColor: UInt32) {
        self.cells = Array(repeating: VTCell(backgroundColor: backgroundColor), count: width)
        self.generation = VTRow.nextGen()
    }

    private static func nextGen() -> UInt64 {
        let value = genCounter
        genCounter &+= 1
        return value
    }

    func copy() -> VTRow {
        let row = VTRow(width: cells.count, backgroundColor: 0)
        row.cells = cells
        row.generation = generation
        return row
    }

    func insertCell(at col: Int, backgroundColor: UInt32) {
        cells.insert(VTCell(backgroundColor: backgroundColor), at: col)
        cells.removeLast()
        generation = VTRow.nextGen()
    }

    func deleteCell(at col: Int, backgroundColor: UInt32) {
        cells.append(VTCell(backgroundColor: backgroundColor))
        cells.remove(at: col)
        generation = VTRow.nextGen()
    }

    func reset(backgroundColor: UInt32) {
        generation = VTRow.nextGen()
        for index in cells.indices {
            cells[index].reset(backgroundColor: backgroundColor)
        }
    }

    func getWrap() -> Bool {
        cells.last?.getWrap() ?? false
    }

    func setWrap(_ value: Bool) {
        guard !cells.isEmpty else { return }
        var cell = cells[cells.count - 1]
        cell.setWrap(value)
        cells[cells.count - 1] = cell
        generation = VTRow.nextGen()
    }

    static func == (lhs: VTRow, rhs: VTRow) -> Bool {
        lhs.generation == rhs.generation && lhs.cells == rhs.cells
    }
}
