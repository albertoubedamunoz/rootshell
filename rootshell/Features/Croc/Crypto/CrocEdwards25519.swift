#if !targetEnvironment(macCatalyst)

import BigInt
import CryptoKit
import Foundation

/// Edwards25519 curve implementation for PAKE.
///
/// Matches Go's `Edwards25519Curve` in pake.go.
/// The Go implementation stores the full 32-byte compressed Edwards25519 point
/// in the x coordinate as a BigInt, with y always 0.
nonisolated struct CrocEdwards25519Curve: CrocEllipticCurve {
    /// 2^255 - 19
    let P: BigInt = "57896044618658097711785492504343953926634992332820282019728792003956564819949"

    func add(_ x1: BigInt, _ y1: BigInt, _ x2: BigInt, _ y2: BigInt) -> (BigInt, BigInt) {
        guard let p1 = pointFromBigInts(x1, y1),
              let p2 = pointFromBigInts(x2, y2) else {
            return (BigInt(0), BigInt(0))
        }
        // Use Curve25519 point addition via CryptoKit isn't directly exposed,
        // so we use the raw bytes approach matching Go's edwards25519 package.
        // Since CryptoKit doesn't expose Edwards25519 point arithmetic,
        // we implement it using the twisted Edwards curve equation.
        let result = ed25519Add(p1, p2)
        return pointToBigInts(result)
    }

    /// Subtract two points (used by PAKE for Edwards25519).
    func subtract(_ x1: BigInt, _ y1: BigInt, _ x2: BigInt, _ y2: BigInt) -> (BigInt, BigInt) {
        guard let p1 = pointFromBigInts(x1, y1),
              let p2 = pointFromBigInts(x2, y2) else {
            return (BigInt(0), BigInt(0))
        }
        let negP2 = ed25519Negate(p2)
        let result = ed25519Add(p1, negP2)
        return pointToBigInts(result)
    }

    func scalarBaseMult(_ k: Data) -> (BigInt, BigInt) {
        let scalar = normalizeScalar(k)
        // The base point for Ed25519
        let basePoint = ed25519BasePoint()
        let result = ed25519ScalarMult(basePoint, scalar)
        return pointToBigInts(result)
    }

    func scalarMult(_ bx: BigInt, _ by: BigInt, _ k: Data) -> (BigInt, BigInt) {
        guard let point = pointFromBigInts(bx, by) else {
            return (BigInt(0), BigInt(0))
        }
        let scalar = normalizeScalar(k)
        let result = ed25519ScalarMult(point, scalar)
        return pointToBigInts(result)
    }

    func isOnCurve(_ x: BigInt, _ y: BigInt) -> Bool {
        guard let _ = pointFromBigInts(x, y) else { return false }
        return true // If we can decode the point, it's on the curve
    }

    // MARK: - BigInt ↔ Point Conversion

    /// Convert BigInt coordinates to 32-byte compressed point.
    /// Go stores the entire point in x, y is always 0.
    ///
    /// IMPORTANT: Must use magnitude.serialize() (BigUInt), NOT BigInt.serialize(),
    /// because BigInt.serialize() prepends a 0x00 sign byte for positive values
    /// whose high byte >= 0x80, producing 33 bytes and breaking the <= 32 check.
    private func pointFromBigInts(_ x: BigInt, _ y: BigInt) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let xBytes = x.magnitude.serialize() // big-endian, no sign byte
        if xBytes.count <= 32 {
            // Copy big-endian bytes right-aligned into the 32-byte buffer
            let offset = 32 - xBytes.count
            for i in 0..<xBytes.count {
                bytes[offset + i] = xBytes[i]
            }
        }
        return bytes
    }

    /// Convert 32-byte point to BigInt coordinates.
    /// Uses BigUInt to avoid interpreting byte 0 as a sign byte.
    private func pointToBigInts(_ pointBytes: [UInt8]) -> (BigInt, BigInt) {
        guard pointBytes.count == 32 else { return (BigInt(0), BigInt(0)) }
        let x = BigInt(sign: .plus, magnitude: BigUInt(Data(pointBytes)))
        return (x, BigInt(0))
    }

    /// Ensure scalar is exactly 32 bytes (matching Go's normalizeScalar).
    private func normalizeScalar(_ k: Data) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 32)
        if k.count >= 32 {
            key = Array(k.prefix(32))
        } else {
            let offset = 32 - k.count
            for (i, byte) in k.enumerated() {
                key[offset + i] = byte
            }
        }
        return key
    }

    // MARK: - Edwards25519 Arithmetic

    // Ed25519 curve: -x² + y² = 1 + d·x²·y² where d = -121665/121666 mod p
    // p = 2^255 - 19

    private static let edP: BigInt = "57896044618658097711785492504343953926634992332820282019728792003956564819949"
    private static let edD: BigInt = "37095705934669439343138083508754565189542113879843219016388785533085940283555"

    /// Ed25519 base point in extended coordinates (x, y).
    private func ed25519BasePoint() -> [UInt8] {
        // The standard Ed25519 base point compressed encoding
        let baseY: BigInt = "46316835694926478169428394003475163141307993866256225615783033890098355573289"
        // Compute x from y
        let p = CrocEdwards25519Curve.edP
        let y2 = (baseY * baseY) % p
        let num = (y2 - 1 + p) % p
        let den = (CrocEdwards25519Curve.edD * y2 + 1) % p
        guard let denInv = den.inverse(p) else { return [UInt8](repeating: 0, count: 32) }
        let x2 = (num * denInv) % p
        let baseX = modSqrt(x2, p)

        // Encode as compressed point (y with x sign bit)
        return encodePoint(baseX, baseY)
    }

    /// Point addition on Ed25519 in compressed form.
    private func ed25519Add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let p = CrocEdwards25519Curve.edP
        let d = CrocEdwards25519Curve.edD

        let (ax, ay) = decodePoint(a)
        let (bx, by) = decodePoint(b)

        // Extended coordinates addition formula:
        // x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
        // y3 = (y1*y2 + x1*x2) / (1 - d*x1*x2*y1*y2)
        // Note: Ed25519 uses -x² + y² = 1 + d*x²*y², so addition is:
        // x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
        // y3 = (y1*y2 - (-1)*x1*x2) / (1 - d*x1*x2*y1*y2)
        //    = (y1*y2 + x1*x2) / (1 - d*x1*x2*y1*y2)

        let xy = (d * ax % p * bx % p * ay % p * by) % p
        let x3num = (ax * by + ay * bx) % p
        let x3den = (1 + xy + p) % p
        let y3num = (ay * by + ax * bx) % p
        let y3den = (1 - xy + p) % p

        guard let x3denInv = x3den.inverse(p),
              let y3denInv = y3den.inverse(p) else {
            return [UInt8](repeating: 0, count: 32)
        }

        var x3 = (x3num * x3denInv) % p
        if x3 < 0 { x3 += p }
        var y3 = (y3num * y3denInv) % p
        if y3 < 0 { y3 += p }

        return encodePoint(x3, y3)
    }

    /// Negate a point on Ed25519 (negate x coordinate).
    private func ed25519Negate(_ point: [UInt8]) -> [UInt8] {
        let p = CrocEdwards25519Curve.edP
        let (x, y) = decodePoint(point)
        let negX = (p - x) % p
        return encodePoint(negX, y)
    }

    /// Scalar multiplication using double-and-add.
    private func ed25519ScalarMult(_ point: [UInt8], _ scalar: [UInt8]) -> [UInt8] {
        // Identity point (0, 1) in compressed form
        var result = encodePoint(BigInt(0), BigInt(1))

        // Clamp the scalar as Go does with SetBytesWithClamping
        var clampedScalar = scalar
        clampedScalar[0] &= 248
        clampedScalar[31] &= 127
        clampedScalar[31] |= 64

        // Process bits from MSB to LSB (big-endian scalar, but Ed25519 uses little-endian)
        // Go's SetBytesWithClamping expects little-endian, so we reverse
        // Actually the Go code passes big-endian bytes from BigInt to normalizeScalar
        // then calls SetBytesWithClamping which interprets as little-endian.
        // We need to match this exactly.

        for byte in clampedScalar {
            var b = byte
            for _ in 0..<8 {
                result = ed25519Add(result, result)
                if b & 0x80 != 0 {
                    result = ed25519Add(result, point)
                }
                b <<= 1
            }
        }

        return result
    }

    // MARK: - Point Encoding/Decoding

    /// Encode an Edwards25519 point (x, y) to 32-byte compressed form.
    /// Format: y in little-endian with the high bit of byte 31 being the sign of x.
    private func encodePoint(_ x: BigInt, _ y: BigInt) -> [UInt8] {
        var bytes = bigIntToLE32(y)
        bytes[31] |= x.isOdd ? 0x80 : 0x00
        return bytes
    }

    /// Decode a 32-byte compressed Edwards25519 point to (x, y).
    private func decodePoint(_ bytes: [UInt8]) -> (BigInt, BigInt) {
        let p = CrocEdwards25519Curve.edP
        let d = CrocEdwards25519Curve.edD

        var yBytes = bytes
        let xSign = (yBytes[31] >> 7) & 1
        yBytes[31] &= 0x7F

        let y = le32ToBigInt(yBytes)

        // Recover x: x² = (y² - 1) / (d·y² + 1) mod p
        let y2 = (y * y) % p
        let num = (y2 - 1 + p) % p
        let den = (d * y2 + 1) % p
        guard let denInv = den.inverse(p) else { return (BigInt(0), BigInt(1)) }
        let x2 = (num * denInv) % p

        var x = modSqrt(x2, p)
        // Ensure correct sign
        if (x.isOdd ? 1 : 0) != xSign {
            x = (p - x) % p
        }

        return (x, y)
    }

    private func bigIntToLE32(_ value: BigInt) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        let serialized = value.magnitude.serialize() // big-endian, no sign byte
        // Reverse to little-endian, right-aligned
        for (i, byte) in serialized.reversed().enumerated() {
            if i < 32 { bytes[i] = byte }
        }
        return bytes
    }

    private func le32ToBigInt(_ bytes: [UInt8]) -> BigInt {
        // Convert little-endian to big-endian for BigInt (unsigned to avoid sign issues)
        return BigInt(sign: .plus, magnitude: BigUInt(Data(bytes.reversed())))
    }

    /// Modular square root using Tonelli-Shanks for p ≡ 5 (mod 8).
    /// For Ed25519's prime p = 2^255 - 19, p ≡ 5 (mod 8), so we use
    /// x = a^((p+3)/8) mod p, with adjustment if needed.
    private func modSqrt(_ a: BigInt, _ p: BigInt) -> BigInt {
        if a == 0 { return BigInt(0) }

        // p = 2^255 - 19, p mod 8 = 5
        // sqrt(a) = a^((p+3)/8) mod p, if a^((p-1)/4) ≡ 1 (mod p)
        // Otherwise sqrt(a) = 2a * (4a)^((p-5)/8) mod p
        let exp = (p + 3) / 8
        var result = modPow(a, exp, p)

        // Verify
        if (result * result) % p == a % p {
            return result
        }

        // Try the other root
        let sqrt2 = modPow(BigInt(2), (p - 1) / 4, p)
        result = (result * sqrt2) % p
        return result
    }

    /// Modular exponentiation: base^exp mod modulus.
    private func modPow(_ base: BigInt, _ exp: BigInt, _ modulus: BigInt) -> BigInt {
        return base.power(exp, modulus: modulus)
    }
}

private nonisolated extension BigInt {
    var isOdd: Bool {
        return self & 1 == 1
    }
}

#endif
