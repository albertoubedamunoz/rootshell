//
//  GPGSigner.swift
//  rootshell
//
//  Translates "I have a parsed OpenPGP subkey and a precomputed digest
//  the remote wants signed" into bytes formatted as an Assuan `PKSIGN`
//  reply payload (per ``CanonicalSExpression``).
//
//  Coverage today:
//    * Ed25519 (algo 22 legacy + algo 27 native) via `Curve25519.Signing`.
//      Standard OpenPGP-EdDSA semantics: the digest sent by `SETHASH` is
//      passed as the EdDSA "message" — Ed25519 will internally re-hash
//      with SHA-512, which is what real gpg-agent does too.
//    * ECDSA P-256 via Security.framework's `SecKeyCreateSignature`. We
//      go through SecKey rather than swift-crypto/CryptoKit because the
//      public ECDSA API for those frameworks won't sign a raw digest
//      that didn't come out of one of its own `Digest` types — we have
//      arbitrary digest bytes from the remote's `SETHASH`.
//
//  Coverage NOT shipped this checkpoint:
//    * RSA. Citadel's `Insecure.RSA.PrivateKey.signature(for:hashAlgorithm:)`
//      hashes its input rather than accepting a precomputed digest, and
//      `SecKey` requires a full PKCS#1 RSAPrivateKey blob with CRT
//      parameters (dp, dq, qInv) that the OpenPGP key format doesn't
//      carry directly — computing them from (p, q, d) needs a bignum
//      library we don't have on hand. The cleanest fix is to add a
//      `signaturePrecomputed(...)` entry point to the local Citadel
//      fork during the streamlocal-forwarding work; that's the same
//      fork the rest of the GPG plumbing already depends on, so it
//      lands together.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto
import Citadel
import Security

nonisolated enum GPGSignError: Error, LocalizedError, Equatable {
    case unsupportedAlgorithm(String)
    case malformedKey
    case malformedSignature
    case secKeyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let name):
            return "Algorithm \(name) is not supported by the GPG signer yet."
        case .malformedKey:
            return "Stored GPG secret material is malformed."
        case .malformedSignature:
            return "Failed to encode the signature for the requested algorithm."
        case .secKeyFailed(let detail):
            return "ECDSA signing failed: \(detail)"
        }
    }
}

