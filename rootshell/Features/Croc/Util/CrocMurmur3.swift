#if !targetEnvironment(macCatalyst)

import Foundation

/// Murmur3 128-bit hash — port of Go's `twmb/murmur3` used by `kalafut/imohash`.
/// Produces identical output to Go's `murmur3.New128()`.
nonisolated struct Murmur3_128 {

    private static let c1: UInt64 = 0x87c3_7b91_1142_53d5
    private static let c2: UInt64 = 0x4cf5_ad43_2745_937f

    private var h1: UInt64 = 0
    private var h2: UInt64 = 0
    private var length: Int = 0
    private var tail = Data()

    mutating func update(_ data: Data) {
        var input = data
        length += input.count

        // If we have leftover tail bytes, prepend them
        if !tail.isEmpty {
            tail.append(input)
            if tail.count < 16 {
                return  // Still not enough for a full block
            }
            input = tail
            tail = Data()
        }

        // Process 16-byte blocks
        var offset = 0
        while offset + 16 <= input.count {
            let k1 = input.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset, as: UInt64.self)
            }
            let k2 = input.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset + 8, as: UInt64.self)
            }
            processBlock(UInt64(littleEndian: k1), UInt64(littleEndian: k2))
            offset += 16
        }

        // Save remaining bytes as tail
        if offset < input.count {
            tail = input[offset...]
        }
    }

    private mutating func processBlock(_ k1In: UInt64, _ k2In: UInt64) {
        var k1 = k1In
        var k2 = k2In

        k1 = k1 &* Self.c1
        k1 = (k1 << 31) | (k1 >> 33)
        k1 = k1 &* Self.c2
        h1 ^= k1

        h1 = (h1 << 27) | (h1 >> 37)
        h1 = h1 &+ h2
        h1 = h1 &* 5 &+ 0x52dce729

        k2 = k2 &* Self.c2
        k2 = (k2 << 33) | (k2 >> 31)
        k2 = k2 &* Self.c1
        h2 ^= k2

        h2 = (h2 << 31) | (h2 >> 33)
        h2 = h2 &+ h1
        h2 = h2 &* 5 &+ 0x38495ab5
    }

    /// Finalize and return 16-byte hash.
    mutating func finalize() -> Data {
        var k1: UInt64 = 0
        var k2: UInt64 = 0

        // Process remaining tail bytes
        let tailBytes = Array(tail)
        switch tailBytes.count {
        case 15: k2 ^= UInt64(tailBytes[14]) << 48; fallthrough
        case 14: k2 ^= UInt64(tailBytes[13]) << 40; fallthrough
        case 13: k2 ^= UInt64(tailBytes[12]) << 32; fallthrough
        case 12: k2 ^= UInt64(tailBytes[11]) << 24; fallthrough
        case 11: k2 ^= UInt64(tailBytes[10]) << 16; fallthrough
        case 10: k2 ^= UInt64(tailBytes[9]) << 8; fallthrough
        case 9:
            k2 ^= UInt64(tailBytes[8])
            k2 = k2 &* Self.c2
            k2 = (k2 << 33) | (k2 >> 31)
            k2 = k2 &* Self.c1
            h2 ^= k2
            fallthrough
        case 8: k1 ^= UInt64(tailBytes[7]) << 56; fallthrough
        case 7: k1 ^= UInt64(tailBytes[6]) << 48; fallthrough
        case 6: k1 ^= UInt64(tailBytes[5]) << 40; fallthrough
        case 5: k1 ^= UInt64(tailBytes[4]) << 32; fallthrough
        case 4: k1 ^= UInt64(tailBytes[3]) << 24; fallthrough
        case 3: k1 ^= UInt64(tailBytes[2]) << 16; fallthrough
        case 2: k1 ^= UInt64(tailBytes[1]) << 8; fallthrough
        case 1:
            k1 ^= UInt64(tailBytes[0])
            k1 = k1 &* Self.c1
            k1 = (k1 << 31) | (k1 >> 33)
            k1 = k1 &* Self.c2
            h1 ^= k1
        default:
            break
        }

        // Finalization mix
        h1 ^= UInt64(length)
        h2 ^= UInt64(length)

        h1 = h1 &+ h2
        h2 = h2 &+ h1

        h1 = fmix64(h1)
        h2 = fmix64(h2)

        h1 = h1 &+ h2
        h2 = h2 &+ h1

        // Go's murmur3 Sum() outputs h1/h2 in big-endian byte order (murmur128.go:56-64)
        var result = Data(count: 16)
        result.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: h1.bigEndian, toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: h2.bigEndian, toByteOffset: 8, as: UInt64.self)
        }
        return result
    }

    private func fmix64(_ kIn: UInt64) -> UInt64 {
        var k = kIn
        k ^= k >> 33
        k = k &* 0xff51afd7ed558ccd
        k ^= k >> 33
        k = k &* 0xc4ceb9fe1a85ec53
        k ^= k >> 33
        return k
    }
}

#endif
