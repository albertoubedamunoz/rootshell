//
//  VTParser.swift
//  rootshell
//

import Foundation
import Darwin

final class VTParser {
    private var state: VTParserState = .ground

    init() {}

    private init(state: VTParserState) {
        self.state = state
    }

    func input(_ ch: UInt32, events: inout [VTParserEvent]) {
        let transition = state.transition(for: ch)
        if transition.nextState != nil {
            let exitAction = state.exitAction
            if exitAction != .ignore {
                events.append(VTParserEvent(action: exitAction))
            }
        }
        if transition.action != .ignore {
            events.append(VTParserEvent(action: transition.action, codepoint: ch, hasCodepoint: true))
        }
        if let next = transition.nextState {
            let enterAction = next.entryAction
            if enterAction != .ignore {
                events.append(VTParserEvent(action: enterAction))
            }
            state = next
        }
    }

    func resetInput() {
        state = .ground
    }

    func copy() -> VTParser {
        VTParser(state: state)
    }
}

final class VTUTF8Parser {
    private let parser: VTParser
    private var buffer: [UInt8] = []
    private static let bufferSize = 8

    init() {
        self.parser = VTParser()
        buffer.reserveCapacity(VTUTF8Parser.bufferSize)
    }

    private init(parser: VTParser, buffer: [UInt8]) {
        self.parser = parser
        self.buffer = buffer
        self.buffer.reserveCapacity(VTUTF8Parser.bufferSize)
    }

    func input(_ byte: UInt8, events: inout [VTParserEvent]) {
        if buffer.isEmpty && byte <= 0x7F {
            parser.input(UInt32(byte), events: &events)
            return
        }

        buffer.append(byte)
        if buffer.count > VTUTF8Parser.bufferSize {
            buffer.removeFirst(buffer.count - VTUTF8Parser.bufferSize)
        }

        while true {
            let result = decodeNextScalar()
            switch result {
            case .incomplete:
                return
            case .invalid:
                parser.input(0xFFFD, events: &events)
                continue
            case .scalar(let scalar):
                parser.input(scalar, events: &events)
                continue
            }
        }
    }

    func resetInput() {
        parser.resetInput()
        buffer.removeAll(keepingCapacity: true)
    }

    func copy() -> VTUTF8Parser {
        VTUTF8Parser(parser: parser.copy(), buffer: buffer)
    }

    private enum DecodeResult {
        case scalar(UInt32)
        case incomplete
        case invalid
    }

    private func decodeNextScalar() -> DecodeResult {
        guard !buffer.isEmpty else { return .incomplete }

        let b0 = buffer[0]
        if b0 <= 0x7F {
            buffer.removeFirst()
            return .scalar(UInt32(b0))
        }

        let expectedLength: Int
        if (0xC2...0xDF).contains(b0) {
            expectedLength = 2
        } else if (0xE0...0xEF).contains(b0) {
            expectedLength = 3
        } else if (0xF0...0xF4).contains(b0) {
            expectedLength = 4
        } else {
            handleInvalidSequence()
            return .invalid
        }

        if buffer.count < expectedLength {
            return .incomplete
        }

        let bytes = Array(buffer.prefix(expectedLength))
        if !validContinuation(bytes) {
            handleInvalidSequence()
            return .invalid
        }

        if let scalar = decodeScalar(bytes: bytes) {
            buffer.removeFirst(expectedLength)
            if scalar > 0x10FFFF || (0xD800...0xDFFF).contains(scalar) {
                return .scalar(0xFFFD)
            }
            return .scalar(scalar)
        }

        handleInvalidSequence()
        return .invalid
    }

    private func validContinuation(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 2:
            return (bytes[1] & 0xC0) == 0x80
        case 3:
            if bytes[0] == 0xE0 {
                if !(0xA0...0xBF).contains(bytes[1]) { return false }
            } else if bytes[0] == 0xED {
                if !(0x80...0x9F).contains(bytes[1]) { return false }
            } else if (bytes[1] & 0xC0) != 0x80 {
                return false
            }
            return (bytes[2] & 0xC0) == 0x80
        case 4:
            if bytes[0] == 0xF0 {
                if !(0x90...0xBF).contains(bytes[1]) { return false }
            } else if bytes[0] == 0xF4 {
                if !(0x80...0x8F).contains(bytes[1]) { return false }
            } else if (bytes[1] & 0xC0) != 0x80 {
                return false
            }
            return (bytes[2] & 0xC0) == 0x80 && (bytes[3] & 0xC0) == 0x80
        default:
            return false
        }
    }

    private func decodeScalar(bytes: [UInt8]) -> UInt32? {
        switch bytes.count {
        case 2:
            let scalar = (UInt32(bytes[0] & 0x1F) << 6) | UInt32(bytes[1] & 0x3F)
            return scalar
        case 3:
            let scalar = (UInt32(bytes[0] & 0x0F) << 12)
                | (UInt32(bytes[1] & 0x3F) << 6)
                | UInt32(bytes[2] & 0x3F)
            return scalar
        case 4:
            let scalar = (UInt32(bytes[0] & 0x07) << 18)
                | (UInt32(bytes[1] & 0x3F) << 12)
                | (UInt32(bytes[2] & 0x3F) << 6)
                | UInt32(bytes[3] & 0x3F)
            return scalar
        default:
            return nil
        }
    }

    private func handleInvalidSequence() {
        // Maximal-subpart consumption (Unicode Table 3-7 / W3C recommendation):
        // consume only the longest well-formed prefix and leave the rest for
        // the next decode pass. The previous "keep last byte" behavior could
        // silently swallow an ESC byte sitting between an invalid lead and a
        // trailing graphic char, which then printed the trailing char as
        // ground-state text.
        guard !buffer.isEmpty else { return }
        let b0 = buffer[0]
        if b0 < 0xC2 || b0 > 0xF4 {
            buffer.removeFirst()
            return
        }
        let allowedSecond: ClosedRange<UInt8>
        switch b0 {
        case 0xE0: allowedSecond = 0xA0...0xBF
        case 0xED: allowedSecond = 0x80...0x9F
        case 0xF0: allowedSecond = 0x90...0xBF
        case 0xF4: allowedSecond = 0x80...0x8F
        default:   allowedSecond = 0x80...0xBF
        }
        var consume = 1
        if buffer.count > 1, allowedSecond.contains(buffer[1]) {
            consume = 2
            if (0xE0...0xF4).contains(b0), buffer.count > 2, (buffer[2] & 0xC0) == 0x80 {
                consume = 3
                if (0xF0...0xF4).contains(b0), buffer.count > 3, (buffer[3] & 0xC0) == 0x80 {
                    consume = 4
                }
            }
        }
        buffer.removeFirst(consume)
    }
}
