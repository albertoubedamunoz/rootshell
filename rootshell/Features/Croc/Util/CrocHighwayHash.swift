#if !targetEnvironment(macCatalyst)

import Foundation

/// HighwayHash-256 — port of Go's `minio/highwayhash` (generic/reference implementation).
/// Produces identical output to Go's `highwayhash.New(key)` with 32-byte output.
nonisolated struct HighwayHashState {

    private static let init0: [UInt64] = [0xdbe6d5d5fe4cce2f, 0xa4093822299f31d0, 0x13198a2e03707344, 0x243f6a8885a308d3]
    private static let init1: [UInt64] = [0x3bd39e10cb0ef593, 0xc0acf169b5f18a8c, 0xbe5466cf34e90c6c, 0x452821e638d01377]

    // State: v0[0..3], v1[4..7], mul0[8..11], mul1[12..15]
    private var state = [UInt64](repeating: 0, count: 16)
    private var buffer = Data()

    init(key: Data) {
        precondition(key.count == 32)
        var k = [UInt64](repeating: 0, count: 4)
        key.withUnsafeBytes { ptr in
            for i in 0..<4 {
                k[i] = UInt64(littleEndian: ptr.load(fromByteOffset: i * 8, as: UInt64.self))
            }
        }

        for i in 0..<4 { state[8 + i] = Self.init0[i] }   // mul0
        for i in 0..<4 { state[12 + i] = Self.init1[i] }   // mul1
        for i in 0..<4 { state[0 + i] = Self.init0[i] ^ k[i] }  // v0

        let rotK: [UInt64] = [
            (k[0] >> 32) | (k[0] << 32),
            (k[1] >> 32) | (k[1] << 32),
            (k[2] >> 32) | (k[2] << 32),
            (k[3] >> 32) | (k[3] << 32),
        ]
        for i in 0..<4 { state[4 + i] = Self.init1[i] ^ rotK[i] }  // v1
    }

    mutating func update(_ data: Data) {
        buffer.append(data)

        while buffer.count >= 32 {
            processBlock(Array(buffer.prefix(32)))
            buffer = buffer.dropFirst(32)
        }
    }

    /// Finalize and return 32-byte (256-bit) hash.
    /// Matches Go's `digest.Sum()` → `hashBuffer` → `finalize` path.
    mutating func finalize256() -> Data {
        // Process remaining partial block using Go's hashBuffer (highwayhash.go:196-225)
        if !buffer.isEmpty {
            hashBuffer(buffer: Array(buffer), offset: buffer.count)
        }

        // Permute and update (10 rounds for 256-bit — highwayhash_generic.go:160-181)
        for _ in 0..<10 {
            permuteAndUpdate()
        }

        // Build 256-bit output using reduceMod (highwayhash_generic.go:189-197)
        let (h0, h1) = reduceMod(
            state[0] &+ state[8],
            state[1] &+ state[9],
            state[4] &+ state[12],
            state[5] &+ state[13]
        )
        let (h2, h3) = reduceMod(
            state[2] &+ state[10],
            state[3] &+ state[11],
            state[6] &+ state[14],
            state[7] &+ state[15]
        )

        var result = Data(count: 32)
        result.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: h0.littleEndian, toByteOffset: 0, as: UInt64.self)
            ptr.storeBytes(of: h1.littleEndian, toByteOffset: 8, as: UInt64.self)
            ptr.storeBytes(of: h2.littleEndian, toByteOffset: 16, as: UInt64.self)
            ptr.storeBytes(of: h3.littleEndian, toByteOffset: 24, as: UInt64.self)
        }
        return result
    }

    /// Port of Go's hashBuffer (highwayhash.go:196-225).
    /// Mixes the partial block length into state, then constructs a specially-laid-out
    /// 32-byte block from the buffer contents before running update.
    private mutating func hashBuffer(buffer buf: [UInt8], offset: Int) {
        var block = [UInt8](repeating: 0, count: 32)

        // mod32 = (offset << 32) + offset
        let mod32 = (UInt64(offset) << 32) | UInt64(offset)
        for i in 0..<4 {
            state[i] = state[i] &+ mod32
        }

        // Rotate each 32-bit half of v1[i] left by offset bits
        for i in 0..<4 {
            var t0 = UInt32(truncatingIfNeeded: state[4 + i])
            t0 = (t0 << UInt32(offset)) | (t0 >> UInt32(32 - offset))

            var t1 = UInt32(truncatingIfNeeded: state[4 + i] >> 32)
            t1 = (t1 << UInt32(offset)) | (t1 >> UInt32(32 - offset))

            state[4 + i] = (UInt64(t1) << 32) | UInt64(t0)
        }

        // Construct the block from buffer contents
        let mod4 = offset & 3
        let remain = offset - mod4

        for i in 0..<remain {
            block[i] = buf[i]
        }

        if offset >= 16 {
            // Copy last 4 bytes to block[28..31]
            block[28] = buf[offset - 4]
            block[29] = buf[offset - 3]
            block[30] = buf[offset - 2]
            block[31] = buf[offset - 1]
        } else if mod4 != 0 {
            // Pack up to 3 remaining bytes into a uint32 at block[16..19]
            var last: UInt32 = UInt32(buf[remain])
            last += UInt32(buf[remain + mod4 >> 1]) << 8
            last += UInt32(buf[offset - 1]) << 16
            block[16] = UInt8(last & 0xFF)
            block[17] = UInt8((last >> 8) & 0xFF)
            block[18] = UInt8((last >> 16) & 0xFF)
            block[19] = UInt8((last >> 24) & 0xFF)
        }

        processBlock(block)
    }

    /// Permute v0 and feed back through update (highwayhash_generic.go:160-181).
    private mutating func permuteAndUpdate() {
        var perm = [UInt64](repeating: 0, count: 4)
        perm[0] = (state[2] >> 32) | (state[2] << 32)
        perm[1] = (state[3] >> 32) | (state[3] << 32)
        perm[2] = (state[0] >> 32) | (state[0] << 32)
        perm[3] = (state[1] >> 32) | (state[1] << 32)

        var tmp = [UInt8](repeating: 0, count: 32)
        for i in 0..<4 {
            let v = perm[i].littleEndian
            withUnsafeBytes(of: v) { src in
                for j in 0..<8 {
                    tmp[i * 8 + j] = src[j]
                }
            }
        }
        processBlock(tmp)
    }

    // MARK: - Core

    private mutating func processBlock(_ msg: [UInt8]) {
        precondition(msg.count >= 32)
        var m = [UInt64](repeating: 0, count: 4)
        msg.withUnsafeBytes { ptr in
            for i in 0..<4 {
                m[i] = UInt64(littleEndian: ptr.load(fromByteOffset: i * 8, as: UInt64.self))
            }
        }

        // Update loop — matches highwayhash_generic.go updateGeneric
        for i in 0..<4 {
            state[4 + i] = state[4 + i] &+ m[i] &+ state[8 + i]
            state[8 + i] ^= UInt64(UInt32(truncatingIfNeeded: state[4 + i])) &* (state[0 + i] >> 32)
            state[0 + i] = state[0 + i] &+ state[12 + i]
            state[12 + i] ^= UInt64(UInt32(truncatingIfNeeded: state[0 + i])) &* (state[4 + i] >> 32)
        }

        // zipperMerge(v1[0], v1[1]) -> v0[0], v0[1]
        let (zm00, zm01) = zipperMerge(state[4 + 0], state[4 + 1])
        state[0 + 0] = state[0 + 0] &+ zm00
        state[0 + 1] = state[0 + 1] &+ zm01

        // zipperMerge(v1[2], v1[3]) -> v0[2], v0[3]
        let (zm02, zm03) = zipperMerge(state[4 + 2], state[4 + 3])
        state[0 + 2] = state[0 + 2] &+ zm02
        state[0 + 3] = state[0 + 3] &+ zm03

        // zipperMerge(v0[0], v0[1]) -> v1[0], v1[1]
        let (zm10, zm11) = zipperMerge(state[0 + 0], state[0 + 1])
        state[4 + 0] = state[4 + 0] &+ zm10
        state[4 + 1] = state[4 + 1] &+ zm11

        // zipperMerge(v0[2], v0[3]) -> v1[2], v1[3]
        let (zm12, zm13) = zipperMerge(state[0 + 2], state[0 + 3])
        state[4 + 2] = state[4 + 2] &+ zm12
        state[4 + 3] = state[4 + 3] &+ zm13
    }

    private func zipperMerge(_ v0: UInt64, _ v1: UInt64) -> (UInt64, UInt64) {
        var res: UInt64 = v0 & (0xff << (2 * 8))
        var res2: UInt64 = (v0 & (0xff << (7 * 8))) &+ (v1 & (0xff << (2 * 8)))
        res = res &+ ((v1 & (0xff << (7 * 8))) >> 8)
        res2 = res2 &+ ((v0 & (0xff << (6 * 8))) >> 8)
        res = res &+ (((v0 & (0xff << (5 * 8))) &+ (v1 & (0xff << (6 * 8)))) >> 16)
        res2 = res2 &+ ((v1 & (0xff << (5 * 8))) >> 16)
        res = res &+ (((v0 & (0xff << (3 * 8))) &+ (v1 & (0xff << (4 * 8)))) >> 24)
        res2 = res2 &+ (((v1 & (0xff << (3 * 8))) &+ (v0 & (0xff << (4 * 8)))) >> 24)
        res = res &+ ((v0 & (0xff << (1 * 8))) << 32)
        res2 = res2 &+ ((v1 & 0xff) << 48)
        res = res &+ (v0 << 56)
        res2 = res2 &+ ((v1 & (0xff << (1 * 8))) << 24)
        return (res, res2)
    }

    private func reduceMod(_ v0: UInt64, _ v1: UInt64, _ v2In: UInt64, _ v3In: UInt64) -> (UInt64, UInt64) {
        var v2 = v2In
        var v3 = v3In & 0x3FFFFFFFFFFFFFFF

        var r0 = v2
        var r1 = v3

        v3 = (v3 << 1) | (v2 >> 63)
        v2 = v2 << 1
        r1 = (r1 << 2) | (r0 >> 62)
        r0 = r0 << 2

        r0 ^= v0 ^ v2
        r1 ^= v1 ^ v3
        return (r0, r1)
    }

}

#endif
