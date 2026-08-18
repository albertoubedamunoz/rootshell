//
//  GPGDecryptor.swift
//  rootshell
//
//  Mirror of ``GPGSigner`` for the PKDECRYPT path. Takes a parsed
//  OpenPGP secret subkey and the `(enc-val …)` ciphertext S-expression
//  that arrived over Assuan's INQUIRE response, and produces the
//  payload bytes that the agent wraps in a `(value …)` reply.
//
//  What "plaintext" means here depends on the algorithm:
//
//  * **RSA** — we do raw textbook RSA (`c^d mod n`) using `BigUInt`
//    then strip PKCS#1 v1.5 EME padding. The returned bytes are the
//    OpenPGP wrapped session key (`symalg || key || checksum`) that
//    gpg unwraps further on the client side.
//  * **ECDH cv25519 / X25519 / P-256** — older clients expect raw
//    ECDH output and do the KDF/AES-wrap unwrap themselves. KEM-aware
//    clients can ask the agent to return the unwrapped session frame.
//
//  Hardware-backed keys (YubiKey, FIDO2) aren't supported in this
//  decryptor — those flows would need scdaemon-style routing.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto
import Citadel

nonisolated enum GPGDecryptError: Error, LocalizedError, Equatable {
    case unsupportedAlgorithm(String)
    case malformedKey
    case malformedCiphertext(String)
    case pkcs1PaddingInvalid
    case aesUnwrapFailed(String)
    case kdfFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAlgorithm(let what):
            return "Decryption with \(what) is not supported by the GPG agent."
        case .malformedKey:
            return "Stored GPG secret material is malformed."
        case .malformedCiphertext(let detail):
            return "Malformed PKDECRYPT ciphertext: \(detail)."
        case .pkcs1PaddingInvalid:
            return "RSA PKCS#1 v1.5 padding is invalid."
        case .aesUnwrapFailed(let detail):
            return "AES Key Unwrap failed: \(detail)."
        case .kdfFailed(let detail):
            return "ECDH KDF failed: \(detail)."
        }
    }
}

