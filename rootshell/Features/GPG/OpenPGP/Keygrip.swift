//
//  Keygrip.swift
//  rootshell
//
//  Computes the "keygrip" — the 20-byte SHA-1 identifier that gpg-agent
//  uses internally to refer to a key. The Assuan protocol commands
//  `SIGKEY`, `SETKEY`, `KEYINFO`, and `HAVEKEY` all pass keygrips, so a
//  forwarded GPG agent has to be able to compute matching values from
//  imported key material.
//
//  The encoding rule is:
//
//      For each named element of the algorithm's "elements" string,
//      write the *canonical S-expression* representation of a list
//      containing two atoms: the single-character name, then the raw
//      element bytes. So an element named "n" with value 0xDE 0xAD
//      hashes the bytes `(1:n2:\xDE\xAD)`. SHA-1 the concatenation of
//      every element's encoding to get the keygrip.
//
//  Elements differ per algorithm:
//      * RSA: just `n` (the modulus). `e` is deliberately excluded —
//        two RSA keys with the same modulus collide on keygrip, which
//        is the desired behaviour because they're the same key.
//      * ECDSA / EdDSA (legacy + native): `p` (prime), `a`, `b`, `g`,
//        `n` (curve parameters), then `q` (the public point). For a
//        named curve, the agent format expects the named-curve metadata
//        inlined — we replicate that here for the two curves we accept
//        (NIST P-256 and Ed25519).
//
//  The canonical S-expression format we use here is the
//  length-prefixed binary form: each atom is `<decimal-length>:<bytes>`,
//  lists are wrapped in parentheses.
//
//  Critical: the byte sequences emitted here MUST match the keygrip
//  hash format byte-for-byte. Any divergence silently produces a
//  different keygrip from what `gpg --with-keygrip` reports, and
//  lookups against forwarded agent requests will all miss. The test
//  plan in the approved feature design calls for cross-checking
//  against known reference values during import.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto

