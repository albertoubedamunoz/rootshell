#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - Input Events

/// Mouse button identifiers.
enum RFMouseButton: Sendable {
    case left, middle, right, none
}

/// Scroll direction.
enum RFScrollDirection: Sendable {
    case up, down
}

/// Parsed input event from raw terminal escape sequences.
enum RFInputEvent: Sendable {
    // Keyboard
    case character(Character)
    case enter
    case backspace
    case delete
    case escape
    case tab
    case shiftTab

    // Arrows (with shift modifier)
    case arrowUp(shift: Bool)
    case arrowDown(shift: Bool)
    case arrowLeft(shift: Bool)
    case arrowRight(shift: Bool)

    // Navigation
    case home
    case end
    case pageUp
    case pageDown

    // Control keys
    case ctrlA
    case ctrlC
    case ctrlD
    case ctrlE
    case ctrlK
    case ctrlL
    case ctrlU
    case ctrlW

    // Mouse (SGR extended mode, 0-indexed coordinates)
    case mousePress(button: RFMouseButton, col: Int, row: Int)
    case mouseRelease(button: RFMouseButton, col: Int, row: Int)
    case mouseMotion(button: RFMouseButton, col: Int, row: Int)
    case mouseScroll(direction: RFScrollDirection, col: Int, row: Int)
}

// MARK: - Input Parser

/// Parses raw bytes from terminal input into structured events.
///
/// Three kinds of partial state can be pending between `parse` calls, since a
/// sequence may be split across chunk boundaries: a string sequence body, an
/// escape sequence, and an incomplete UTF-8 scalar. Every byte goes through
/// `feed`, which checks them in that priority order; recovery paths clear the
/// state first and then re-dispatch the byte, so a truncated or stray sequence
/// can never desync the stream.
@MainActor
final class RFInputParser {
    /// Outcome of feeding a byte into a partially collected escape sequence.
    private enum EscapeResult {
        case incomplete           // need more bytes
        case event(RFInputEvent)  // complete and recognized
        case unrecognized         // complete but not ours: consume and drop
    }

    /// Partial escape sequence buffer
    private var escBuffer: [UInt8] = []
    private var inEscapeSequence = false

    /// String sequence (DCS/SOS/OSC/PM/APC) state. The body is consumed and dropped.
    private var inStringSequence = false
    private var stringSawEsc = false
    private var stringHasBody = false
    private var stringIntroducer: UInt8 = 0

    /// Partial UTF-8 scalar state
    private var utf8Buffer: [UInt8] = []
    private var utf8Needed = 0

    /// Scalars accumulated for the grapheme cluster currently being typed
    private var pendingCluster: String = ""

    /// Max escape sequence length before giving up
    private static let maxEscLength = 32

    /// Max scalars in one grapheme cluster before it is emitted regardless
    private static let maxClusterScalars = 32

    /// True when a sequence has been started but is not resolved yet. These
    /// need the human-pause window, since the alternative reading is a keypress.
    /// A string sequence whose body has started is excluded: it is terminal
    /// output and silence tells us nothing about it.
    var hasPendingSequence: Bool {
        inEscapeSequence || (inStringSequence && !stringHasBody)
    }

    /// True when a grapheme cluster is still open and could take more scalars.
    /// This only needs to outlast a pipe-read split, not a human pause.
    var hasPendingCluster: Bool { !pendingCluster.isEmpty }

    /// Parse raw input data into events.
    ///
    /// Nothing pending is resolved here. Chunks are pipe reads, not keystroke
    /// or sequence boundaries, so an open cluster or sequence may still have
    /// bytes coming. `flush()` resolves them once input goes quiet.
    func parse(_ data: Data) -> [RFInputEvent] {
        var events: [RFInputEvent] = []
        for byte in data {
            feed(byte, &events)
        }
        return events
    }

    /// Resolve pending state once input has gone quiet.
    func flush() -> [RFInputEvent] {
        var events: [RFInputEvent] = []
        if inStringSequence, !stringHasBody {
            // An introducer with no body at all, and then silence. A real reply
            // streams its body in the same breath as the introducer, so this is
            // a keypress the terminal encoded as ESC + character (Alt+P, Alt+],
            // or Escape followed closely by one of those).
            //
            // Once a body has started there is nothing to resolve: silence is
            // not evidence that a reply ended, and leaving discard mode would
            // hand terminal output to the keyboard parser, where it could run
            // destructive normal-mode commands. Such a sequence stays in
            // discard mode until its terminator or the C0 rule below breaks it.
            let introducer = stringIntroducer
            endStringSequence()
            flushCluster(&events)
            events.append(.escape)
            feedFresh(introducer, &events)
        } else if inEscapeSequence {
            // A lone ESC is the Escape key; anything collected after it is
            // reprocessed as typed input (xterm's escape-timeout behaviour).
            let pending = Array(escBuffer.dropFirst())
            resetEscape()
            flushCluster(&events)
            events.append(.escape)
            for byte in pending {
                feed(byte, &events)
            }
        }
        flushCluster(&events)
        return events
    }

