//
//  MoshProtocolCompression.swift
//  rootshell
//
//  Shared zlib helpers for Mosh transport instructions
//

import Foundation
import zlib

enum MoshProtocolCompression {
    static func zlibCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw MoshError.compressionError(reason: "deflateInit failed: \(initResult)")
        }
        defer { deflateEnd(&stream) }

        let maxOutputSize = deflateBound(&stream, UInt(data.count))
        var outputBuffer = [UInt8](repeating: 0, count: Int(maxOutputSize))

        let compressedSize: Int = try data.withUnsafeBytes { inputPtr in
            try outputBuffer.withUnsafeMutableBufferPointer { outputPtr -> Int in
                guard let inputBase = inputPtr.baseAddress,
                      let outputBase = outputPtr.baseAddress else {
                    throw MoshError.compressionError(reason: "Invalid buffer")
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(data.count)
                stream.next_out = outputBase
                stream.avail_out = UInt32(outputPtr.count)

                let deflateResult = deflate(&stream, Z_FINISH)
                guard deflateResult == Z_STREAM_END else {
                    throw MoshError.compressionError(reason: "deflate failed: \(deflateResult)")
                }

                return Int(stream.total_out)
            }
        }

        return Data(outputBuffer.prefix(compressedSize))
    }

    static func zlibDecompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initResult = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw MoshError.compressionError(reason: "inflateInit failed: \(initResult)")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = max(4096, data.count * 2)

        try data.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.baseAddress else {
                throw MoshError.compressionError(reason: "Invalid buffer")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = UInt32(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)

            var done = false
            while true {
                let produced: Int = try buffer.withUnsafeMutableBytes { outputPtr in
                    guard let outputBase = outputPtr.baseAddress else {
                        throw MoshError.compressionError(reason: "Invalid buffer")
                    }
                    stream.next_out = outputBase.assumingMemoryBound(to: UInt8.self)
                    stream.avail_out = UInt32(outputPtr.count)

                    let inflateResult = inflate(&stream, Z_NO_FLUSH)
                    if inflateResult == Z_STREAM_END {
                        done = true
                        return outputPtr.count - Int(stream.avail_out)
                    }
                    guard inflateResult == Z_OK else {
                        throw MoshError.compressionError(reason: "inflate failed: \(inflateResult)")
                    }
                    return outputPtr.count - Int(stream.avail_out)
                }

                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }

                if done {
                    break
                }
                if stream.avail_out > 0 && stream.avail_in == 0 {
                    break
                }
                if stream.avail_in == 0 && produced == 0 {
                    break
                }
            }

            if !done {
                throw MoshError.compressionError(reason: "inflate failed: incomplete stream")
            }
        }

        return output
    }
}
