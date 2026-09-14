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
                // DA (c), DSR/CPR (n, R), window reports (t), DECRPM (y).
                guard [0x63, 0x6e, 0x52, 0x74, 0x79].contains(bytes[end]) else { return false }
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
