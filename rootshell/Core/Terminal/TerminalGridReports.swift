// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation

/// Replies to our CSI 18 t probes come from the terminal parser, unlike
/// ghostty_surface_size, which reports a resize before the IO thread applies it.
nonisolated struct TerminalGridReports {
    struct Grid: Equatable, Sendable {
        let cols: Int
        let rows: Int
    }

    var pending = 0
    private var carry = Data()

    mutating func consume(_ data: Data) -> (forward: Data, grids: [Grid]) {
        guard pending > 0 || !carry.isEmpty else { return (data, []) }
        let bytes = Array(carry + data)
        carry.removeAll(keepingCapacity: true)
        var forward = Data()
        var grids: [Grid] = []
        var index = 0
        while index < bytes.count {
            let start = index
            guard pending > 0, bytes[index] == 0x1b else {
                forward.append(bytes[index]); index += 1
                continue
            }
            index += 1
            if index == bytes.count { carry.append(contentsOf: bytes[start...]); break }
            guard bytes[index] == 0x5b else { forward.append(0x1b); continue }
            index += 1
            while index < bytes.count, index - start < 64,
                  (0x30...0x3f).contains(bytes[index]) { index += 1 }
            if index == bytes.count, index - start < 64 {
                carry.append(contentsOf: bytes[start...]); break
            }
            if index < bytes.count, bytes[index] == 0x74 {
                let params = String(decoding: bytes[(start + 2)..<index], as: UTF8.self)
                    .split(separator: ";", omittingEmptySubsequences: false)
                if params.count == 3, params[0] == "8",
                   let rows = Int(params[1]), let cols = Int(params[2]), rows > 0, cols > 0 {
                    grids.append(Grid(cols: cols, rows: rows))
                    pending -= 1
                    index += 1
                    continue
                }
            }
            forward.append(contentsOf: bytes[start..<index])
        }
        return (forward, grids)
    }
}

