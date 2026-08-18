//
//  SExpression.swift
//  rootshell
//
//  Tiny canonical-S-expression encoder used to format `PKSIGN` reply
//  payloads for the Assuan protocol. The on-the-wire format gpg-agent
//  returns is a single D-line whose value is a canonical S-expression
//  describing the signature, e.g.:
//
//      (7:sig-val(5:eddsa(1:r32:<bytes>)(1:s32:<bytes>)))
//      (7:sig-val(5:ecdsa(1:r32:<bytes>)(1:s32:<bytes>)))
//      (7:sig-val(3:rsa(1:s256:<bytes>)))
//
//  Canonical encoding: atoms are `<decimal-length>:<bytes>`, lists are
//  paren-wrapped. No whitespace, no advanced (display hint) syntax.
//
//  This file does NOT implement a general-purpose S-exp library — it's
//  just the writer side, scoped to the three signature shapes above.
//  Anything more complex (parsing the inquire/PINENTRY exchange,
//  decryption replies) is out of scope for the sign-only MVP.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Canonical S-expression payload builder; `nonisolated` to match the
/// other GPG crypto helpers — off-MainActor signers/decryptors call
/// these constructors and would otherwise re-pin to MainActor.
nonisolated enum CanonicalSExpression {

    /// Build the Assuan `PKSIGN` reply payload for an EdDSA / Ed25519
    /// signature. Both `r` and `s` are 32 bytes; the reply format
    /// always emits them at fixed width with no MPI-style
    /// leading-zero stripping, so the caller must pass the raw
    /// fixed-width halves of the 64-byte Ed25519 signature.
    static func eddsaSigVal(r: Data, s: Data) -> Data {
        var inner = Data()
        inner.append(open)
        inner.append(rawAtom("eddsa"))
        inner.append(rsList(r: r, s: s))
        inner.append(close)
        return wrapSigVal(inner)
    }

    /// Build the Assuan `PKSIGN` reply payload for an ECDSA signature.
    /// `r` and `s` are big-endian, may have leading zero bytes — the
    /// reply format preserves whatever width the caller supplies, but
    /// most clients expect the full curve width (32 bytes for P-256).
    static func ecdsaSigVal(r: Data, s: Data) -> Data {
        var inner = Data()
        inner.append(open)
        inner.append(rawAtom("ecdsa"))
        inner.append(rsList(r: r, s: s))
        inner.append(close)
        return wrapSigVal(inner)
    }

    /// Build the Assuan `PKSIGN` reply payload for an RSA PKCS#1 v1.5
    /// signature. `s` is the full modulus-width signature value, big-
    /// endian, padded with leading zeros to match the modulus length —
    /// the RSA reply path does *not* strip leading zeros from `s`.
    static func rsaSigVal(s: Data) -> Data {
        var inner = Data()
        inner.append(open)
        inner.append(rawAtom("rsa"))
        inner.append(listPair("s", s))
        inner.append(close)
        return wrapSigVal(inner)
    }

    /// Build the canonical S-expression that wraps a PKDECRYPT reply:
    /// `(value <bytes>)`. The payload may be an ECDH shared secret, an
    /// unwrapped session frame, or a PKCS#1-unpadded RSA message,
    /// depending on the command variant.
    static func valueReply(_ bytes: Data) -> Data {
        var buf = Data()
        buf.append(open)
        buf.append(rawAtom("value"))
        // Value atom: `<lenAscii>:<bytes>`
        let lenAscii = Array("\(bytes.count)".utf8)
        buf.append(contentsOf: lenAscii)
        buf.append(0x3A)  // ":"
        buf.append(bytes)
        buf.append(close)
        return buf
    }

    // MARK: - Private builders

    private static let open = Data([0x28])   // "("
    private static let close = Data([0x29])  // ")"

    /// Emit a single canonical S-expression atom: `<lenAscii>:<bytes>`.
    /// Use this for algorithm names ("rsa", "ecdsa", "eddsa") that
    /// stand alone as the first element of a list, not as part of a
    /// name+value pair.
    private static func rawAtom(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var buf = Data()
        buf.append(contentsOf: Array("\(bytes.count)".utf8))
        buf.append(0x3A)  // ":"
        buf.append(contentsOf: bytes)
        return buf
    }

    /// `(<lenLen>:<lenBytes><valueLen>:<valueBytes>)` is NOT what's
    /// produced here — this method produces just two adjacent atoms:
    /// `<nameLen>:<name><valueLen>:<value>`. Callers wrap them in
    /// parens at the right nesting level.
    private static func atom(_ name: String, _ value: String) -> Data {
        atom(name, Data(value.utf8))
    }

    private static func atom(_ name: String, _ value: Data) -> Data {
        var buf = Data()
        // Name atom
        let nameBytes = Array(name.utf8)
        buf.append(contentsOf: Array("\(nameBytes.count)".utf8))
        buf.append(0x3A)  // ":"
        buf.append(contentsOf: nameBytes)
        // Value atom
        buf.append(contentsOf: Array("\(value.count)".utf8))
        buf.append(0x3A)  // ":"
        buf.append(value)
        return buf
    }

    /// `(<lenLen>:<lenBytes><valueLen>:<value>)` — a single (name value)
    /// list. Used when both name and value are emitted as their own
    /// length-prefixed atoms inside an enclosing list.
    private static func listPair(_ name: String, _ value: Data) -> Data {
        var buf = Data()
        buf.append(open)
        buf.append(atom(name, value))
        buf.append(close)
        return buf
    }

    /// The `(r ...)(s ...)` portion shared by EdDSA and ECDSA replies.
    private static func rsList(r: Data, s: Data) -> Data {
        listPair("r", r) + listPair("s", s)
    }

    /// Wrap the algorithm-specific inner expression in the outer
    /// `(sig-val ...)` envelope.
    private static func wrapSigVal(_ inner: Data) -> Data {
        var buf = Data()
        buf.append(open)
        let name = Array("sig-val".utf8)
        buf.append(contentsOf: Array("\(name.count)".utf8))
        buf.append(0x3A)
        buf.append(contentsOf: name)
        buf.append(inner)
        buf.append(close)
        return buf
    }
}
