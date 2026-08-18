//
//  VTEmulator.swift
//  rootshell
//

import Foundation
import Darwin

final class VTEmulator: Equatable {
    private(set) var framebuffer: VTFramebuffer
    let dispatch: VTSequenceDispatcher
    let user: VTUserInputProcessor

    init(width: Int, height: Int) {
        self.framebuffer = VTFramebuffer(width: width, height: height)
        self.dispatch = VTSequenceDispatcher()
        self.user = VTUserInputProcessor()
        VTSequenceHandlers.registerAll()
    }

    private init(framebuffer: VTFramebuffer, dispatch: VTSequenceDispatcher, user: VTUserInputProcessor) {
        self.framebuffer = framebuffer
        self.dispatch = dispatch
        self.user = user
        VTSequenceHandlers.registerAll()
    }

    func drainHostOutput() -> Data {
        let data = dispatch.hostResponseBuffer
        dispatch.hostResponseBuffer.removeAll(keepingCapacity: true)
        return data
    }

    func handle(_ event: VTParserEvent) {
        switch event.action {
        case .print:
            handlePrintable(event)
        case .execute:
            dispatch.dispatch(.control, event, framebuffer: framebuffer)
        case .clear:
            dispatch.clear()
        case .collectParam:
            dispatch.newParamChar(event)
        case .collectIntermediate:
            dispatch.collect(event)
        case .dispatchEsc:
            escDispatch(event)
        case .dispatchCSI:
            dispatch.dispatch(.csi, event, framebuffer: framebuffer)
        case .endOSC:
            dispatch.oscDispatch(framebuffer: framebuffer)
        case .beginOSC:
            dispatch.oscStart()
        case .feedOSC:
            dispatch.oscPut(event)
        case .hookDCS, .putDCS, .unhookDCS:
            break
        case .ignore:
            break
        case .userByte(let byte):
            let data = user.input(byte, applicationModeCursorKeys: framebuffer.cursorState.applicationModeCursorKeys)
            dispatch.hostResponseBuffer.append(data)
        case .resize(let width, let height):
            framebuffer.resize(width: width, height: height)
        }
    }

    private func handlePrintable(_ event: VTParserEvent) {
        guard event.hasCodepoint else { return }
        let ch = event.codepoint

        let chwidth = VTCell.displayWidth(ch)

        switch chwidth {
        case 1, 2:
            var thisCell: VTCell? = framebuffer.getMutableCell()

            if framebuffer.cursorState.autoWrapMode && framebuffer.cursorState.nextPrintWillWrap {
                framebuffer.ensureUniqueRow(-1).setWrap(true)
                framebuffer.cursorState.moveCol(0)
                framebuffer.advanceCursorWithScroll(1)
                thisCell = nil
            } else if framebuffer.cursorState.autoWrapMode && chwidth == 2 && framebuffer.cursorState.getCursorCol() == framebuffer.cursorState.getWidth() - 1 {
                if var cell = thisCell {
                    framebuffer.resetCell(&cell)
                    framebuffer.setMutableCell(cell)
                }
                framebuffer.ensureUniqueRow(-1).setWrap(false)
                framebuffer.cursorState.moveCol(0)
                framebuffer.advanceCursorWithScroll(1)
                thisCell = nil
            }

            if framebuffer.cursorState.insertMode {
                for _ in 0..<chwidth {
                    framebuffer.insertCell(row: framebuffer.cursorState.getCursorRow(), col: framebuffer.cursorState.getCursorCol())
                }
                thisCell = nil
            }

            if thisCell == nil {
                thisCell = framebuffer.getMutableCell()
            }

            if var cell = thisCell {
                framebuffer.resetCell(&cell)
                cell.append(ch)
                cell.setWide(chwidth == 2)
                var cellOpt: VTCell? = cell
                framebuffer.applyRenditionsToCell(&cellOpt)
                if let updated = cellOpt {
                    cell = updated
                }
                framebuffer.setMutableCell(cell)
            }

            if chwidth == 2 && framebuffer.cursorState.getCursorCol() + 1 < framebuffer.cursorState.getWidth() {
                var cell = framebuffer.getMutableCell(row: framebuffer.cursorState.getCursorRow(), col: framebuffer.cursorState.getCursorCol() + 1)
                framebuffer.resetCell(&cell)
                framebuffer.setMutableCell(cell, row: framebuffer.cursorState.getCursorRow(), col: framebuffer.cursorState.getCursorCol() + 1)
            }

            framebuffer.cursorState.moveCol(chwidth, relative: true, implicit: true)
        case 0:
            let row = framebuffer.cursorState.getCombiningCharRow()
            let col = framebuffer.cursorState.getCombiningCharCol()
            guard row >= 0, col >= 0 else { break }
            guard row < framebuffer.cursorState.getHeight(), col < framebuffer.cursorState.getWidth() else { break }
            var cell = framebuffer.getMutableCell(row: row, col: col)
            if cell.isEmpty {
                cell.setFallback(true)
                framebuffer.cursorState.moveCol(1, relative: true, implicit: true)
            }
            if !cell.isFull {
                cell.append(ch)
            }
            framebuffer.setMutableCell(cell, row: row, col: col)
        case -1:
            break
        default:
            break
        }
    }

    private func escDispatch(_ event: VTParserEvent) {
        if dispatch.getDispatchChars().isEmpty, (0x40...0x5F).contains(event.codepoint) {
            let ctrlEvent = VTParserEvent(action: .execute, codepoint: event.codepoint + 0x40, hasCodepoint: event.hasCodepoint)
            dispatch.dispatch(.control, ctrlEvent, framebuffer: framebuffer)
        } else {
            dispatch.dispatch(.escape, event, framebuffer: framebuffer)
        }
    }

    func replaceFramebuffer(_ framebuffer: VTFramebuffer) {
        self.framebuffer = framebuffer
    }

    func copy() -> VTEmulator {
        VTEmulator(
            framebuffer: framebuffer.copy(),
            dispatch: dispatch.copy(),
            user: user.copy()
        )
    }

    func resetInput() {
        // no parser state here; handled by Complete
    }

    static func == (lhs: VTEmulator, rhs: VTEmulator) -> Bool {
        lhs.framebuffer == rhs.framebuffer
    }
}
