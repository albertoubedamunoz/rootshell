//
//  HerdrReplyFilter.swift
//  rootshell
//
//  Tells a terminal's automatic replies (device attributes, cursor
//  position, window reports, OSC colour and DCS capability answers) apart
//  from user input on Ghostty's response pipe. Several clients share one
//  pane on a protocol 2 server, and only the query authority may answer.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated enum HerdrReplyFilter {

    /// True when every sequence in `data` is a report a terminal emits on
    /// its own. Mixed chunks count as input: a dropped keystroke is worse
    /// than a duplicated reply.
    static func isAutomaticReply(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1b, index + 1 < bytes.count else { return false }
            switch bytes[index + 1] {
            case 0x5b: // CSI
                guard let end = csiEnd(bytes, from: index + 2) else { return false }
                // Focus-in/out (CSI I/O) are emitted on focus changes and
                // when snapshot replay enables mode 1004. They are not user
                // input: forwarding them as input would reclaim geometry.
                let focusReport = end == index + 2 && [0x49, 0x4f].contains(bytes[end])
                // DA (c), DSR/CPR (n, R), window reports (t), DECRPM (y).
                guard focusReport || [0x63, 0x6e, 0x52, 0x74, 0x79].contains(bytes[end]) else { return false }
                index = end + 1
            case 0x5d: // OSC: BEL or ST terminated
                guard let end = stringEnd(bytes, from: index + 2, allowBell: true) else { return false }
                index = end
            case 0x50, 0x5f, 0x5e, 0x58: // DCS, APC, PM, SOS: ST terminated
                guard let end = stringEnd(bytes, from: index + 2, allowBell: false) else { return false }
                index = end
            default:
                return false
            }
        }
        return true
    }

    /// Offset where a sequence left unfinished at the end of `bytes` starts
    /// (a bare ESC, a CSI without its final byte, a string sequence without
    /// its terminator), or nil when every sequence is whole. The response
    /// pipe delivers arbitrary read sizes, so a reply can straddle two reads.
    static func incompleteTailStart(_ bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1b else { index += 1; continue }
            guard index + 1 < bytes.count else { return index }
            switch bytes[index + 1] {
            case 0x5b:
                guard let end = csiEnd(bytes, from: index + 2) else { return index }
                index = end + 1
            case 0x5d:
                guard let end = stringEnd(bytes, from: index + 2, allowBell: true) else { return index }
                index = end
            case 0x50, 0x5f, 0x5e, 0x58:
                guard let end = stringEnd(bytes, from: index + 2, allowBell: false) else { return index }
                index = end
            default:
                // ESC + one byte (alt-modified key, single-char sequence).
                index += 2
            }
        }
        return nil
    }

    /// Index of the CSI final byte (0x40...0x7e) after parameter and
    /// intermediate bytes, or nil when the sequence is cut short.
    private static func csiEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if (0x40...0x7e).contains(byte) { return index }
            guard (0x20...0x3f).contains(byte) else { return nil }
            index += 1
        }
        return nil
    }

    /// Index just past the terminator of a string sequence.
    private static func stringEnd(_ bytes: [UInt8], from start: Int, allowBell: Bool) -> Int? {
        var index = start
        while index < bytes.count {
            if allowBell, bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x1b {
                guard index + 1 < bytes.count, bytes[index + 1] == 0x5c else { return nil }
                return index + 2
            }
            if bytes[index] == 0x9c { return index + 1 }
            index += 1
        }
        return nil
    }
}