/// Byte-stream boundaries for VT output split across reads.
nonisolated enum TerminalSequenceBoundary {
    /// Parser state inside a sequence left unfinished at the end of a chunk.
    private enum Open: Equatable, Sendable {
        /// After ESC and any transparent controls.
        case escape
        /// CSI, or ESC with intermediates, before its final byte.
        case sequence(csi: Bool)
        /// OSC DCS APC PM SOS body; `escape` when it ended on a possible ST.
        case string(bel: Bool, escape: Bool)
    }

    private enum Step: Equatable {
        /// Back at ground from this offset, which may be an ESC starting the next sequence.
        case closed(Int)
        case open(Open)
    }

    /// Holds back the unfinished sequence at the end of a stream so only
    /// whole ones go out. The next chunk resumes the held parser state, so a
    /// sequence split across many chunks is scanned once, not per chunk.
    struct Carry: Sendable {
        private var held = Data()
        /// Nil while `held` is empty or truncated UTF-8 (at most 3 bytes).
        private var state: Open?

        /// Appends `bytes` and returns what can go out now. A held sequence
        /// longer than `limit` goes out as is.
        mutating func split(appending bytes: Data, limit: Int) -> Data? {
            guard !bytes.isEmpty else { return nil }
            let resumeAt = held.count
            if held.isEmpty { held = bytes } else { held.append(bytes) }
            let tail: (start: Int, state: Open?)? = held.withUnsafeBytes { buffer in
                var ground = 0
                if let state {
                    switch TerminalSequenceBoundary.resume(state, buffer, at: resumeAt) {
                    case .open(let next): return (0, next)
                    case .closed(let end): ground = end
                    }
                }
                return TerminalSequenceBoundary.openTail(buffer, ground: ground)
            }
            guard let tail, held.count - tail.start <= limit else {
                let out = held
                held = Data()
                state = nil
                return out
            }
            state = tail.state
            guard tail.start > 0 else { return nil }
            let split = held.startIndex + tail.start
            let out = held.subdata(in: held.startIndex..<split)
            held = held.subdata(in: split..<held.endIndex)
            return out
        }
    }

    /// Where a sequence left unfinished at the end starts (ESC without its
    /// final byte, an unterminated string, or truncated UTF-8) and the
    /// parser state there, nil for UTF-8. `ground` is known to be outside
    /// any sequence.
    private static func openTail(_ bytes: UnsafeRawBufferPointer, ground: Int = 0) -> (start: Int, state: Open?)? {
        let count = bytes.count
        // Every ESC restarts the scan below, or is the ESC of an ST, which
        // scans the same from there. So start at the last ESC, or the one
        // before when it is the final byte and may end an open string.
        let scan = UnsafeRawBufferPointer(rebasing: bytes[ground...])
        var i = scan.lastOffset(of: 0x1b, before: scan.count).map { ground + $0 } ?? count
        if i == count - 1, let earlier = scan.lastOffset(of: 0x1b, before: i - ground) { i = ground + earlier }
        while i < count {
            guard bytes[i] == 0x1b else { i += 1; continue }
            switch resume(.escape, bytes, at: i + 1) {
            case .closed(let end): i = end
            case .open(let state): return (i, state)
            }
        }
        return incompleteUTF8Start(bytes).map { ($0, nil) }
    }

    /// Runs the parser from `state` over `bytes[start...]`. A string's
    /// pending ESC may close at `start - 1`.
    private static func resume(_ state: Open, _ bytes: UnsafeRawBufferPointer, at start: Int) -> Step {
        var state = state
        var j = start
        while j < bytes.count {
            let byte = bytes[j]
            switch state {
            case .escape:
                // Executable C0 controls and DEL pass through escape state.
                // CAN and SUB abort any sequence; a second ESC restarts one.
                // These mirror the parser's "anywhere" transitions.
                if isTransparentControl(byte) { break }
                switch byte {
                case 0x1b: return .closed(j)
                case 0x18, 0x1a: return .closed(j + 1)
                case 0x5b: state = .sequence(csi: true)
                case 0x20...0x2f: state = .sequence(csi: false) // ESC with intermediates, up to a final byte
                case 0x5d: state = .string(bel: true, escape: false) // OSC: until ST or BEL
                case 0x50, 0x5f, 0x5e, 0x58: state = .string(bel: false, escape: false) // DCS APC PM SOS: until ST
                default: return .closed(j + 1)
                }
            case .sequence(let csi):
                if byte == 0x1b { return .closed(j) }
                if byte == 0x18 || byte == 0x1a { return .closed(j + 1) }
                if csi ? (0x40...0x7e).contains(byte) : (0x30...0x7e).contains(byte) { return .closed(j + 1) }
            case .string(_, escape: true):
                // ST ends the string; any other ESC starts a new sequence.
                return .closed(byte == 0x5c ? j + 1 : j - 1)
            case .string(let bel, escape: false):
                if bel, byte == 0x07 { return .closed(j + 1) }
                if byte == 0x18 || byte == 0x1a { return .closed(j + 1) }
                if byte == 0x1b { state = .string(bel: bel, escape: true) }
            }
            j += 1
        }
        return .open(state)
    }

    private static func isTransparentControl(_ byte: UInt8) -> Bool {
        byte < 0x18 || byte == 0x19 || (0x1c...0x1f).contains(byte) || byte == 0x7f
    }

    static func incompleteUTF8Start(_ bytes: UnsafeRawBufferPointer) -> Int? {
        let count = bytes.count
        guard count > 0 else { return nil }
        for back in 1...min(3, count) {
            let index = count - back
            let byte = bytes[index]
            if byte & 0xc0 == 0x80 { continue }
            let needed: Int
            switch byte {
            case 0xc0...0xdf: needed = 2
            case 0xe0...0xef: needed = 3
            case 0xf0...0xf7: needed = 4
            default: return nil
            }
            return back < needed ? index : nil
        }
        return nil
    }
}

/// A preview may paint only after the parser acknowledges the latest resize.
/// Replies to probes sent before that resize cannot satisfy the new request,
/// including when a quick open/close returns to an earlier grid size.
nonisolated struct TerminalPreviewGrid {
    typealias Grid = TerminalGridReports.Grid
    private var wanted: Grid?
    private var confirmed: Grid?
    private var reports = TerminalGridReports()
    private var staleReplies = 0
    private var nextProbeAt: TimeInterval = 0

    var isReady: Bool { wanted != nil && confirmed == wanted }

    mutating func resize(cols: Int, rows: Int) {
        let grid = Grid(cols: cols, rows: rows)
        guard wanted != grid else { return }
        wanted = grid
        confirmed = nil
        staleReplies = reports.pending
        nextProbeAt = 0
    }

    mutating func consume(_ data: Data) {
        for grid in reports.consume(data).grids {
            if staleReplies > 0 { staleReplies -= 1 }
            else { confirmed = grid }
        }
    }

    mutating func probe(at now: TimeInterval) -> String? {
        guard wanted != nil, !isReady, now >= nextProbeAt else { return nil }
        reports.pending += 1
        nextProbeAt = now + 0.1
        return "\u{18}\u{1b}[18t"
    }
}
