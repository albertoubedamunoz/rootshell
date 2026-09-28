//
//  ByteSearch.swift
//  rootshell
//
//  memchr-backed byte and marker search for hot byte-stream paths, so
//  filters can jump between special bytes and copy the runs in between.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated extension UnsafeRawBufferPointer {
    /// Offset of the first `byte` in `range`.
    func firstOffset(of byte: UInt8, in range: Range<Int>) -> Int? {
        guard let base = baseAddress, !range.isEmpty,
              let hit = memchr(base + range.lowerBound, Int32(byte), range.count) else { return nil }
        return UnsafeRawPointer(hit) - base
    }

    /// Offset of the first `pattern` at or after `start`.
    func firstOffset(of pattern: [UInt8], from start: Int = 0) -> Int? {
        guard let first = pattern.first else { return nil }
        var cursor = start
        while count - cursor >= pattern.count, let hit = firstOffset(of: first, in: cursor..<count) {
            guard count - hit >= pattern.count else { return nil }
            let match = pattern.withUnsafeBytes { memcmp(baseAddress! + hit, $0.baseAddress!, pattern.count) == 0 }
            if match { return hit }
            cursor = hit + 1
        }
        return nil
    }

    /// Offset of the last `byte` before `end`. Darwin has no memrchr, so
    /// this skips 8-byte words that cannot contain it.
    func lastOffset(of byte: UInt8, before end: Int) -> Int? {
        let ones: UInt64 = 0x0101_0101_0101_0101
        let splat = ones &* UInt64(byte)
        var i = end
        while i >= 8 {
            let word = loadUnaligned(fromByteOffset: i - 8, as: UInt64.self) ^ splat
            if (word &- ones) & ~word & (ones << 7) != 0 { break }
            i -= 8
        }
        while i > 0 {
            i -= 1
            if self[i] == byte { return i }
        }
        return nil
    }
}

nonisolated extension Data {
    /// Offset from the first byte (not `startIndex`) of the first `pattern`
    /// at or after `start`.
    func firstOffset(of pattern: [UInt8], from start: Int = 0) -> Int? {
        withUnsafeBytes { $0.firstOffset(of: pattern, from: start) }
    }
}

/// Splits a byte stream into newline-terminated lines. Consumed lines only
/// advance a cursor, and bytes already searched are never searched again.
nonisolated struct NewlineFramer {
    private static let newline: [UInt8] = [0x0A]
    private var buffer = Data()
    private var start = 0
    private var scanned = 0

    /// Bytes received but not yet returned as a line.
    var bufferedCount: Int { buffer.count - start }

    mutating func append(_ chunk: Data) {
        if start > 0 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + start)
            scanned -= start
            start = 0
        }
        buffer.append(chunk)
    }

    /// The next complete line without its newline, or nil until one arrives.
    mutating func nextLine() -> Data? {
        guard let newline = buffer.firstOffset(of: Self.newline, from: scanned) else {
            scanned = buffer.count
            return nil
        }
        let base = buffer.startIndex
        let line = buffer.subdata(in: base + start..<base + newline)
        start = newline + 1
        scanned = start
        return line
    }
}