    /// Drop every kind of partial state. Used when rf leaves the screen, so a
    /// half-typed cluster or sequence cannot surface as an event after it
    /// returns.
    func reset() {
        resetEscape()
        endStringSequence()
        utf8Buffer.removeAll()
        utf8Needed = 0
        pendingCluster.removeAll()
    }

    private func resetEscape() {
        escBuffer.removeAll()
        inEscapeSequence = false
    }

    // MARK: - Byte Dispatch

    private func feed(_ byte: UInt8, _ events: inout [RFInputEvent]) {
        if inStringSequence { feedStringSequence(byte, &events); return }
        if inEscapeSequence { feedEscape(byte, &events); return }
        if utf8Needed > 0 { feedUTF8Continuation(byte, &events); return }
        feedFresh(byte, &events)
    }

    /// Dispatch a byte with no partial state pending.
    private func feedFresh(_ byte: UInt8, _ events: inout [RFInputEvent]) {
        if byte == 0x1B {
            inEscapeSequence = true
            escBuffer = [byte]
            return
        }
        if byte < 0x80 {
            if let event = parseControlByte(byte) {
                flushCluster(&events)
                events.append(event)
            } else if byte >= 0x20, byte <= 0x7E {
                emitScalar(UnicodeScalar(byte), &events)
            }
            return
        }
        switch byte {
        case 0xC2...0xDF: utf8Needed = 2
        case 0xE0...0xEF: utf8Needed = 3
        case 0xF0...0xF4: utf8Needed = 4
        default: return // stray continuation or invalid lead
        }
        utf8Buffer = [byte]
    }

    // MARK: - UTF-8

    private func feedUTF8Continuation(_ byte: UInt8, _ events: inout [RFInputEvent]) {
        guard byte & 0xC0 == 0x80 else {
            // Truncated scalar. Drop it and reprocess this byte cleanly.
            utf8Buffer.removeAll()
            utf8Needed = 0
            feedFresh(byte, &events)
            return
        }
        utf8Buffer.append(byte)
        guard utf8Buffer.count == utf8Needed else { return }
        let bytes = utf8Buffer
        utf8Buffer.removeAll()
        utf8Needed = 0
        if let scalar = Self.decodeScalar(bytes) {
            emitScalar(scalar, &events)
        }
    }

    // MARK: - Grapheme Clusters

    /// Accumulate scalars into the grapheme cluster being typed, so a base
    /// character plus its combining marks, variation selectors or ZWJ parts
    /// arrive as one `.character` event. Without this, normal-mode bindings
    /// would fire on the base scalar before the rest of the cluster lands.
    ///
    /// A keystroke reaches us as a single `Data` chunk, so `parse` flushes at
    /// the end of every chunk and typing incurs no delay. A cluster split
    /// across chunks degrades to one event per part.
    private func emitScalar(_ scalar: UnicodeScalar, _ events: inout [RFInputEvent]) {
        if pendingCluster.isEmpty {
            pendingCluster = String(scalar)
            return
        }
        let extended = pendingCluster + String(scalar)
        if extended.count == 1, extended.unicodeScalars.count <= Self.maxClusterScalars {
            pendingCluster = extended
            return
        }
        events.append(.character(Character(pendingCluster)))
        pendingCluster = String(scalar)
    }

    /// Emit the accumulated cluster. Called before any non-character event and
    /// at the end of each chunk so event order is preserved.
    private func flushCluster(_ events: inout [RFInputEvent]) {
        guard !pendingCluster.isEmpty else { return }
        events.append(.character(Character(pendingCluster)))
        pendingCluster.removeAll()
    }

