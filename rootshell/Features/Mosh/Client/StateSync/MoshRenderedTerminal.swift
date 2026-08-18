//
//  MoshRenderedTerminal.swift
//  rootshell
//

import Foundation

final class MoshRenderedTerminal: MoshSyncableState, Equatable {
    private let utf8Decoder: VTUTF8Parser
    private let emulator: VTEmulator
    private let displayRenderer: VTDisplayRenderer

    private var pendingEvents: [VTParserEvent] = []

    private typealias EchoTrackingEntry = (frame: UInt64, timestamp: UInt64)
    private var echoTrackingHistory: [EchoTrackingEntry] = []
    private var confirmedEchoFrame: UInt64 = 0

    private static let echoConfirmationDelayMs: UInt64 = 50

    init(width: Int, height: Int) {
        self.utf8Decoder = VTUTF8Parser()
        self.emulator = VTEmulator(width: width, height: height)
        self.displayRenderer = VTDisplayRenderer(useEnvironment: false)
    }

    private init(
        utf8Decoder: VTUTF8Parser,
        emulator: VTEmulator,
        displayRenderer: VTDisplayRenderer,
        pendingEvents: [VTParserEvent],
        echoTrackingHistory: [EchoTrackingEntry],
        confirmedEchoFrame: UInt64
    ) {
        self.utf8Decoder = utf8Decoder
        self.emulator = emulator
        self.displayRenderer = displayRenderer
        self.pendingEvents = pendingEvents
        self.echoTrackingHistory = echoTrackingHistory
        self.confirmedEchoFrame = confirmedEchoFrame
    }

    func processInput(_ data: Data) -> Data {
        for byte in data {
            utf8Decoder.input(byte, events: &pendingEvents)
            for event in pendingEvents {
                emulator.handle(event)
            }
            pendingEvents.removeAll(keepingCapacity: true)
        }
        return emulator.drainHostOutput()
    }

    func processEvent(_ event: VTParserEvent) -> Data {
        emulator.handle(event)
        return emulator.drainHostOutput()
    }

    var framebuffer: VTFramebuffer { emulator.framebuffer }

    func resetParser() { utf8Decoder.resetInput() }

    var echoAcknowledgment: UInt64 { confirmedEchoFrame }

    func advanceEchoAcknowledgment(at now: UInt64) -> Bool {
        var ret = false
        var newestEchoAck: UInt64 = 0

        for entry in echoTrackingHistory {
            if entry.timestamp <= now - MoshRenderedTerminal.echoConfirmationDelayMs {
                newestEchoAck = entry.frame
            }
        }

        echoTrackingHistory.removeAll { $0.frame < newestEchoAck }
        if confirmedEchoFrame != newestEchoAck {
            ret = true
        }
        confirmedEchoFrame = newestEchoAck
        return ret
    }

    func recordFrameForEchoTracking(frame: UInt64, at now: UInt64) {
        echoTrackingHistory.append((frame, now))
    }

    func timeUntilNextEchoUpdate(at now: UInt64) -> Int {
        if echoTrackingHistory.count < 2 {
            return Int.max
        }
        let next = echoTrackingHistory[1]
        let nextEchoTime = next.timestamp + MoshRenderedTerminal.echoConfirmationDelayMs
        if nextEchoTime <= now { return 0 }
        return Int(nextEchoTime - now)
    }

    func pruneAcknowledged(_ baseline: MoshRenderedTerminal?) {
        // No-op for terminal state
    }

    func encodeDelta(since existing: MoshRenderedTerminal) -> Data {
        var message = HostMessage()

        if existing.echoAcknowledgment != echoAcknowledgment {
            message.instructions.append(.echoAck(.init(echoNum: echoAcknowledgment)))
        }

        if existing.framebuffer != framebuffer {
            if existing.framebuffer.cursorState.getWidth() != emulator.framebuffer.cursorState.getWidth()
                || existing.framebuffer.cursorState.getHeight() != emulator.framebuffer.cursorState.getHeight() {
                message.instructions.append(.resize(width: UInt32(emulator.framebuffer.cursorState.getWidth()), height: UInt32(emulator.framebuffer.cursorState.getHeight())))
            }
            let update = displayRenderer.renderDelta(initialized: true, last: existing.framebuffer, f: emulator.framebuffer)
            if !update.isEmpty {
                message.instructions.append(.hostBytes(.init(data: Data(update.utf8))))
            }
        }

        return (try? message.serialize()) ?? Data()
    }

    func encodeSnapshot() -> Data {
        let empty = MoshRenderedTerminal(width: emulator.framebuffer.cursorState.getWidth(), height: emulator.framebuffer.cursorState.getHeight())
        return encodeDelta(since: empty)
    }

    func applyDelta(_ payload: Data) {
        guard let msg = try? HostMessage.deserialize(payload) else { return }
        for instruction in msg.instructions {
            switch instruction {
            case .hostBytes(let bytes):
                let out = processInput(bytes.data)
                // Host output is rendered locally, not echoed
                _ = out
            case .resize(let width, let height):
                let event = VTParserEvent(action: .resize(width: Int(width), height: Int(height)))
                _ = processEvent(event)
            case .echoAck(let ack):
                let num = ack.echoNum
                if num >= confirmedEchoFrame {
                    confirmedEchoFrame = num
                }
            }
        }
    }

    static func == (lhs: MoshRenderedTerminal, rhs: MoshRenderedTerminal) -> Bool {
        return lhs.emulator == rhs.emulator && lhs.confirmedEchoFrame == rhs.confirmedEchoFrame
    }

    func hasCellDifferences(from other: MoshRenderedTerminal) -> Bool {
        // Cell-by-cell framebuffer comparison
        let fb = emulator.framebuffer
        let otherFb = other.emulator.framebuffer
        if fb.cursorState.getHeight() != otherFb.cursorState.getHeight() || fb.cursorState.getWidth() != otherFb.cursorState.getWidth() {
            return true
        }
        let height = fb.cursorState.getHeight()
        let width = fb.cursorState.getWidth()
        for y in 0..<height {
            for x in 0..<width {
                if fb.getCell(row: y, col: x).hasDifferences(from: otherFb.getCell(row: y, col: x)) {
                    return true
                }
            }
        }
        if fb.cursorState.getCursorRow() != otherFb.cursorState.getCursorRow() || fb.cursorState.getCursorCol() != otherFb.cursorState.getCursorCol() {
            return true
        }
        return false
    }

    func copy() -> MoshRenderedTerminal {
        MoshRenderedTerminal(
            utf8Decoder: utf8Decoder.copy(),
            emulator: emulator.copy(),
            displayRenderer: VTDisplayRenderer(useEnvironment: false),
            pendingEvents: pendingEvents,
            echoTrackingHistory: echoTrackingHistory,
            confirmedEchoFrame: confirmedEchoFrame
        )
    }
}
