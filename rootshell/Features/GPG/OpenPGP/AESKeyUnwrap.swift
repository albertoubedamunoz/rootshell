//
//  AESKeyUnwrap.swift
//  rootshell
//
//  Thin wrapper over CommonCrypto's `CCSymmetricKeyUnwrap` for the
//  RFC 3394 AES Key Wrap algorithm. OpenPGP ECDH uses AESWRAP to
//  protect the session key inside an `enc-val` ciphertext (RFC 9580
//  §13.5 / RFC 6637 §8) — we unwrap with the KEK derived from the
//  ECDH shared secret + KDF.
//
//  CryptoKit does NOT expose AES Key Wrap; CommonCrypto does. Both
//  ship with the OS so there's no third-party dependency.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import CommonCrypto

/// Pure RFC 3394 AES Key Unwrap; `nonisolated` so the off-MainActor
/// `GPGDecryptor` / `SSHKeyGPGBridge` callers can invoke it without
/// re-acquiring MainActor isolation from the project default.
nonisolated enum AESKeyUnwrap {

    enum UnwrapError: Error, LocalizedError, Equatable {
        case invalidKEKLength(Int)
        case invalidWrappedLength(Int)
        case unwrapFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidKEKLength(let n):
                return "AES Key Wrap requires a 16/24/32-byte KEK; got \(n)."
            case .invalidWrappedLength(let n):
                return "AES Key Wrap input must be a multiple of 8 bytes >= 16; got \(n)."
            case .unwrapFailed(let status):
                return "AES Key Wrap unwrap failed (CC status \(status))."
            }
        }
    }

    /// Unwrap `wrapped` using `kek` as the wrapping key. Returns the
    /// plaintext key/message bytes. KEK must be 16, 24, or 32 bytes
    /// (AES-128/192/256). Wrapped input must be at least 16 bytes and
    /// a multiple of 8.
    static func unwrap(_ wrapped: Data, kek: Data) throws -> Data {
        guard kek.count == 16 || kek.count == 24 || kek.count == 32 else {
            throw UnwrapError.invalidKEKLength(kek.count)
        }
        guard wrapped.count >= 16, wrapped.count % 8 == 0 else {
            throw UnwrapError.invalidWrappedLength(wrapped.count)
        }

        // Output is exactly 8 bytes shorter than input.
        var outLen = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        var out = Data(count: outLen)

        let status: Int32 = out.withUnsafeMutableBytes { outBuf in
            wrapped.withUnsafeBytes { wrappedBuf in
                kek.withUnsafeBytes { kekBuf in
                    // Default IV per RFC 3394 §2.2.3.1: A6A6A6A6A6A6A6A6.
                    var iv: [UInt8] = [0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6, 0xA6]
                    return iv.withUnsafeMutableBufferPointer { ivBuf in
                        return CCSymmetricKeyUnwrap(
                            CCWrappingAlgorithm(kCCWRAPAES),
                            ivBuf.baseAddress, ivBuf.count,
                            kekBuf.baseAddress, kekBuf.count,
                            wrappedBuf.baseAddress, wrappedBuf.count,
                            outBuf.baseAddress, &outLen
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw UnwrapError.unwrapFailed(status)
        }
        // CommonCrypto reports the actual unwrapped length in outLen —
        // trim the trailing zero-pad that the initial Data(count:)
        // allocation included.
        if out.count != outLen {
            out = out.prefix(outLen)
        }
        return out
    }
}