    /// Decode a complete UTF-8 sequence, rejecting overlongs, surrogates and
    /// out-of-range scalars.
    private static func decodeScalar(_ bytes: [UInt8]) -> UnicodeScalar? {
        var value: UInt32
        let minimum: UInt32
        switch bytes.count {
        case 2: value = UInt32(bytes[0] & 0x1F); minimum = 0x80
        case 3: value = UInt32(bytes[0] & 0x0F); minimum = 0x800
        case 4: value = UInt32(bytes[0] & 0x07); minimum = 0x10000
        default: return nil
        }
        for b in bytes.dropFirst() {
            value = (value << 6) | UInt32(b & 0x3F)
        }
        guard value >= minimum else { return nil }
        return UnicodeScalar(value) // nil for surrogates and > U+10FFFF
    }

    // MARK: - Single Byte

    /// Control bytes only. Printable ASCII goes through the grapheme
    /// accumulator so it can absorb a following combining scalar.
    private func parseControlByte(_ byte: UInt8) -> RFInputEvent? {
        switch byte {
        case 0x01: return .ctrlA
        case 0x03: return .ctrlC
        case 0x04: return .ctrlD
        case 0x05: return .ctrlE
        case 0x09: return .tab
        case 0x0B: return .ctrlK
        case 0x0C: return .ctrlL
        case 0x0D: return .enter
        case 0x15: return .ctrlU
        case 0x17: return .ctrlW
        case 0x08: return .backspace
        case 0x7F: return .backspace
        default:
            return nil
        }
    }

    // MARK: - String Sequences

    /// ESC P (DCS), ESC X (SOS), ESC ] (OSC), ESC ^ (PM), ESC _ (APC) run until
    /// a string terminator. Terminal replies arrive this way and must not reach
    /// the input line.
    private static func isStringIntroducer(_ byte: UInt8) -> Bool {
        byte == 0x50 || byte == 0x58 || byte == 0x5D || byte == 0x5E || byte == 0x5F
    }

    /// Discard the body until a terminator. There is deliberately no length cap
    /// and no timeout: giving up mid-reply would hand the rest of the response
    /// to the keyboard parser, where it could run destructive normal-mode
    /// commands. The one exit is the C0 rule below, which is a property of the
    /// bytes rather than of timing.
    private func feedStringSequence(_ byte: UInt8, _ events: inout [RFInputEvent]) {
        if byte == 0x07 { endStringSequence(); return } // BEL
        if stringSawEsc {
            stringSawEsc = false
            if byte == 0x5C { endStringSequence(); return } // ST: ESC backslash
        } else if byte == 0x1B {
            stringSawEsc = true
            stringHasBody = true
            return
        }
        // CAN and SUB cancel a control string per ECMA-48. Other C0 bytes are
        // legal body content in OSC and DCS, so they must keep being discarded:
        // aborting on those would hand the rest of a real reply to the keyboard
        // parser, which is the case this whole state exists to prevent.
        if byte == 0x18 || byte == 0x1A { // CAN, SUB
            endStringSequence()
            return
        }
        // ETX is not a cancellation control, but a body never legitimately
        // carries one, and a malformed sequence would otherwise discard for the
        // rest of the session. This is the deliberate Ctrl-C way out, so the
        // byte is re-fed for rf to act on.
        if byte == 0x03 {
            endStringSequence()
            feed(byte, &events)
            return
        }
        stringHasBody = true
    }

    private func endStringSequence() {
        inStringSequence = false
        stringSawEsc = false
        stringHasBody = false
    }

    // MARK: - Escape Sequences

    private func feedEscape(_ byte: UInt8, _ events: inout [RFInputEvent]) {
        if escBuffer.count == 1 {
            if Self.isStringIntroducer(byte) {
                resetEscape()
                inStringSequence = true
                stringSawEsc = false
                stringHasBody = false
                stringIntroducer = byte
                return
            }
            // ESC followed by anything but CSI/SS3 is the Escape key; the byte
            // belongs to the next keystroke (rf binds no Alt chords).
            if byte != 0x5B, byte != 0x4F {
                resetEscape()
                flushCluster(&events)
                events.append(.escape)
                feedFresh(byte, &events)
                return
            }
        }

        // Sequence bodies are ASCII. Anything else means the sequence was
        // truncated, so drop it and reprocess the byte.
        guard byte < 0x80 else {
            resetEscape()
            feedFresh(byte, &events)
            return
        }

        escBuffer.append(byte)
        switch tryCompleteEscape() {
        case .incomplete:
            if escBuffer.count > Self.maxEscLength { resetEscape() }
        case .event(let event):
            flushCluster(&events)
            events.append(event)
            resetEscape()
        case .unrecognized:
            resetEscape()
        }
    }