/// Pure cryptographic signer; `nonisolated` so callers (notably the
/// `@MainActor` agent) can hop the CPU-bound RSA / EdDSA / ECDSA math
/// off the UI thread via `Task.detached`.
nonisolated enum GPGSigner {

    /// Produce an Assuan `PKSIGN` reply payload (a canonical
    /// S-expression `(sig-val …)`). Caller is responsible for
    /// wrapping the bytes in a `D`-line and following them with `OK`.
    static func sign(
        subkey: OpenPGPSubkey,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) throws -> Data {
        let raw = try signRaw(subkey: subkey, hash: hash, hashAlgorithm: hashAlgorithm)
        switch raw {
        case .ed25519(let r, let s):
            return CanonicalSExpression.eddsaSigVal(r: r, s: s)
        case .ecdsa(let r, let s):
            return CanonicalSExpression.ecdsaSigVal(r: r, s: s)
        case .rsa(let s):
            return CanonicalSExpression.rsaSigVal(s: s)
        }
    }

    /// Sign `hash` with `subkey` and return the raw signature
    /// primitives (as ``SSHKeyGPGBridge/RawSignature``). Used by the
    /// public-key export path which wraps the raw values in an
    /// OpenPGP v4 signature packet rather than an Assuan S-expression.
    static func signRaw(
        subkey: OpenPGPSubkey,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) throws -> SSHKeyGPGBridge.RawSignature {
        switch subkey.algorithm {
        case .eddsaLegacy, .ed25519Native:
            return try signRawEd25519(subkey: subkey, hash: hash)
        case .ecdsa(let curve):
            switch curve {
            case .p256:
                return try signRawECDSAP256(subkey: subkey, hash: hash)
            case .ed25519, .cv25519:
                // Parser rejects this combo, but be defensive.
                throw GPGSignError.unsupportedAlgorithm("ECDSA on non-P-256 curve")
            }
        case .ecdh:
            // ECDH subkeys are encryption-only — they have no signing
            // semantics. Surface this clearly so the user understands
            // why the operation failed.
            throw GPGSignError.unsupportedAlgorithm("ECDH (encryption-only key)")
        case .x25519Native:
            throw GPGSignError.unsupportedAlgorithm("X25519 (encryption-only key)")
        case .rsa:
            return try signRawRSA(subkey: subkey, hash: hash, hashAlgorithm: hashAlgorithm)
        case .unsupported(let id):
            throw GPGSignError.unsupportedAlgorithm("algorithm id \(id)")
        }
    }

    // MARK: - Ed25519

    private static func signRawEd25519(subkey: OpenPGPSubkey, hash: Data) throws -> SSHKeyGPGBridge.RawSignature {
        guard case .ec(let scalar) = subkey.secretMaterial else { throw GPGSignError.malformedKey }
        // Ed25519 expects a 32-byte seed. OpenPGP MPI decoding may have
        // trimmed leading zeros — pad on the left to 32 bytes.
        let seed = leftPad(scalar, toCount: 32)
        guard seed.count == 32 else { throw GPGSignError.malformedKey }

        let key: Curve25519.Signing.PrivateKey
        do {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        } catch {
            throw GPGSignError.malformedKey
        }

        let signature = try key.signature(for: hash)
        // Ed25519 signatures are exactly 64 bytes: r || s, each 32.
        guard signature.count == 64 else { throw GPGSignError.malformedSignature }
        let r = signature.prefix(32)
        let s = signature.suffix(32)
        return .ed25519(r: Data(r), s: Data(s))
    }

    // MARK: - RSA

    private static func signRawRSA(
        subkey: OpenPGPSubkey,
        hash: Data,
        hashAlgorithm: GPGHashAlgorithm
    ) throws -> SSHKeyGPGBridge.RawSignature {
        guard case .rsa(let n, let e) = subkey.publicMaterial,
              case .rsa(let d, _, _, _) = subkey.secretMaterial else {
            throw GPGSignError.malformedKey
        }

        let citadelHash: Insecure.RSA.PrivateKey.PrecomputedHashAlgorithm
        switch hashAlgorithm {
        case .sha1: citadelHash = .sha1
        case .sha224: citadelHash = .sha224
        case .sha256: citadelHash = .sha256
        case .sha384: citadelHash = .sha384
        case .sha512: citadelHash = .sha512
        case .unknown(let id):
            throw GPGSignError.unsupportedAlgorithm("hash id \(id) for RSA")
        }

        let key = Insecure.RSA.PrivateKey(
            modulus: n,
            publicExponent: e,
            privateExponent: d
        )

        let signature: Insecure.RSA.Signature
        do {
            signature = try key.signature(forPrecomputedDigest: hash, hashAlgorithm: citadelHash)
        } catch {
            throw GPGSignError.secKeyFailed("RSA sign failed: \(error.localizedDescription)")
        }

        // Pad the signature to the modulus byte length so the remote
        // sees a fixed-width MPI on the receiving end. The modulus is
        // big-endian, possibly with a leading zero that we should strip
        // before measuring its length.
        let modulusByteLength = Self.stripLeadingZeros(n).count
        let padded = leftPad(signature.rawRepresentation, toCount: modulusByteLength)
        return .rsa(s: padded)
    }

    private static func stripLeadingZeros(_ data: Data) -> Data {
        var slice = data
        while slice.count > 1, slice.first == 0x00 {
            slice = slice.subdata(in: slice.index(after: slice.startIndex)..<slice.endIndex)
        }
        return slice
    }

    // MARK: - ECDSA P-256

    private static func signRawECDSAP256(subkey: OpenPGPSubkey, hash: Data) throws -> SSHKeyGPGBridge.RawSignature {
        guard case .ec(let q) = subkey.publicMaterial,
              case .ec(let d) = subkey.secretMaterial else {
            throw GPGSignError.malformedKey
        }

        // Apple's SecKey for an EC private key wants:
        //   0x04 || X || Y || scalar
        // where X, Y, scalar are each 32 bytes (P-256), big-endian.
        // OpenPGP gives us `q` as 0x04 || X || Y (65 bytes) and `d` as
        // a possibly-trimmed scalar.
        guard q.count == 65, q[q.startIndex] == 0x04 else { throw GPGSignError.malformedKey }
        let scalar = leftPad(d, toCount: 32)
        guard scalar.count == 32 else { throw GPGSignError.malformedKey }

        var keyBytes = Data()
        keyBytes.append(q)
        keyBytes.append(scalar)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(keyBytes as CFData, attributes as CFDictionary, &error) else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GPGSignError.secKeyFailed("SecKeyCreateWithData: \(detail)")
        }

        // The digest signing variant skips re-hashing — exactly what we want.
        // We always claim SHA-256 because P-256 is curve-locked to a
        // 32-byte digest; if the remote sent a different-length digest
        // we'd have rejected it back at SETHASH.
        guard let sigCFData = SecKeyCreateSignature(
            secKey,
            .ecdsaSignatureDigestX962SHA256,
            hash as CFData,
            &error
        ) else {
            let detail = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw GPGSignError.secKeyFailed("SecKeyCreateSignature: \(detail)")
        }

        // Output is DER `SEQUENCE { r INTEGER, s INTEGER }`; the
        // reply S-expression wants raw r and s halves so we can format
        // them as MPIs. Parse the DER ourselves — it's a tiny
        // structure.
        let derSig = sigCFData as Data
        let (r, s) = try parseECDSADER(derSig)
        return .ecdsa(
            r: leftPad(r, toCount: 32),
            s: leftPad(s, toCount: 32)
        )
    }

    // MARK: - DER helpers

    /// Parse an X9.62 `ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }`
    /// blob. Returns the bytes of r and s with their leading sign byte
    /// (the 0x00 that ASN.1 INTEGER adds when the high bit would be set)
    /// stripped.
    private static func parseECDSADER(_ data: Data) throws -> (r: Data, s: Data) {
        var r = ByteCursor(data: data)
        guard r.byte() == 0x30 else { throw GPGSignError.malformedSignature }
        _ = try readLength(&r)

        guard r.byte() == 0x02 else { throw GPGSignError.malformedSignature }
        let rLen = try readLength(&r)
        guard let rBytes = r.read(rLen) else { throw GPGSignError.malformedSignature }

        guard r.byte() == 0x02 else { throw GPGSignError.malformedSignature }
        let sLen = try readLength(&r)
        guard let sBytes = r.read(sLen) else { throw GPGSignError.malformedSignature }

        return (stripSignByte(rBytes), stripSignByte(sBytes))
    }

    private static func readLength(_ cursor: inout ByteCursor) throws -> Int {
        guard let first = cursor.byte() else { throw GPGSignError.malformedSignature }
        if first & 0x80 == 0 { return Int(first) }
        let n = Int(first & 0x7F)
        guard n > 0 && n <= 4 else { throw GPGSignError.malformedSignature }
        var v = 0
        for _ in 0..<n {
            guard let b = cursor.byte() else { throw GPGSignError.malformedSignature }
            v = (v << 8) | Int(b)
        }
        return v
    }

    private static func stripSignByte(_ data: Data) -> Data {
        if let first = data.first, first == 0x00, data.count > 1 {
            return data.subdata(in: data.index(after: data.startIndex)..<data.endIndex)
        }
        return data
    }

    private static func leftPad(_ data: Data, toCount count: Int) -> Data {
        if data.count >= count {
            // Take last `count` bytes (in case the input has spurious
            // leading zero padding past the curve width).
            return data.suffix(count)
        }
        var padded = Data(repeating: 0, count: count - data.count)
        padded.append(data)
        return padded
    }
}

private nonisolated struct ByteCursor {
    let data: Data
    var idx: Data.Index

    init(data: Data) {
        self.data = data
        self.idx = data.startIndex
    }

    mutating func byte() -> UInt8? {
        guard idx < data.endIndex else { return nil }
        let v = data[idx]
        idx = data.index(after: idx)
        return v
    }

    mutating func read(_ count: Int) -> Data? {
        guard let end = data.index(idx, offsetBy: count, limitedBy: data.endIndex) else { return nil }
        let chunk = data.subdata(in: idx..<end)
        idx = end
        return chunk
    }
}
