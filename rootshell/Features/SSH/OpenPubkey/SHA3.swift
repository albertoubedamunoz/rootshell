import Foundation

/// Pure-Swift SHA3-256 (FIPS 202).
///
/// CryptoKit has no SHA-3 family, and the OpenPubkey protocol requires
/// SHA3-256 for the CIC commitment hash (the OIDC nonce). This implements
/// Keccak-f[1600] with the FIPS-202 domain padding (0x06 ... 0x80), which is
/// NOT the legacy Keccak padding (0x01).
nonisolated enum SHA3 {
    /// SHA3-256: rate 136 bytes, output 32 bytes.
    static func sha3_256(_ message: Data) -> Data {
        let rate = 136
        var state = [UInt64](repeating: 0, count: 25)

        // Absorb full blocks, then the padded final block.
        var block = [UInt8](repeating: 0, count: rate)
        var offset = 0
        let bytes = [UInt8](message)
        while message.count - offset >= rate {
            for i in 0..<rate { block[i] = bytes[offset + i] }
            absorb(&state, block, rate: rate)
            offset += rate
        }
        var final = [UInt8](repeating: 0, count: rate)
        let remaining = message.count - offset
        for i in 0..<remaining { final[i] = bytes[offset + i] }
        final[remaining] = 0x06
        final[rate - 1] |= 0x80
        absorb(&state, final, rate: rate)

        // Squeeze 32 bytes (single block, 32 < rate).
        var out = Data(capacity: 32)
        for lane in 0..<4 {
            var v = state[lane]
            for _ in 0..<8 {
                out.append(UInt8(truncatingIfNeeded: v))
                v >>= 8
            }
        }
        return out
    }

    private static func absorb(_ state: inout [UInt64], _ block: [UInt8], rate: Int) {
        for lane in 0..<(rate / 8) {
            var v: UInt64 = 0
            for b in 0..<8 {
                v |= UInt64(block[lane * 8 + b]) << (8 * UInt64(b))
            }
            state[lane] ^= v
        }
        keccakF1600(&state)
    }

    private static let roundConstants: [UInt64] = [
        0x0000_0000_0000_0001, 0x0000_0000_0000_8082, 0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
        0x0000_0000_0000_808B, 0x0000_0000_8000_0001, 0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
        0x0000_0000_0000_008A, 0x0000_0000_0000_0088, 0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
        0x0000_0000_8000_808B, 0x8000_0000_0000_008B, 0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
        0x8000_0000_0000_8002, 0x8000_0000_0000_0080, 0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
        0x8000_0000_8000_8081, 0x8000_0000_0000_8080, 0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
    ]

    // rho rotation offsets indexed by lane (x + 5y)
    private static let rho: [UInt64] = [
        0, 1, 62, 28, 27,
        36, 44, 6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21, 8,
        18, 2, 61, 56, 14,
    ]

    private static func keccakF1600(_ a: inout [UInt64]) {
        for round in 0..<24 {
            // theta
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20]
            }
            for x in 0..<5 {
                let d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1)
                for y in 0..<5 {
                    a[x + 5 * y] ^= d
                }
            }

            // rho + pi
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(a[x + 5 * y], rho[x + 5 * y])
                }
            }

            // chi
            for y in 0..<5 {
                for x in 0..<5 {
                    a[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }

            // iota
            a[0] ^= roundConstants[round]
        }
    }

    @inline(__always)
    private static func rotl(_ v: UInt64, _ n: UInt64) -> UInt64 {
        n == 0 ? v : (v << n) | (v >> (64 - n))
    }
}