/// GPG keygrip computation; `nonisolated` so it can be called from
/// off-MainActor paths (the `nonisolated SSHKeyGPGBridge` uses it on
/// every keygrip query, and we'd otherwise re-pin to MainActor via
/// the project default).
nonisolated enum Keygrip {

    /// Compute the 20-byte keygrip for the given public key material.
    /// Throws for algorithms we don't support — the caller is expected
    /// to have filtered ``OpenPGPAlgorithm/unsupported`` out already.
    static func compute(
        algorithm: OpenPGPAlgorithm,
        publicMaterial: OpenPGPSubkey.PublicMaterial
    ) throws -> Data {
        var hasher = Insecure.SHA1()

        switch (algorithm, publicMaterial) {
        case (.rsa, .rsa(let n, _)):
            // RSA keygrip is `SHA-1(n_bytes_as_signed_magnitude)`
            // direct, with NO S-expression wrapping.
            //
            // The keygrip-side serialization treats `n` as a signed
            // MPI: strip all leading zero bytes, then PREPEND a 0x00
            // sign byte if the resulting high bit is set so the value
            // is unambiguously positive in a two's-complement
            // interpretation.
            //
            // For a properly-generated 4096-bit RSA modulus the high
            // bit IS set, so the hash sees 513 bytes (0x00 || n), not
            // 512. Stripping all leading zeros (the obvious
            // implementation) is the opposite of what we want.
            hasher.update(data: mpiSignedMagnitude(n))

        case (.ecdsa(let curve), .ec(let q)):
            // ECDSA: hash p, a, b, g, n curve params then q. For P-256
            // `q` is 65 bytes uncompressed (`04 || X || Y`) which is
            // already the format the keygrip hash expects.
            try hashECCurveParams(curve: curve, into: &hasher)
            hashElement(name: "q", value: q, into: &hasher)

        case (.eddsaLegacy(let curve), .ec(let q)):
            // Ed25519 legacy (OpenPGP algo 22): the OpenPGP wire
            // format is `0x40 || compressed_32` for `q`. The keygrip
            // hash strips the `0x40` marker before hashing. The curve
            // params themselves are the magnitude bytes of the
            // canonical Ed25519 MPI literals — NOT the mod-p
            // reductions — because the keygrip hashes magnitude only
            // (sign bit is separate and not hashed).
            try hashECCurveParams(curve: curve, into: &hasher)
            let strippedQ: Data
            if let first = q.first, first == 0x40, q.count > 1 {
                strippedQ = q.subdata(in: q.index(after: q.startIndex)..<q.endIndex)
            } else {
                strippedQ = q
            }
            hashElement(name: "q", value: strippedQ, into: &hasher)

        case (.ed25519Native, .ec(let q)):
            // v6 Ed25519: q is already the raw 32-byte compressed
            // point with no 0x40 marker — feeds directly.
            try hashECCurveParams(curve: .ed25519, into: &hasher)
            hashElement(name: "q", value: q, into: &hasher)

        case (.ecdh(let curve), .ec(let q)):
            // ECDH (OpenPGP algo 18): wire format is the same MPI
            // shape as ECDSA / EdDSA legacy — for cv25519 the value
            // is 0x40-prefixed onto the 32-byte X25519 public point;
            // for P-256 it's `0x04 || X || Y`. The keygrip hash
            // strips the cv25519 prefix the same way it does for
            // Ed25519 (any Montgomery/Edwards curve gets compacted),
            // so we mirror that here.
            try hashECCurveParams(curve: curve, into: &hasher)
            let strippedQ: Data
            if curve == .cv25519,
               let first = q.first, first == 0x40, q.count > 1 {
                strippedQ = q.subdata(in: q.index(after: q.startIndex)..<q.endIndex)
            } else {
                strippedQ = q
            }
            hashElement(name: "q", value: strippedQ, into: &hasher)

        case (.x25519Native, .ec(let q)):
            // v6 X25519 (algo 25): q is the raw 32-byte u-coordinate
            // with no prefix. Same Montgomery curve params as
            // cv25519.
            try hashECCurveParams(curve: .cv25519, into: &hasher)
            hashElement(name: "q", value: q, into: &hasher)

        case (.unsupported, _):
            throw OpenPGPParseError.unsupportedAlgorithm(0)

        case (.rsa, .ec),
             (.ecdsa, .rsa),
             (.ecdh, .rsa),
             (.eddsaLegacy, .rsa),
             (.ed25519Native, .rsa),
             (.x25519Native, .rsa):
            // Type mismatch — shouldn't happen unless the parser is
            // wired wrong. Surface as malformed so dev catches it.
            throw OpenPGPParseError.malformedMPI
        }

        return Data(hasher.finalize())
    }

    /// Strip ALL leading zero bytes to produce canonical magnitude
    /// bytes — used by the ECC keygrip path. Not currently used
    /// directly but kept as the reference helper for any future MPI
    /// canonicalisation needs.
    private static func stripLeadingZeros(_ data: Data) -> Data {
        var slice = data
        while slice.count > 1, slice.first == 0x00 {
            slice = slice.subdata(in: slice.index(after: slice.startIndex)..<slice.endIndex)
        }
        return slice
    }

    /// Signed-magnitude MPI serialization used by the RSA keygrip:
    ///   1. Strip leading zero bytes to canonical magnitude
    ///   2. If the first byte has its high bit set, prepend a 0x00
    ///      sign byte so the value is unambiguously positive
    /// The RSA keygrip s-exp treats `n` and `e` as signed MPIs, so
    /// the high-bit-set case needs the explicit zero pad.
    private static func mpiSignedMagnitude(_ data: Data) -> Data {
        let magnitude = stripLeadingZeros(data)
        guard let first = magnitude.first, (first & 0x80) != 0 else {
            return magnitude
        }
        var withSign = Data([0x00])
        withSign.append(magnitude)
        return withSign
    }

    // MARK: - Curve parameters

    /// Append the canonical curve-parameter elements (p, a, b, g, n)
    /// for the given named curve. The byte sequences are the agreed
    /// constants the keygrip hash expects for these curves.
    private static func hashECCurveParams(curve: ECCurve, into hasher: inout Insecure.SHA1) throws {
        switch curve {
        case .p256:
            // NIST P-256 (secp256r1 / prime256v1). Field prime, curve
            // coefficients, base point (uncompressed), and group order.
            let p = GPGHex.decode( "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")!
            let a = GPGHex.decode( "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC")!
            let b = GPGHex.decode( "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")!
            let g = GPGHex.decode( "046B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C2964FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")!
            let n = GPGHex.decode( "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!
            hashElement(name: "p", value: p, into: &hasher)
            hashElement(name: "a", value: a, into: &hasher)
            hashElement(name: "b", value: b, into: &hasher)
            hashElement(name: "g", value: g, into: &hasher)
            hashElement(name: "n", value: n, into: &hasher)

        case .ed25519:
            // Ed25519 magnitudes per the keygrip-side domain
            // parameters. `a` and `b` are NEGATIVE MPI literals; the
            // keygrip hash sees only the MAGNITUDE bytes — sign lives
            // outside the byte representation and isn't hashed.
            //   p  = 2^255 - 19 (32 bytes, positive)
            //   a  = -1 (magnitude byte: 0x01)
            //   b  = -d_Edwards (magnitude bytes — NOT mod-p reduction)
            //   g  = 0x04 || g_x || g_y (65 bytes — Weierstrass-style
            //        encoding, NOT the 32-byte Edwards compressed
            //        form)
            //   n  = group order (32 bytes)
            let p = GPGHex.decode("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED")!
            let a = GPGHex.decode("01")!
            let b = GPGHex.decode("2DFC9311D490018C7338BF8688861767FF8FF5B2BEBE27548A14B235ECA6874A")!
            let gx = "216936D3CD6E53FEC0A4E231FDD6DC5C692CC7609525A7B2C9562D608F25D51A"
            let gy = "6666666666666666666666666666666666666666666666666666666666666658"
            let g = GPGHex.decode("04" + gx + gy)!
            let n = GPGHex.decode("1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED")!
            hashElement(name: "p", value: p, into: &hasher)
            hashElement(name: "a", value: a, into: &hasher)
            hashElement(name: "b", value: b, into: &hasher)
            hashElement(name: "g", value: g, into: &hasher)
            hashElement(name: "n", value: n, into: &hasher)

        case .cv25519:
            // Curve25519 (Montgomery form) magnitudes from the
            // keygrip-side domain parameters for "Curve25519":
            //   p  = 2^255 - 19 (same as Ed25519, 32 bytes)
            //   a  = (A-2)/4 = 121665 = 0x1DB41 — the Montgomery
            //        `a24` constant used in the X25519 ladder, NOT
            //        the full A = 486662. This is the canonical
            //        value the keygrip hashes.
            //   b  = 0x01
            //   g  = 0x04 || g_x || g_y where g_x = 9 zero-padded
            //        to 32 bytes, g_y is the affine y-coordinate of
            //        the standard base point.
            //   n  = group order (same as Ed25519, 32 bytes)
            let p = GPGHex.decode("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED")!
            let a = GPGHex.decode("01DB41")!
            let b = GPGHex.decode("01")!
            let gx = "0000000000000000000000000000000000000000000000000000000000000009"
            let gy = "20AE19A1B8A086B4E01EDD2C7748D14C923D4D7E6D7C61B229E9C5A27ECED3D9"
            let g = GPGHex.decode("04" + gx + gy)!
            let n = GPGHex.decode("1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED")!
            hashElement(name: "p", value: p, into: &hasher)
            hashElement(name: "a", value: a, into: &hasher)
            hashElement(name: "b", value: b, into: &hasher)
            hashElement(name: "g", value: g, into: &hasher)
            hashElement(name: "n", value: n, into: &hasher)
        }
    }

    // MARK: - Canonical S-expression element

    /// Hash a single element of the form `(<name-len>:<name><value-len>:<value>)`
    /// in canonical S-expression encoding. The name is always a single
    /// ASCII character for the elements we hash here, but the encoding
    /// is general.
    private static func hashElement(name: String, value: Data, into hasher: inout Insecure.SHA1) {
        let nameBytes = Array(name.utf8)
        var buf = Data()
        buf.append(0x28)  // "("
        appendCanonicalAtom(bytes: nameBytes, into: &buf)
        appendCanonicalAtom(bytes: Array(value), into: &buf)
        buf.append(0x29)  // ")"
        hasher.update(data: buf)
    }

    private static func appendCanonicalAtom(bytes: [UInt8], into buf: inout Data) {
        let lengthASCII = Array("\(bytes.count)".utf8)
        buf.append(contentsOf: lengthASCII)
        buf.append(0x3A)  // ":"
        buf.append(contentsOf: bytes)
    }

}

// MARK: - GPG hex helpers
//
// Namespaced under an enum to avoid clashing with the file-private
// ``Data.init(hexString:)`` extensions that already exist in the Trzsz
// transport layer. The GPG code uses these helpers via
// ``GPGHex.decode(_:)`` / ``GPGHex.encodeUpper(_:)``.

nonisolated enum GPGHex {
    /// Decode an even-length hex string to bytes. Returns nil on any
    /// non-hex character or odd length. Whitespace is ignored.
    static func decode(_ string: String) -> Data? {
        let cleaned = string.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }

        var bytes = Data()
        bytes.reserveCapacity(cleaned.count / 2)
        var iter = cleaned.makeIterator()
        while let hi = iter.next(), let lo = iter.next() {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            bytes.append(UInt8(h << 4 | l))
        }
        return bytes
    }

    /// Uppercase hex string with no separators. Used when emitting
    /// keygrips/fingerprints over Assuan.
    static func encodeUpper(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
}

nonisolated extension Data {
    /// Uppercase hex string used by GPG-layer code for keygrip and
    /// fingerprint formatting. Distinct name from the (currently
    /// nonexistent) module-wide `hexUpper` so the GPG code can stay
    /// independent of any future Data hex helper that other layers
    /// introduce.
    var gpgHexUpper: String {
        GPGHex.encodeUpper(self)
    }
}
