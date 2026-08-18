#if !targetEnvironment(macCatalyst)

import BigInt
import CryptoKit
import Foundation

/// PAKE (Password-Authenticated Key Exchange) implementation.
/// Port of Go's `github.com/schollz/pake/v3` — must produce wire-compatible output.
///
/// Protocol (SPAKE2 variant):
/// - Role 0 (receiver/A): computes X = ScalarMult(U, pw) + ScalarBaseMult(α), sends X
/// - Role 1 (sender/B): receives X, computes Y = ScalarMult(V, pw) + ScalarBaseMult(α), sends Y
/// - Both derive Z and session key K = SHA256(pw || X.x || X.y || Y.x || Y.y || Z.x || Z.y)
nonisolated final class CrocPAKE: @unchecked Sendable {

    // MARK: - Public (serialized over wire as JSON)

    let role: Int
    private(set) var Uu: BigInt  // U point x
    private(set) var Uv: BigInt  // U point y
    private(set) var Vu: BigInt  // V point x
    private(set) var Vv: BigInt  // V point y
    private(set) var Xu: BigInt  // X point x (role 0 sends this)
    private(set) var Xv: BigInt  // X point y
    private(set) var Yu: BigInt  // Y point x (role 1 sends this)
    private(set) var Yv: BigInt  // Y point y

    // MARK: - Private

    private let curve: CrocEllipticCurve
    private let pw: Data
    private var Vpwu: BigInt = 0
    private var Vpwv: BigInt = 0
    private var Upwu: BigInt = 0
    private var Upwv: BigInt = 0
    private var alpha: Data = Data()
    private var alphaU: BigInt = 0
    private var alphaV: BigInt = 0
    private var Zu: BigInt = 0
    private var Zv: BigInt = 0
    private(set) var sessionKey: Data?
    private let curveName: String

    // MARK: - Initialization

    /// Initialize PAKE with a weak passphrase, role (0 or 1), and curve name.
    /// Matches Go's `pake.InitCurve(pw, role, curve)`.
    init(pw: Data, role: Int, curve curveName: String) throws {
        let (curve, Ux, Uy, Vx, Vy) = try CrocCurveFactory.initCurve(curveName)
        self.curve = curve
        self.curveName = curveName
        self.pw = pw
        self.role = role >= 1 ? 1 : 0
        self.Uu = Ux
        self.Uv = Uy
        self.Vu = Vx
        self.Vv = Vy
        self.Xu = 0
        self.Xv = 0
        self.Yu = 0
        self.Yv = 0

        guard curve.isOnCurve(Ux, Uy) else {
            throw CrocError.pakeInitFailed("U point not on curve")
        }
        guard curve.isOnCurve(Vx, Vy) else {
            throw CrocError.pakeInitFailed("V point not on curve")
        }

        if self.role == 0 {
            // Role 0 (A): compute X = ScalarMult(U, pw) + ScalarBaseMult(α)
            (Vpwu, Vpwv) = curve.scalarMult(Vu, Vv, pw)
            (Upwu, Upwv) = curve.scalarMult(Uu, Uv, pw)

            alpha = Data(count: 32)
            alpha.withUnsafeMutableBytes { ptr in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
            }
            (alphaU, alphaV) = curve.scalarBaseMult(alpha)
            (Xu, Xv) = curve.add(Upwu, Upwv, alphaU, alphaV)
        }
    }

    // MARK: - Wire Serialization

    /// Serialize public variables to JSON bytes (matches Go's `Pake.Bytes()`).
    /// Go serializes `*big.Int` as bare JSON numbers (decimal, no quotes).
    /// Standard JSONEncoder can't produce bare numbers for arbitrary-precision BigInt,
    /// so we build the JSON string manually.
    func bytes() throws -> Data {
        let json = PAKEPublicJSON.encode(
            role: role,
            Uu: Uu, Uv: Uv, Vu: Vu, Vv: Vv,
            Xu: Xu, Xv: Xv, Yu: Yu, Yv: Yv
        )
        guard let data = json.data(using: .utf8) else {
            throw CrocError.protocolError("failed to serialize PAKE")
        }
        return data
    }

    /// Update with the other party's PAKE bytes.
    /// Matches Go's `Pake.Update(qBytes)`.
    func update(_ qBytes: Data) throws {
        guard let jsonString = String(data: qBytes, encoding: .utf8) else {
            throw CrocError.pakeExchangeFailed("invalid UTF-8")
        }
        let q = try PAKEPublicJSON.decode(jsonString)

        guard self.role != q.Role else {
            throw CrocError.sameRole
        }

        if role == 1 {
            // Role 1 (B): receives X from A
            Xu = q.Xu
            Xv = q.Xv

            guard curve.isOnCurve(Xu, Xv) else {
                throw CrocError.pakeExchangeFailed("X values not on curve")
            }

            // Compute Y
            (Vpwu, Vpwv) = curve.scalarMult(Vu, Vv, pw)
            (Upwu, Upwv) = curve.scalarMult(Uu, Uv, pw)

            alpha = Data(count: 32)
            alpha.withUnsafeMutableBytes { ptr in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, ptr.baseAddress!)
            }
            (alphaU, alphaV) = curve.scalarBaseMult(alpha)
            (Yu, Yv) = curve.add(Vpwu, Vpwv, alphaU, alphaV)

            // Compute Z = ScalarMult(X - Upw, α)
            if let ed25519 = curve as? CrocEdwards25519Curve {
                (Zu, Zv) = ed25519.subtract(Xu, Xv, Upwu, Upwv)
            } else {
                // Negate Upwv: -y mod P
                var negUpwv = -Upwv % curve.P
                if negUpwv < 0 { negUpwv += curve.P }
                (Zu, Zv) = curve.add(Xu, Xv, Upwu, negUpwv)
            }
            (Zu, Zv) = curve.scalarMult(Zu, Zv, alpha)

            // K = SHA256(pw || X.x.Bytes || X.y.Bytes || Y.x.Bytes || Y.y.Bytes || Z.x.Bytes || Z.y.Bytes)
            sessionKey = computeSessionKey()

        } else {
            // Role 0 (A): receives Y from B
            Yu = q.Yu
            Yv = q.Yv

            guard curve.isOnCurve(Yu, Yv) else {
                throw CrocError.pakeExchangeFailed("Y values not on curve")
            }

            // Compute Z = ScalarMult(Y - Vpw, α)
            if let ed25519 = curve as? CrocEdwards25519Curve {
                (Zu, Zv) = ed25519.subtract(Yu, Yv, Vpwu, Vpwv)
            } else {
                var negVpwv = -Vpwv % curve.P
                if negVpwv < 0 { negVpwv += curve.P }
                (Zu, Zv) = curve.add(Yu, Yv, Vpwu, negVpwv)
            }
            (Zu, Zv) = curve.scalarMult(Zu, Zv, alpha)

            // K = SHA256(pw || X.x.Bytes || X.y.Bytes || Y.x.Bytes || Y.y.Bytes || Z.x.Bytes || Z.y.Bytes)
            sessionKey = computeSessionKey()
        }
    }

    /// Whether a session key has been derived.
    var hasSessionKey: Bool { sessionKey != nil }

    // MARK: - Session Key Derivation

    /// Compute K = SHA256(pw || Xu.Bytes || Xv.Bytes || Yu.Bytes || Yv.Bytes || Zu.Bytes || Zv.Bytes)
    /// Uses Go's `big.Int.Bytes()` which is big-endian with no leading zeros.
    private func computeSessionKey() -> Data {
        var hasher = SHA256()
        hasher.update(data: pw)
        hasher.update(data: bigIntBytes(Xu))
        hasher.update(data: bigIntBytes(Xv))
        hasher.update(data: bigIntBytes(Yu))
        hasher.update(data: bigIntBytes(Yv))
        hasher.update(data: bigIntBytes(Zu))
        hasher.update(data: bigIntBytes(Zv))
        let digest = hasher.finalize()
        return Data(digest)
    }

    /// Convert BigInt to bytes matching Go's `big.Int.Bytes()`.
    /// Go returns big-endian bytes with no leading zeros and NO sign byte.
    /// For zero, returns empty slice.
    ///
    /// IMPORTANT: BigInt.serialize() prepends a sign byte (0x00 for positive).
    /// We must use magnitude (BigUInt) serialize() which has no sign byte.
    private func bigIntBytes(_ value: BigInt) -> Data {
        if value == 0 { return Data() }
        return value.magnitude.serialize()
    }
}