/// An authority change must cross the same parser and response pipe as the
/// queries it governs. Main-actor receipt of terminal.authority is too early:
/// output (and its replies) may still be waiting behind a layout or snapshot.
nonisolated struct HerdrQueryAuthority {
    // Read-only unknown DECRQM modes, below the mobile fence's ID range.
    static func marker(answersQueries: Bool) -> Data {
        Data("\u{1b}[?\(answersQueries ? 15999 : 15998)$p".utf8)
    }

    private static let enabledReply = Data("\u{1b}[?15999;0$y".utf8)
    private static let disabledReply = Data("\u{1b}[?15998;0$y".utf8)
    private(set) var answersQueries = true

    struct Segment {
        let bytes: Data
        let answersQueries: Bool
    }

    /// Called after response reassembly. Preserve the boundaries even when
    /// old replies, the marker, and new replies arrive in one pipe read.
    mutating func consume(_ data: Data) -> [Segment] {
        var remaining = data[...]
        var result: [Segment] = []
        while !remaining.isEmpty {
            let enabled = remaining.range(of: Self.enabledReply)
            let disabled = remaining.range(of: Self.disabledReply)
            let next: (Range<Data.Index>, Bool)?
            switch (enabled, disabled) {
            case let (.some(on), .some(off)):
                next = on.lowerBound < off.lowerBound ? (on, true) : (off, false)
            case let (.some(on), .none): next = (on, true)
            case let (.none, .some(off)): next = (off, false)
            case (.none, .none): next = nil
            }
            guard let (range, value) = next else {
                result.append(Segment(bytes: Data(remaining), answersQueries: answersQueries))
                break
            }
            if range.lowerBound > remaining.startIndex {
                result.append(Segment(bytes: Data(remaining[..<range.lowerBound]), answersQueries: answersQueries))
            }
            answersQueries = value
            remaining = remaining[range.upperBound...]
        }
        return result
    }
}

/// Local DECRQM probes acknowledge that the parser reached a point in the
/// output stream. Unknown private modes are read-only and echo the mode
/// number, unlike an untagged DSR reply that could acknowledge an old probe.
/// Replies are consumed here even after cancellation; they never reach herdr.
nonisolated struct HerdrParserFence {
    // Ghostty stores private mode numbers in 15 bits.
    private var nextID = 16_000
    private var issued: Set<Int> = []
    private var acknowledgedIDs: [Int] = []
    private var carry = Data()

    mutating func issue() -> (id: Int, bytes: Data)? {
        // Live resizing can issue many fences on a long-lived surface. Only
        // reuse IDs whose reply was consumed; a timed-out/cancelled probe
        // remains issued so its late reply cannot confirm a new boundary.
        let id: Int
        if nextID <= 32_767 {
            id = nextID
            nextID += 1
        } else if let acknowledged = acknowledgedIDs.popLast() {
            id = acknowledged
        } else {
            return nil
        }
        issued.insert(id)
        return (id, Data("\u{1b}[?\(id)$p".utf8))
    }

    mutating func consume(_ data: Data) -> (forward: Data, acknowledged: [Int]) {
        guard !issued.isEmpty || !carry.isEmpty else { return (data, []) }
        let bytes = Array(carry + data)
        carry.removeAll(keepingCapacity: true)
        var forward = Data()
        var acknowledged: [Int] = []
        var i = 0
        while i < bytes.count {
            let start = i
            guard bytes[i] == 0x1b else { forward.append(bytes[i]); i += 1; continue }
            let prefix: [UInt8] = [0x1b, 0x5b, 0x3f]
            var j = 0
            while j < prefix.count, i + j < bytes.count, bytes[i + j] == prefix[j] { j += 1 }
            if i + j == bytes.count, j < prefix.count {
                carry.append(contentsOf: bytes[start...]); break
            }
            guard j == prefix.count else { forward.append(bytes[i]); i += 1; continue }
            i += j
            while i < bytes.count, (0x30...0x39).contains(bytes[i]), i - start < 10 { i += 1 }
            let numberEnd = i
            let suffix: [UInt8] = [0x3b, 0x30, 0x24, 0x79] // ;0$y
            j = 0
            while j < suffix.count, i + j < bytes.count, bytes[i + j] == suffix[j] { j += 1 }
            if i + j == bytes.count, j < suffix.count, i - start < 10 {
                carry.append(contentsOf: bytes[start...]); break
            }
            if j == suffix.count,
               let id = Int(String(decoding: bytes[(start + 3)..<numberEnd], as: UTF8.self)),
               issued.remove(id) != nil {
                acknowledged.append(id)
                acknowledgedIDs.append(id)
                i += j
            } else {
                forward.append(contentsOf: bytes[start..<i])
            }
        }
        return (forward, acknowledged)
    }
}
