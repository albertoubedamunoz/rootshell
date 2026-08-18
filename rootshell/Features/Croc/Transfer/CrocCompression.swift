#if !targetEnvironment(macCatalyst)

import Foundation
import zlib

/// Raw DEFLATE compression matching Go's `compress.Compress`.
///
/// Go uses `flate.NewWriter(..., flate.HuffmanOnly)`, which produces raw DEFLATE
/// with Huffman-only strategy. This uses the same zlib primitives as the working
/// mosh compression path, but with croc's raw-DEFLATE settings.
nonisolated enum CrocCompression {

    static func compress(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -15,
            8,
            Z_HUFFMAN_ONLY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return input }
        defer { deflateEnd(&stream) }

        let maxOutputSize = deflateBound(&stream, UInt(input.count))
        var outputBuffer = [UInt8](repeating: 0, count: Int(maxOutputSize))

        let compressedSize: Int?
        compressedSize = input.withUnsafeBytes { inputPtr in
            outputBuffer.withUnsafeMutableBufferPointer { outputPtr -> Int? in
                guard let inputBase = inputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let outputBase = outputPtr.baseAddress else {
                    return nil
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputBase)
                stream.avail_in = UInt32(input.count)
                stream.next_out = outputBase
                stream.avail_out = UInt32(outputPtr.count)

                let result = deflate(&stream, Z_FINISH)
                guard result == Z_STREAM_END else {
                    return nil
                }

                return Int(stream.total_out)
            }
        }

        guard let compressedSize else { return input }
        return Data(outputBuffer.prefix(compressedSize))
    }

    static func decompress(_ input: Data) -> Data {
        guard !input.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return input }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = max(4096, input.count * 2)
        var didFinish = false
        var didFail = false

        input.withUnsafeBytes { inputPtr in
            guard let inputBase = inputPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                didFail = true
                return
            }

            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = UInt32(input.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)

            while true {
                let produced = buffer.withUnsafeMutableBufferPointer { outputPtr -> Int in
                    guard let outputBase = outputPtr.baseAddress else {
                        didFail = true
                        return 0
                    }

                    stream.next_out = outputBase
                    stream.avail_out = UInt32(outputPtr.count)

                    let result = inflate(&stream, Z_NO_FLUSH)
                    if result == Z_STREAM_END {
                        didFinish = true
                    } else if result != Z_OK {
                        didFail = true
                    }

                    return outputPtr.count - Int(stream.avail_out)
                }

                if produced > 0 {
                    output.append(contentsOf: buffer.prefix(produced))
                }

                if didFail || didFinish {
                    break
                }
                if stream.avail_in == 0 && produced == 0 {
                    break
                }
            }
        }

        guard didFinish && !didFail else { return input }
        return output
    }
}

#endif