/// Pure functional decryptor; `nonisolated` so the CPU-bound RSA
/// modexp / ECDH agreement / OpenPGP KDF / AES key-unwrap can be run
/// off the main thread via `Task.detached` from the agent's
/// `@MainActor` Assuan loop. Otherwise the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would pin every call
/// to the UI thread.
nonisolated enum GPGDecryptor {
    enum ReplyMode: Sendable, Equatable {
        case legacyECDHSharedSecret
        case unwrappedSessionKey
    }

    /// Decrypt the ciphertext in `encValSExpr` using `subkey` and
    /// return the payload bytes that the agent should wrap in a
    /// `(value …)` reply on the wire. Caller is responsible for the
    /// S-expression framing of the reply.
    static func decrypt(
        subkey: OpenPGPSubkey,
        encValSExpr: SExpr,
        primaryFingerprint: Data,
        replyMode: ReplyMode = .unwrappedSessionKey
    ) throws -> Data {
        // The outer sexp is always `(enc-val (algoName …))`. Strip
        // the wrapper and dispatch on the inner head.
        let inner = try extractEncValBody(encValSExpr)

        switch subkey.algorithm {
        case .rsa:
            return try decryptRSA(subkey: subkey, inner: inner)
        case .ecdh(let curve):
            switch curve {
            case .cv25519:
                if replyMode == .legacyECDHSharedSecret {
                    return try sharedSecretCurve25519(subkey: subkey, inner: inner)
                } else {
                    return try decryptECDHCurve25519(
                        subkey: subkey,
                        inner: inner,
                        primaryFingerprint: primaryFingerprint
                    )
                }
            case .p256:
                if replyMode == .legacyECDHSharedSecret {
                    return try sharedSecretP256(subkey: subkey, inner: inner)
                } else {
                    return try decryptECDHP256(
                        subkey: subkey,
                        inner: inner,
                        primaryFingerprint: primaryFingerprint
                    )
                }
            case .ed25519:
                throw GPGDecryptError.unsupportedAlgorithm("ECDH on Ed25519 (not a valid combination)")
            }
        case .x25519Native:
            if replyMode == .legacyECDHSharedSecret {
                return try sharedSecretCurve25519(subkey: subkey, inner: inner)
            } else {
                return try decryptECDHCurve25519(
                    subkey: subkey,
                    inner: inner,
                    primaryFingerprint: primaryFingerprint
                )
            }
        case .ecdsa, .eddsaLegacy, .ed25519Native:
            throw GPGDecryptError.unsupportedAlgorithm("signing-only subkey can't decrypt")
        case .unsupported(let id):
            throw GPGDecryptError.unsupportedAlgorithm("algorithm id \(id)")
        }
    }

    // MARK: - enc-val parsing

    /// Validate the outer `(enc-val (algo …))` shape and return the
    /// inner `(algo …)` list.
    private static func extractEncValBody(_ envelope: SExpr) throws -> SExpr {
        guard case .list(let items) = envelope,
              items.count >= 2,
              items[0].atomString == "enc-val",
              case .list = items[1] else {
            throw GPGDecryptError.malformedCiphertext("missing enc-val wrapper")
        }
        return items[1]
    }

    // MARK: - RSA

    private static func decryptRSA(subkey: OpenPGPSubkey, inner: SExpr) throws -> Data {
        // Shape: (rsa (a <ciphertext-MPI>))
        guard inner.isList(named: "rsa"),
              let aPair = inner.firstChild(named: "a"),
              let a = aPair.pairValue else {
            throw GPGDecryptError.malformedCiphertext("rsa enc-val missing (a …)")
        }

        guard case .rsa(let n, let e) = subkey.publicMaterial,
              case .rsa(let d, _, _, _) = subkey.secretMaterial else {
            throw GPGDecryptError.malformedKey
        }

        // Route through Citadel's BoringSSL-backed RSA decrypt — same
        // code path that the SSH-key bridge uses. BoringSSL handles
        // both the modular exponentiation and PKCS#1 v1.5 EME
        // unpadding internally.
        let rsaKey = Insecure.RSA.PrivateKey(
            modulus: n,
            publicExponent: e,
            privateExponent: d
        )
        let modulusByteLen = stripLeadingZeros(n).count
        let ciphertext = leftPad(a, toCount: modulusByteLen)
        do {
            return try rsaKey.decryptPKCS1v15(ciphertext)
        } catch {
            throw GPGDecryptError.pkcs1PaddingInvalid
        }
    }

    // MARK: - ECDH cv25519 / X25519

    private static func sharedSecretCurve25519(
        subkey: OpenPGPSubkey,
        inner: SExpr
    ) throws -> Data {
        let scalars = try x25519PrivateScalarCandidates(for: subkey)
        let parts = try extractECDHParts(inner: inner)
        let ephemeral = stripCv25519Prefix(parts.e)
        guard ephemeral.count == 32 else {
            throw GPGDecryptError.malformedCiphertext("expected 32-byte X25519 ephemeral, got \(ephemeral.count)")
        }

        let pubKey: Curve25519.KeyAgreement.PublicKey
        do {
            pubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        } catch {
            throw GPGDecryptError.malformedCiphertext("X25519 ephemeral rejected by CryptoKit")
        }

        var lastError: Error?
        for scalar in scalars {
            do {
                let privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
                let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
                var out = Data([0x40])
                out.append(shared.withUnsafeBytes { Data($0) })
                return out
            } catch {
                lastError = error
            }
        }
        throw GPGDecryptError.malformedCiphertext(lastError?.localizedDescription ?? "X25519 agreement failed")
    }

    private static func decryptECDHCurve25519(
        subkey: OpenPGPSubkey,
        inner: SExpr,
        primaryFingerprint: Data
    ) throws -> Data {
        let scalars = try x25519PrivateScalarCandidates(for: subkey)

        let parts = try extractECDHParts(inner: inner)
        // Strip the 0x40 prefix that OpenPGP cv25519 uses on the ephemeral
        // public point. v6 X25519 (algo 25) ships the raw 32 bytes with
        // no prefix; we accept either form.
        let ephemeral = stripCv25519Prefix(parts.e)
        guard ephemeral.count == 32 else {
            throw GPGDecryptError.malformedCiphertext("expected 32-byte X25519 ephemeral, got \(ephemeral.count)")
        }

        let pubKey: Curve25519.KeyAgreement.PublicKey
        do {
            pubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeral)
        } catch {
            throw GPGDecryptError.malformedCiphertext("X25519 ephemeral rejected by CryptoKit")
        }

        let wrapped = stripWrappedLengthPrefix(parts.s)
        var lastError: Error?

        for scalar in scalars {
            let privKey: Curve25519.KeyAgreement.PrivateKey
            do {
                privKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            } catch {
                lastError = error
                continue
            }

            let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
            let sharedBytes = shared.withUnsafeBytes { Data($0) }
            for kdf in kdfCandidates(parts: parts, subkey: subkey, recipientFingerprint: primaryFingerprint) {
                do {
                    let kek = try deriveKEK(sharedBytes: sharedBytes, candidate: kdf)
                    return try AESKeyUnwrap.unwrap(wrapped, kek: kek)
                } catch {
                    lastError = error
                }
            }
        }

        throw GPGDecryptError.aesUnwrapFailed(lastError?.localizedDescription ?? "all cv25519 candidates failed")
    }

    /// CryptoKit expects X25519 private keys in RFC 7748 little-endian
    /// scalar form. Legacy OpenPGP cv25519 stores the scalar as a
    /// big-endian MPI, so imported legacy secret keys must be reversed
    /// after padding. RFC 9580 native X25519 stores raw scalar bytes.
    private static func x25519PrivateScalarCandidates(for subkey: OpenPGPSubkey) throws -> [Data] {
        guard case .ec(let scalarBytes) = subkey.secretMaterial else {
            throw GPGDecryptError.malformedKey
        }

        switch subkey.algorithm {
        case .ecdh(.cv25519):
            let magnitude = stripLeadingZeros(scalarBytes)
            guard magnitude.count <= 32 else { throw GPGDecryptError.malformedKey }
            let padded = leftPad(magnitude, toCount: 32)
            let reversed = Data(padded.reversed())
            return reversed == padded ? [reversed] : [reversed, padded]

        case .x25519Native:
            guard scalarBytes.count == 32 else { throw GPGDecryptError.malformedKey }
            return [scalarBytes]

        default:
            throw GPGDecryptError.malformedKey
        }
    }

    // MARK: - ECDH P-256

    private static func sharedSecretP256(
        subkey: OpenPGPSubkey,
        inner: SExpr
    ) throws -> Data {
        guard case .ec(let scalarBytes) = subkey.secretMaterial else {
            throw GPGDecryptError.malformedKey
        }
        let scalar = leftPad(scalarBytes, toCount: 32)
        guard scalar.count == 32 else { throw GPGDecryptError.malformedKey }

        let parts = try extractECDHParts(inner: inner)
        guard parts.e.count == 65, parts.e.first == 0x04 else {
            throw GPGDecryptError.malformedCiphertext("expected 65-byte uncompressed P-256 ephemeral")
        }

        let privKey: P256.KeyAgreement.PrivateKey
        do {
            privKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        } catch {
            throw GPGDecryptError.malformedKey
        }
        let pubKey: P256.KeyAgreement.PublicKey
        do {
            pubKey = try P256.KeyAgreement.PublicKey(x963Representation: parts.e)
        } catch {
            throw GPGDecryptError.malformedCiphertext("P-256 ephemeral rejected by CryptoKit")
        }
        let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        return shared.withUnsafeBytes { Data($0) }
    }

    private static func decryptECDHP256(
        subkey: OpenPGPSubkey,
        inner: SExpr,
        primaryFingerprint: Data
    ) throws -> Data {
        guard case .ec(let scalarBytes) = subkey.secretMaterial else {
            throw GPGDecryptError.malformedKey
        }
        let scalar = leftPad(scalarBytes, toCount: 32)
        guard scalar.count == 32 else { throw GPGDecryptError.malformedKey }

        let parts = try extractECDHParts(inner: inner)
        // OpenPGP P-256 ephemeral is `0x04 || X || Y` (65 bytes).
        guard parts.e.count == 65, parts.e.first == 0x04 else {
            throw GPGDecryptError.malformedCiphertext("expected 65-byte uncompressed P-256 ephemeral")
        }

        let privKey: P256.KeyAgreement.PrivateKey
        do {
            privKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        } catch {
            throw GPGDecryptError.malformedKey
        }
        let pubKey: P256.KeyAgreement.PublicKey
        do {
            pubKey = try P256.KeyAgreement.PublicKey(x963Representation: parts.e)
        } catch {
            throw GPGDecryptError.malformedCiphertext("P-256 ephemeral rejected by CryptoKit")
        }
        let shared = try privKey.sharedSecretFromKeyAgreement(with: pubKey)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }

        let wrapped = stripWrappedLengthPrefix(parts.s)
        var lastError: Error?
        for kdf in kdfCandidates(parts: parts, subkey: subkey, recipientFingerprint: primaryFingerprint) {
            do {
                let kek = try deriveKEK(sharedBytes: sharedBytes, candidate: kdf)
                return try AESKeyUnwrap.unwrap(wrapped, kek: kek)
            } catch {
                lastError = error
            }
        }
        throw GPGDecryptError.aesUnwrapFailed(lastError?.localizedDescription ?? "all P-256 KDF candidates failed")
    }

    // MARK: - ECDH sexp helpers

    /// Pull the (e …) and (s …) MPI values out of an ECDH inner
    /// expression. Accepts both `(ecdh …)` (older shape) and
    /// `(ecc …)` (the modern KEM-friendly shape) — only `e` and `s`
    /// matter here; cipher, hash, and KDF parameters are captured when
    /// the request carries them.
    private struct ECDHParts {
        let e: Data
        let s: Data
        let kdfHashAlgo: UInt8?
        let kekAlgo: UInt8?
        let kdfParams: Data?
    }

    private enum KDFCandidate {
        case explicit(hash: UInt8, kek: UInt8, params: Data)
        case reconstructed(hash: UInt8, kek: UInt8, curveOID: Data, fingerprint: Data)
    }

    private static func extractECDHParts(inner: SExpr) throws -> ECDHParts {
        let isECDH = inner.isList(named: "ecdh") || inner.isList(named: "ecc")
        guard isECDH else {
            throw GPGDecryptError.malformedCiphertext("expected ecdh/ecc inner expression")
        }
        guard let ePair = inner.firstChild(named: "e"), let e = ePair.pairValue else {
            throw GPGDecryptError.malformedCiphertext("missing (e …)")
        }
        guard let sPair = inner.firstChild(named: "s"), let s = sPair.pairValue else {
            throw GPGDecryptError.malformedCiphertext("missing (s …)")
        }
        let kdfHash = inner.firstChild(named: "h").flatMap { parseSExprUInt8($0.pairValue) }
        let kek = inner.firstChild(named: "c").flatMap { parseSExprUInt8($0.pairValue) }
        let kdfParams = inner.firstChild(named: "kdf-params")?.pairValue
        return ECDHParts(e: e, s: s, kdfHashAlgo: kdfHash, kekAlgo: kek, kdfParams: kdfParams)
    }

    private static func parseSExprUInt8(_ data: Data?) -> UInt8? {
        guard let data, !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8),
           let value = UInt8(text) {
            return value
        }
        if data.count == 1 {
            return data.first
        }
        return nil
    }

    private static func kdfCandidates(
        parts: ECDHParts,
        subkey: OpenPGPSubkey,
        recipientFingerprint: Data
    ) -> [KDFCandidate] {
        let fallbackHash = subkey.kdfParams?.hashAlgo ?? OpenPGPECDH.defaultHashAlgo
        let fallbackKEK = subkey.kdfParams?.kekAlgo ?? OpenPGPECDH.defaultKEKAlgo
        let fallback = KDFCandidate.reconstructed(
            hash: fallbackHash,
            kek: fallbackKEK,
            curveOID: curveOIDForKDF(subkey: subkey),
            fingerprint: recipientFingerprint
        )

        guard let kdfHash = parts.kdfHashAlgo,
              let kekAlgo = parts.kekAlgo,
              let kdfParams = parts.kdfParams else {
            return [fallback]
        }

        return [
            .explicit(hash: kdfHash, kek: kekAlgo, params: kdfParams),
            fallback
        ]
    }

    private static func deriveKEK(sharedBytes: Data, candidate: KDFCandidate) throws -> Data {
        switch candidate {
        case .explicit(let hash, let kek, let params):
            return try OpenPGPECDH.deriveKEK(
                sharedSecret: sharedBytes,
                kdfHashAlgo: hash,
                kekAlgo: kek,
                kdfParams: params
            )
        case .reconstructed(let hash, let kek, let curveOID, let fingerprint):
            return try OpenPGPECDH.deriveKEK(
                sharedSecret: sharedBytes,
                kdfHashAlgo: hash,
                kekAlgo: kek,
                curveOID: curveOID,
                recipientFingerprint: fingerprint
            )
        }
    }

    /// Curve OID bytes used to build the KDF "Param" string. Pulled
    /// from the subkey's algorithm; matches what the OpenPGP public-
    /// key packet carries.
    private static func curveOIDForKDF(subkey: OpenPGPSubkey) -> Data {
        switch subkey.algorithm {
        case .ecdh(.p256):
            return Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        case .ecdh(.cv25519), .x25519Native:
            return Data([0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01])
        case .ecdh(.ed25519):
            return Data()    // Unreachable; parser rejects this combo.
        case .rsa, .ecdsa, .eddsaLegacy, .ed25519Native, .unsupported:
            return Data()    // Unreachable for decrypt-only path.
        }
    }

    /// OpenPGP cv25519 ephemeral points are `0x40 || compressed_32` on
    /// the wire; strip the prefix to get the raw 32-byte X25519
    /// public-key value CryptoKit expects.
    private static func stripCv25519Prefix(_ data: Data) -> Data {
        if let first = data.first, first == 0x40, data.count > 1 {
            return data.subdata(in: data.index(after: data.startIndex)..<data.endIndex)
        }
        return data
    }

    /// The OpenPGP wire format precedes the AES-wrapped session-key
    /// bytes with a one-octet length (RFC 9580 §13.5). That length
    /// byte is included verbatim in the agent request sexp; strip it
    /// before handing the rest to AES-Unwrap.
    private static func stripWrappedLengthPrefix(_ data: Data) -> Data {
        guard let len = data.first else { return data }
        let payload = data.dropFirst()
        // If the announced length matches the remaining bytes, drop
        // the prefix; otherwise pass through (some clients omit it
        // when wrapping the enc-val sexp).
        if Int(len) == payload.count {
            return Data(payload)
        }
        return data
    }

    // MARK: - Bytes helpers

    private static func stripLeadingZeros(_ data: Data) -> Data {
        var slice = data
        while slice.count > 1, slice.first == 0x00 {
            slice = slice.subdata(in: slice.index(after: slice.startIndex)..<slice.endIndex)
        }
        return slice
    }

    private static func leftPad(_ data: Data, toCount count: Int) -> Data {
        if data.count >= count { return data.suffix(count) }
        var padded = Data(repeating: 0, count: count - data.count)
        padded.append(data)
        return padded
    }
}