// MARK: - Wire Format (Manual JSON for BigInt Compatibility)

/// Manual JSON serialization/deserialization for PAKE public data.
///
/// Go's `encoding/json` marshals `*big.Int` as bare JSON numbers (decimal digits, no quotes).
/// Swift's JSONEncoder can't produce bare numbers for arbitrary-precision BigInt values
/// (it would truncate to Double precision). So we build/parse JSON strings manually.
///
/// Go field names use unicode subscript characters: Uᵤ, Uᵥ, Vᵤ, Vᵥ, Xᵤ, Xᵥ, Yᵤ, Yᵥ
private nonisolated enum PAKEPublicJSON {

    // Go's unicode field names
    static let keyUu = "U\u{1D64}"  // Uᵤ
    static let keyUv = "U\u{1D65}"  // Uᵥ
    static let keyVu = "V\u{1D64}"  // Vᵤ
    static let keyVv = "V\u{1D65}"  // Vᵥ
    static let keyXu = "X\u{1D64}"  // Xᵤ
    static let keyXv = "X\u{1D65}"  // Xᵥ
    static let keyYu = "Y\u{1D64}"  // Yᵤ
    static let keyYv = "Y\u{1D65}"  // Yᵥ

    /// Encode to JSON string with BigInt values as bare JSON numbers.
    /// Go omits zero BigInt fields (omitempty on *big.Int only omits nil, not zero —
    /// actually Go's big.Int always includes the field since it's a pointer).
    /// Go marshals *big.Int pointers; if the pointer is non-nil the value is always included.
    static func encode(
        role: Int,
        Uu: BigInt, Uv: BigInt, Vu: BigInt, Vv: BigInt,
        Xu: BigInt, Xv: BigInt, Yu: BigInt, Yv: BigInt
    ) -> String {
        // Go's json.Marshal produces sorted keys alphabetically.
        // For Go's Pake struct, the fields are in declaration order.
        // Go's encoding/json marshals struct fields in declaration order, not alphabetically.
        // Declaration order: Role, Uᵤ, Uᵥ, Vᵤ, Vᵥ, Xᵤ, Xᵥ, Yᵤ, Yᵥ
        var parts: [String] = []
        parts.append("\"Role\":\(role)")
        parts.append("\"\(keyUu)\":\(Uu.description)")
        parts.append("\"\(keyUv)\":\(Uv.description)")
        parts.append("\"\(keyVu)\":\(Vu.description)")
        parts.append("\"\(keyVv)\":\(Vv.description)")
        // Xᵤ, Xᵥ: only include if non-zero (Go omits zero *big.Int — actually,
        // Go's Pake.Public() always copies the pointer, and json omits nil pointers.
        // Since the public fields are always set (even if zero), Go includes them.
        // However, for Role 1 before Update, Xᵤ/Xᵥ are nil pointers → omitted.
        // After Update, they're set. We match by always including them.
        parts.append("\"\(keyXu)\":\(Xu.description)")
        parts.append("\"\(keyXv)\":\(Xv.description)")
        parts.append("\"\(keyYu)\":\(Yu.description)")
        parts.append("\"\(keyYv)\":\(Yv.description)")
        return "{\(parts.joined(separator: ","))}"
    }

    /// Decoded PAKE public data.
    struct Decoded {
        let Role: Int
        let Uu: BigInt, Uv: BigInt
        let Vu: BigInt, Vv: BigInt
        let Xu: BigInt, Xv: BigInt
        let Yu: BigInt, Yv: BigInt
    }

    /// Decode from JSON string, parsing BigInt values from bare JSON numbers.
    ///
    /// IMPORTANT: We cannot use JSONSerialization here because it parses large numbers
    /// through NSDecimalNumber which only has ~38 digits of precision. P-256 coordinates
    /// can be 77 digits. Instead, we extract raw number strings directly from the JSON text
    /// using string matching to preserve full precision.
    static func decode(_ json: String) throws -> Decoded {
        func extractValue(forKey key: String) -> String {
            // Find "key": followed by the value (a number, null, or 0)
            // JSON keys use unicode subscript chars, so we search for the escaped key
            let searchKey = "\"\(key)\":"
            guard let keyRange = json.range(of: searchKey) else { return "0" }

            let afterKey = json[keyRange.upperBound...]
            let trimmed = afterKey.drop(while: { $0 == " " || $0 == "\t" })

            // Check for null
            if trimmed.hasPrefix("null") { return "0" }

            // Extract the number: digits and optional leading minus
            var numStr = ""
            for ch in trimmed {
                if ch == "-" || ch.isNumber {
                    numStr.append(ch)
                } else {
                    break
                }
            }
            return numStr.isEmpty ? "0" : numStr
        }

        func bigInt(forKey key: String) -> BigInt {
            let str = extractValue(forKey: key)
            return BigInt(str, radix: 10) ?? BigInt(0)
        }

        let roleStr = extractValue(forKey: "Role")
        guard let role = Int(roleStr) else {
            throw CrocError.pakeExchangeFailed("missing Role field")
        }

        return Decoded(
            Role: role,
            Uu: bigInt(forKey: keyUu), Uv: bigInt(forKey: keyUv),
            Vu: bigInt(forKey: keyVu), Vv: bigInt(forKey: keyVv),
            Xu: bigInt(forKey: keyXu), Xv: bigInt(forKey: keyXv),
            Yu: bigInt(forKey: keyYu), Yv: bigInt(forKey: keyYv)
        )
    }
}

#endif
