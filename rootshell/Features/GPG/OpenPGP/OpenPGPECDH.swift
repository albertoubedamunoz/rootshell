//
//  OpenPGPECDH.swift
//  rootshell
//
//  Implements the OpenPGP ECDH KDF (RFC 6637 §8, restated in RFC 9580
//  §13.5) that turns a raw ECDH shared secret into the AES-Wrap KEK
//  used to unwrap the session key. The KDF is a single iteration of
//  X9.63 KDF with a domain-separation string baked in.
//
//  Algorithm:
//    1. Build the "Param" octet string:
//         curve_OID_len  ||  curve_OID
//         || 0x12                       (public-key algorithm ID = ECDH)
//         || 0x03 0x01 hash_id kek_id   (KDF parameters block)
//         || "Anonymous Sender    "     (20-byte UTF-8 padded)
//         || recipient_fingerprint      (20 bytes for v4 keys)
//    2. Compute KDF input = 0x00 0x00 0x00 0x01 || Z || Param
//    3. Apply the hash algorithm to KDF input.
//    4. Truncate the digest to the KEK length implied by `kek_id`
//       (AES-128 → 16, AES-192 → 24, AES-256 → 32).
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto

/// RFC 6637 ECDH KDF; `nonisolated` so off-MainActor crypto can
/// invoke it without re-acquiring MainActor from the project default.
nonisolated enum OpenPGPECDH {

    enum KDFError: Error, LocalizedError, Equatable {
        case unsupportedHash(UInt8)
        case unsupportedKEK(UInt8)
        case digestTooShortForKEK

        var errorDescription: String? {
            switch self {
            case .unsupportedHash(let id):
                return "Unsupported KDF hash algorithm id \(id). Expected 8/9/10 (SHA-256/384/512)."
            case .unsupportedKEK(let id):
                return "Unsupported KEK symmetric algorithm id \(id). Expected 7/8/9 (AES-128/192/256)."
            case .digestTooShortForKEK:
                return "KDF digest is shorter than the requested KEK length."
            }
        }
    }

    /// "Anonymous Sender    " — exactly 20 bytes, the last four padded
    /// with spaces (0x20). This literal is hashed verbatim per the
    /// spec; any change to the bytes silently produces a different
    /// KEK and the wrap will fail to unwrap.
    private static let anonymousSender: [UInt8] = Array("Anonymous Sender    ".utf8)

    /// Derive the AES-Wrap KEK from an ECDH shared secret. Returns
    /// `kekLength(kekAlgo)` bytes.
    ///
    /// - Parameters:
    ///   - sharedSecret: Z, the raw ECDH output. For cv25519/X25519
    ///     this is the 32-byte X25519 shared secret; for P-256 it's
    ///     the 32-byte X coordinate of the ECDH product point.
    ///   - kdfHashAlgo: OpenPGP hash algorithm ID (8/9/10).
    ///   - kekAlgo: OpenPGP symmetric algorithm ID (7/8/9).
    ///   - curveOID: raw OID bytes for the ECDH curve (no
    ///     tag/length prefix), exactly as they appear in the public-
    ///     key packet body.
    ///   - recipientFingerprint: v4 fingerprint of the OpenPGP key the
    ///     message was encrypted to (20 bytes).
    static func deriveKEK(
        sharedSecret: Data,
        kdfHashAlgo: UInt8,
        kekAlgo: UInt8,
        curveOID: Data,
        recipientFingerprint: Data
    ) throws -> Data {
        var param = Data()
        param.append(UInt8(curveOID.count))
        param.append(curveOID)
        param.append(0x12)                  // pub-key algorithm: ECDH
        param.append(0x03)                  // KDF params length
        param.append(0x01)                  // reserved
        param.append(kdfHashAlgo)
        param.append(kekAlgo)
        param.append(contentsOf: anonymousSender)
        param.append(recipientFingerprint)

        return try deriveKEK(
            sharedSecret: sharedSecret,
            kdfHashAlgo: kdfHashAlgo,
            kekAlgo: kekAlgo,
            kdfParams: param
        )
    }

    /// Variant used when the ciphertext includes the fully-built RFC
    /// 6637 KDF parameter string in `(kdf-params ...)`. Using it
    /// verbatim avoids mismatches if local metadata differs from what
    /// the sender used.
    static func deriveKEK(
        sharedSecret: Data,
        kdfHashAlgo: UInt8,
        kekAlgo: UInt8,
        kdfParams: Data
    ) throws -> Data {
        let kekLen = try kekLength(kekAlgo)

        var input = Data()
        input.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        input.append(sharedSecret)
        input.append(kdfParams)

        let digest: Data
        switch kdfHashAlgo {
        case 8:  digest = Data(SHA256.hash(data: input))
        case 9:  digest = Data(SHA384.hash(data: input))
        case 10: digest = Data(SHA512.hash(data: input))
        default: throw KDFError.unsupportedHash(kdfHashAlgo)
        }

        guard digest.count >= kekLen else { throw KDFError.digestTooShortForKEK }
        return digest.prefix(kekLen)
    }

    /// KEK length in bytes for an OpenPGP symmetric algorithm ID.
    static func kekLength(_ kekAlgo: UInt8) throws -> Int {
        switch kekAlgo {
        case 7: return 16   // AES-128
        case 8: return 24   // AES-192
        case 9: return 32   // AES-256
        default: throw KDFError.unsupportedKEK(kekAlgo)
        }
    }

    /// Defaults baked into RFC 9580 algo 25 (X25519 native) and the
    /// values modern cv25519 keygens emit: SHA-256 for the KDF,
    /// AES-128 for the KEK. Used when an enc-val arrives without
    /// explicit `(h ...)`/`(c ...)` parameters, or for the v6 X25519
    /// algorithm that doesn't carry KDF params in the public-key
    /// packet.
    static let defaultHashAlgo: UInt8 = 8       // SHA-256
    static let defaultKEKAlgo: UInt8 = 7        // AES-128
}