    private func tryCompleteEscape() -> EscapeResult {
        guard escBuffer.count >= 2 else { return .incomplete }

        // CSI: ESC [
        if escBuffer[1] == 0x5B {
            return tryParseCSI()
        }

        // SS3: ESC O
        guard escBuffer.count >= 3 else { return .incomplete }
        switch escBuffer[2] {
        case 0x41: return .event(.arrowUp(shift: false))
        case 0x42: return .event(.arrowDown(shift: false))
        case 0x43: return .event(.arrowRight(shift: false))
        case 0x44: return .event(.arrowLeft(shift: false))
        case 0x48: return .event(.home)
        case 0x46: return .event(.end)
        default: return .unrecognized
        }
    }

    private func tryParseCSI() -> EscapeResult {
        guard escBuffer.count >= 3 else { return .incomplete }
        let lastByte = escBuffer[escBuffer.count - 1]
        let isFinal = (lastByte >= 0x40 && lastByte <= 0x7E)

        // SGR mouse: ESC [ < ...
        if escBuffer[2] == 0x3C {
            guard lastByte == 0x4D || lastByte == 0x6D else {
                return isFinal ? .unrecognized : .incomplete
            }
            if let event = parseSGRMouse() { return .event(event) }
            return .unrecognized
        }

        // Parameters (0x30...0x3F) and intermediates (0x20...0x2F) sort below
        // the final byte, so anything in 0x40...0x7E terminates the sequence.
        guard isFinal else { return .incomplete }

        // Simple 3-byte CSI: ESC [ X
        if escBuffer.count == 3 {
            switch lastByte {
            case 0x41: return .event(.arrowUp(shift: false))
            case 0x42: return .event(.arrowDown(shift: false))
            case 0x43: return .event(.arrowRight(shift: false))
            case 0x44: return .event(.arrowLeft(shift: false))
            case 0x48: return .event(.home)
            case 0x46: return .event(.end)
            case 0x5A: return .event(.shiftTab)
            default: return .unrecognized
            }
        }

        // Parameterized CSI: ESC [ params terminal
        let paramStart = 2
        let paramEnd = escBuffer.count - 1
        let paramBytes = escBuffer[paramStart..<paramEnd]
        let paramStr = String(bytes: paramBytes, encoding: .ascii) ?? ""

        // Shift+arrow: ESC [ 1 ; 2 A/B/C/D
        if lastByte >= 0x41, lastByte <= 0x44, paramStr == "1;2" {
            switch lastByte {
            case 0x41: return .event(.arrowUp(shift: true))
            case 0x42: return .event(.arrowDown(shift: true))
            case 0x43: return .event(.arrowRight(shift: true))
            case 0x44: return .event(.arrowLeft(shift: true))
            default: break
            }
        }

        // Numbered sequences: ESC [ N ~
        if lastByte == 0x7E {
            switch paramStr {
            case "1", "7":  return .event(.home)
            case "3":       return .event(.delete)
            case "4", "8":  return .event(.end)
            case "5":       return .event(.pageUp)
            case "6":       return .event(.pageDown)
            default: break
            }
        }

        return .unrecognized // terminated but not ours
    }

    // MARK: - SGR Mouse

    private func parseSGRMouse() -> RFInputEvent? {
        let lastByte = escBuffer[escBuffer.count - 1]
        let isRelease = lastByte == 0x6D // 'm' = release, 'M' = press

        // Extract params between '<' and terminal byte
        let paramBytes = escBuffer[3..<(escBuffer.count - 1)]
        let paramStr = String(bytes: paramBytes, encoding: .ascii) ?? ""
        let parts = paramStr.split(separator: ";")
        guard parts.count == 3,
              let buttonCode = Int(parts[0]),
              let col1 = Int(parts[1]),
              let row1 = Int(parts[2]) else { return nil }

        // Convert to 0-indexed
        let col = col1 - 1
        let row = row1 - 1

        let isMotion = (buttonCode & 32) != 0
        let isScroll = (buttonCode & 64) != 0
        let baseButton = buttonCode & 3

        let button: RFMouseButton = switch baseButton {
        case 0: .left
        case 1: .middle
        case 2: .right
        default: .none
        }

        if isScroll {
            let direction: RFScrollDirection = baseButton == 0 ? .up : .down
            return .mouseScroll(direction: direction, col: col, row: row)
        }

        if isMotion {
            return .mouseMotion(button: button, col: col, row: row)
        }

        if isRelease {
            return .mouseRelease(button: button, col: col, row: row)
        }

        return .mousePress(button: button, col: col, row: row)
    }
}

#endif
