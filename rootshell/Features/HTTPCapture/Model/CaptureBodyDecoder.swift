//
//  CaptureBodyDecoder.swift
//  rootshell
//
//  Bodies are stored as received (still Content-Encoded); decode for viewing.
//

#if !CHINA_BUILD

import Compression
import Foundation

nonisolated enum CaptureBodyDecoder {
    static let decodedLimit = 64 << 20

    /// Decoded body, or the input unchanged when the encoding is identity,
    /// unknown (zstd), or the data is truncated mid-stream.
    static func decode(_ data: Data, contentEncoding: String?) -> (data: Data, decoded: Bool) {
        let encodings = (contentEncoding ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "identity" }
        guard !encodings.isEmpty else { return (data, false) }
        var current = data
        for encoding in encodings.reversed() {
            let next: Data?
            switch encoding {
            case "gzip", "x-gzip": next = gunzip(current)
            case "deflate": next = inflate(current, zlibWrapped: true) ?? inflate(current, zlibWrapped: false)
            case "br": next = run(current, algorithm: COMPRESSION_BROTLI)
            default: next = nil
            }
            guard let next else { return (data, false) }
            current = next
        }
        return (current, true)
    }

    private static func gunzip(_ data: Data) -> Data? {
        // RFC 1952 header: magic, method, flags, mtime, xfl, os, then optional fields.
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard bytes.count > offset + 2 else { return nil }
            offset += 2 + (Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8))
        }
        if flags & 0x08 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x10 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count else { return nil }
        return run(Data(bytes[offset...]), algorithm: COMPRESSION_ZLIB)
    }

    private static func inflate(_ data: Data, zlibWrapped: Bool) -> Data? {
        if zlibWrapped {
            // Strip the 2-byte zlib header; Apple's ZLIB is raw deflate.
            guard data.count > 2, (UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])) % 31 == 0 else { return nil }
            return run(data.dropFirst(2), algorithm: COMPRESSION_ZLIB)
        }
        return run(data, algorithm: COMPRESSION_ZLIB)
    }

    private static func run(_ input: Data, algorithm: compression_algorithm) -> Data? {
        guard !input.isEmpty else { return Data() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(streamPointer) }

        let chunk = 64 << 10
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var output = Data()
        return input.withUnsafeBytes { raw -> Data? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count
            while true {
                streamPointer.pointee.dst_ptr = dst
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - streamPointer.pointee.dst_size)
                if output.count > decodedLimit { return nil }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if streamPointer.pointee.src_size == 0 && streamPointer.pointee.dst_size == chunk { return output }
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return output.isEmpty ? nil : output
                }
            }
        }
    }
}

#endif
