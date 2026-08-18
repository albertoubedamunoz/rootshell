//
//  OpenPGPPacket.swift
//  rootshell
//
//  Minimal RFC 9580 (OpenPGP) packet parser covering the subset we need
//  for GPG agent forwarding: parse a secret-key block (primary + subkeys)
//  enough to identify each subkey's algorithm, public material, and
//  unencrypted secret scalar. Encrypted secret keys are explicitly
//  rejected — the MVP requires the user to import a cleartext export
//  (`gpg --export-secret-keys --armor` after temporarily removing the
//  passphrase). The Keychain access control becomes the at-rest
//  protection on iOS.
//
//  The parser deliberately does not aim for full OpenPGP coverage. It
//  ignores signature, user-ID, and trust packets entirely; their bytes
//  are stepped over but their contents are not interpreted. Anything
//  beyond the scope below is treated as "not supported" and surfaces a
//  clear error to the import UI.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto

// MARK: - Public types

/// Algorithm identifier as it appears in an OpenPGP public-key packet
/// (RFC 9580 §9.1). Covers the algorithms we sign and/or decrypt with;
/// everything else surfaces as ``unsupported``.
nonisolated enum OpenPGPAlgorithm: Sendable, Hashable {
    /// Algo 1 (rsa-sign-and-encrypt), 2 (rsa-encrypt-only), or 3
    /// (rsa-sign-only). Same key material across all three; capability
    /// is tracked separately on ``OpenPGPSubkey``.
    case rsa
    /// Algo 19 — ECDSA over a named curve. The associated value is the
    /// curve identifier carried as an OID in the packet.
    case ecdsa(ECCurve)
    /// Algo 18 — ECDH (encryption) over a named curve. Currently
    /// accepts cv25519 and NIST P-256. The associated value is the
    /// curve identifier carried as an OID in the packet.
    case ecdh(ECCurve)
    /// Algo 22 — legacy EdDSA encoding (Ed25519 with curve OID + MPI of
    /// 0x40-prefixed point). This is what `gpg --gen-key` produces for
    /// Ed25519 v4 keys today; effectively all real-world Ed25519 GPG
    /// keys arrive in this form.
    case eddsaLegacy(ECCurve)
    /// Algo 27 — RFC 9580 native Ed25519 (raw 32-byte point, no MPI).
    /// Only ever appears in v6 packets, which are rare in the wild.
    case ed25519Native
    /// Algo 25 — RFC 9580 native X25519 (raw 32-byte point, no MPI,
    /// no 0x40 prefix). v6 packet format.
    case x25519Native
    /// Anything we neither sign nor decrypt with. Includes DSA (17),
    /// X448, Ed448, etc.
    case unsupported(rawID: UInt8)
}

/// Curves we accept for ECDSA / EdDSA / ECDH. Mapped by OID at parse time.
nonisolated enum ECCurve: Sendable, Hashable {
    case p256
    case ed25519
    /// Montgomery-form Curve25519 — the OpenPGP ECDH curve. Different
    /// curve parameters than ``ed25519`` (Edwards form) so the GPG
    /// keygrip differs even though the underlying scalar/point pair
    /// can be derived from an Ed25519 keypair.
    case cv25519

    /// Recognise a curve from its DER-encoded object identifier as it
    /// appears in an OpenPGP public-key packet (just the OID bytes, no
    /// tag/length prefix).
    static func from(oidBytes: Data) -> ECCurve? {
        // NIST P-256: 1.2.840.10045.3.1.7  →  2A 86 48 CE 3D 03 01 07
        let p256OID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        // Ed25519: 1.3.6.1.4.1.11591.15.1  →  2B 06 01 04 01 DA 47 0F 01
        let ed25519OID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01]
        // Curve25519: 1.3.6.1.4.1.3029.1.5.1  →  2B 06 01 04 01 97 55 01 05 01
        let cv25519OID: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01]

        if oidBytes.elementsEqual(p256OID) { return .p256 }
        if oidBytes.elementsEqual(ed25519OID) { return .ed25519 }
        if oidBytes.elementsEqual(cv25519OID) { return .cv25519 }
        return nil
    }
}

/// One parsed subkey (or primary, treated identically) — algorithm,
/// public material, secret scalar, and the human-facing key fingerprint
/// computed from the public portion.
nonisolated struct OpenPGPSubkey: Sendable, Hashable {
    /// Algorithm + curve identifier.
    let algorithm: OpenPGPAlgorithm

    /// Creation timestamp from the packet (seconds since Unix epoch).
    /// Goes into the v4 fingerprint computation, so we hold onto it.
    let creationTime: UInt32

    /// Algorithm-specific public material. Stored as raw bytes per
    /// algorithm:
    /// * RSA: `(n: Data, e: Data)` — big-endian, no leading zero bytes.
    /// * ECDSA / EdDSA legacy: `(q: Data)` — point in OpenPGP MPI form
    ///   *including* the leading prefix byte (0x04 uncompressed for
    ///   ECDSA, 0x40 for Ed25519 EdDSA).
    /// * Ed25519 native: `(q: Data)` — raw 32 bytes.
    let publicMaterial: PublicMaterial

    /// Algorithm-specific secret material (cleartext). Same encoding
    /// conventions as ``publicMaterial``. The presence of this field is
    /// what distinguishes a subkey we can sign with from one that was
    /// part of the import for context only.
    let secretMaterial: SecretMaterial

    /// The v4 OpenPGP fingerprint of this subkey (20 bytes, uppercase
    /// hex when displayed). Computed per RFC 9580 §5.5.4: SHA-1 over
    /// `0x99 || len(2) || version || ctime(4) || algo || pubparams`.
    let fingerprint: Data

    /// GPG keygrip (20 bytes). Computed lazily by ``Keygrip`` from
    /// the public material — stored here so callers don't have to
    /// recompute it on every Assuan `HAVEKEY`.
    let keygrip: Data

    /// Whether this subkey is the primary (i.e. came from a packet with
    /// tag 5 rather than 7). Primaries are usually certification-only
    /// and not what gets used for signing, but we don't actually look at
    /// key flags in the MVP — we offer every signing-capable subkey to
    /// the remote.
    let isPrimary: Bool

    /// Whether this subkey can sign, encrypt, or both. Initial value
    /// is the algorithm-byte default from ``capability(for:)``; the
    /// parser refines it from the self-signature key-flags subpacket
    /// (type 27) when one is present via ``withKeyFlags(_:)``.
    let capability: Capability

    /// Raw key-flags byte from the binding/self-signature, when one
    /// was parsed. Preserved verbatim so re-exporting a key emits the
    /// exact same flags it came in with — a [C]-only primary stays
    /// [C] on round-trip instead of becoming [SC]. Nil for keys
    /// whose import didn't see a parseable signature (the capability
    /// enum is then the source of truth).
    let keyFlags: UInt8?

    /// KDF parameters for ECDH subkeys: hash algorithm + symmetric KEK
    /// algorithm. Always `nil` for non-ECDH subkeys (RSA, ECDSA, EdDSA,
    /// X25519 native — the v6 native form bakes in SHA-256 + AES-128).
    let kdfParams: KDFParams?

    enum Capability: Sendable, Hashable, Codable {
        case sign
        case encrypt
        case signAndEncrypt
        /// Key flags exist but advertise neither sign (0x02), cert
        /// (0x01), nor encrypt (0x04 | 0x08) — typically a 0x20
        /// authentication-only key. This agent doesn't expose such
        /// keys for PKSIGN or PKDECRYPT; both gates return false.
        /// Distinguished from ``sign`` to avoid silently widening
        /// the auth-only key into a signing key in the agent's
        /// runtime gating and in `gpg --list-keys` output.
        case other

        var canSign: Bool { self == .sign || self == .signAndEncrypt }
        var canEncrypt: Bool { self == .encrypt || self == .signAndEncrypt }
    }

    /// ECDH KDF parameters carried inside the public-key packet
    /// (RFC 9580 §5.5.5.6). One reserved byte (always 1), then the
    /// OpenPGP hash algorithm ID and the AES-Wrap KEK algorithm ID.
    struct KDFParams: Sendable, Hashable, Codable {
        /// OpenPGP hash algorithm ID: 8 = SHA-256, 9 = SHA-384,
        /// 10 = SHA-512. Used to derive the KEK from the ECDH shared
        /// secret.
        let hashAlgo: UInt8
        /// OpenPGP symmetric algorithm ID: 7 = AES-128, 8 = AES-192,
        /// 9 = AES-256. Determines KEK length and the AESWRAP variant
        /// used to unwrap the session key.
        let kekAlgo: UInt8
    }

    enum PublicMaterial: Sendable, Hashable {
        case rsa(n: Data, e: Data)
        case ec(q: Data)
    }

    enum SecretMaterial: Sendable, Hashable {
        case rsa(d: Data, p: Data, q: Data, u: Data)
        /// EC scalar `d`. For Ed25519 (both legacy and native) this is
        /// the 32-byte seed exactly as GPG stores it. For ECDH cv25519
        /// it's the 32-byte X25519 scalar; for ECDH P-256 the 32-byte
        /// big-endian secret scalar.
        case ec(d: Data)
    }

    /// Apply a key-flags byte from a parsed signature packet. Stores
    /// the raw value (so export can emit identical flags) and
    /// recomputes the capability enum used by the agent's runtime
    /// gating.
    func withKeyFlags(_ flags: UInt8) -> OpenPGPSubkey {
        OpenPGPSubkey(
            algorithm: algorithm,
            creationTime: creationTime,
            publicMaterial: publicMaterial,
            secretMaterial: secretMaterial,
            fingerprint: fingerprint,
            keygrip: keygrip,
            isPrimary: isPrimary,
            capability: Self.capabilityFromKeyFlags(flags),
            keyFlags: flags,
            kdfParams: kdfParams
        )
    }

    /// Map an OpenPGP key-flags bitmap to the coarse-grained
    /// capability enum used for runtime gating. RFC 9580 §5.2.3.29:
    ///   0x01 = certify, 0x02 = sign,
    ///   0x04 = encrypt-comm, 0x08 = encrypt-storage,
    ///   0x10 = split key, 0x20 = authenticate,
    ///   0x40 = unused, 0x80 = group key.
    ///
    /// Certify (0x01) is treated as sign-capable for runtime gating
    /// because gpg uses PKSIGN for certification signatures
    /// (`gpg --sign-key`); refusing those would lose legitimate
    /// functionality. Anything that carries neither sign/cert nor
    /// encrypt flags (e.g. 0x20 authenticate-only, 0x80 group key)
    /// becomes ``.other`` so neither PKSIGN nor PKDECRYPT will
    /// surface the key.
    ///
    /// Export-side flag emission preserves the raw bitmap, so a
    /// [C]-only primary doesn't get re-advertised as [SC] — see
    /// ``OpenPGPSubkey/keyFlags`` and ``OpenPGPPublicKeyExport``.
    static func capabilityFromKeyFlags(_ flags: UInt8) -> Capability {
        let canSign = (flags & (0x02 | 0x01)) != 0
        let canEncrypt = (flags & 0x0C) != 0
        switch (canSign, canEncrypt) {
        case (true, true): return .signAndEncrypt
        case (true, false): return .sign
        case (false, true): return .encrypt
        case (false, false): return .other
        }
    }
}

/// The result of parsing an exported secret-key block.
nonisolated struct OpenPGPSecretKeyImport: Sendable, Hashable {
    /// Every subkey we successfully decoded with usable secret material.
    /// May include the primary (signing primaries do exist) and any
    /// number of subkeys; order matches packet order.
    var subkeys: [OpenPGPSubkey]

    /// Primary subkey if present. Useful for picking a human-facing
    /// fingerprint to label the imported key with.
    var primary: OpenPGPSubkey? { subkeys.first(where: { $0.isPrimary }) }
}

// MARK: - Errors

nonisolated enum OpenPGPParseError: Error, LocalizedError, Equatable {
    case truncated
    case malformedPacketHeader
    case unsupportedVersion(UInt8)
    case unsupportedAlgorithm(UInt8)
    case encryptedSecretKey
    case unsupportedCurve
    case noUsableSubkeys
    case malformedMPI
    case malformedOID
    case malformedKDFParams
    case publicKeyBlockProvided

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "Key data is incomplete — the import was cut short."
        case .malformedPacketHeader:
            return "Key data is not a valid OpenPGP packet stream."
        case .unsupportedVersion(let v):
            return "OpenPGP key version \(v) is not supported yet."
        case .unsupportedAlgorithm(let a):
            return "Public-key algorithm \(a) is not supported. Only RSA, ECDSA P-256, Ed25519, and ECDH on Curve25519/P-256 are accepted."
        case .encryptedSecretKey:
            return "This GPG key is passphrase-protected. Re-export it without a passphrase (gpg --export-secret-keys after removing the passphrase) and try again."
        case .unsupportedCurve:
            return "Elliptic curve not supported. Only NIST P-256, Ed25519, and Curve25519 are accepted."
        case .noUsableSubkeys:
            return "No usable subkeys were found in this key."
        case .malformedMPI:
            return "Malformed multi-precision integer in the key packet."
        case .malformedOID:
            return "Malformed curve OID in the key packet."
        case .malformedKDFParams:
            return "Malformed ECDH KDF parameters in the key packet."
        case .publicKeyBlockProvided:
            return "This is a public-key block (PGP PUBLIC KEY BLOCK). The agent needs the private material — re-export with `gpg --export-secret-keys --armor <KEYID>` after removing the passphrase, then import that block."
        }
    }
}

// MARK: - Parser entry point

nonisolated enum OpenPGPPacket {

    /// Parse an exported secret-key block. Accepts ASCII-armored input
    /// (the typical `gpg --export-secret-keys --armor` output) or raw
    /// binary packets. The caller is responsible for ensuring the input
    /// is in fact a secret-key export — passing a public-key export will
    /// return ``OpenPGPParseError/noSignableSubkeys`` because no usable
    /// secret material will be found.
    static func parseSecretKeyExport(_ input: Data) throws -> OpenPGPSecretKeyImport {
        let binary = try dearmorIfNeeded(input)
        var reader = PacketReader(data: binary)

        var subkeys: [OpenPGPSubkey] = []
        var sawPublicOnlyPacket = false
        // Signatures in an OpenPGP key block follow the key they bind:
        // a user-ID self-signature (type 0x13) describes the primary's
        // key flags; a subkey-binding signature (type 0x18) describes
        // the most recent subkey's flags. Both forms carry the type-27
        // key-flags subpacket whose bitmap is the source of truth for
        // sign / encrypt capability — the algorithm byte alone is
        // ambiguous (RSA algo 1 in particular is regularly used for
        // [SC]-only primaries with encryption delegated to a subkey).
        //
        // `currentTargetIndex` tracks the index in `subkeys` that
        // subsequent signature packets describe. It's set only when
        // a tag-5/7 packet successfully parses; if a subkey is
        // SKIPPED (unsupported algorithm like ElGamal), we clear it
        // so the orphaned binding signature doesn't get attributed
        // to the previous key — a real-world hazard since
        // RSA-primary + ElGamal-encrypt-subkey was a common GPG
        // layout and the ElGamal binding-sig encrypt flags would
        // otherwise re-paint the RSA primary as encryption-only.
        var currentTargetIndex: Int? = nil
        while reader.hasMore {
            guard let packet = try reader.readPacket() else { break }
            switch packet.tag {
            case 5, 7:  // Secret-Key Packet (primary) / Secret-Subkey Packet
                if let parsed = try parseSecretKeyPacket(packet.body, isPrimary: packet.tag == 5) {
                    subkeys.append(parsed)
                    currentTargetIndex = subkeys.count - 1
                } else {
                    // Skipped (unsupported algorithm) — subsequent
                    // sigs targeting THIS subkey must be discarded,
                    // not applied to whatever key came before.
                    currentTargetIndex = nil
                }
            case 2:  // Signature Packet
                // Apply key-flag bytes to the current target. Skipped
                // when there's no target (post-skipped-subkey) or
                // when the sig doesn't carry a key-flags subpacket.
                if let target = currentTargetIndex,
                   let flags = parseSignatureKeyFlags(packet.body) {
                    subkeys[target] = subkeys[target].withKeyFlags(flags)
                }
            case 6, 14:
                // Public-Key Packet / Public-Subkey Packet. Useful for
                // distinguishing "public-key block accidentally supplied
                // for import" (the common user error) from "key has no
                // usable subkeys we recognise". Binary streams never
                // include an armor header to lean on; this is the
                // signal we get instead.
                sawPublicOnlyPacket = true
                continue
            default:
                // Ignore: user IDs (13), trust (12), etc.
                continue
            }
        }

        if subkeys.isEmpty {
            if sawPublicOnlyPacket {
                throw OpenPGPParseError.publicKeyBlockProvided
            }
            throw OpenPGPParseError.noUsableSubkeys
        }
        return OpenPGPSecretKeyImport(subkeys: subkeys)
    }

    /// Parse the hashed-subpacket area of a v4 signature packet and
    /// return the key-flags byte (subpacket type 27) if present.
    /// Returns nil for non-v4 sigs, malformed packets, or sigs that
    /// don't carry the subpacket. The unhashed area is intentionally
    /// not consulted — only hashed subpackets are signed, so a
    /// forged unhashed key-flags entry would lift capability without
    /// the cert's blessing.
    private static func parseSignatureKeyFlags(_ body: Data) -> UInt8? {
        var r = ByteReader(data: body)
        // v4 sig prefix: version (1) + sig type (1) + pubkey algo (1) + hash algo (1)
        guard let version = r.readUInt8(), version == 4 else { return nil }
        guard r.read(count: 3) != nil else { return nil }
        // Hashed subpacket count (2 bytes BE) + N bytes of subpackets.
        guard let high = r.readUInt8(), let low = r.readUInt8() else { return nil }
        let hashedLen = (Int(high) << 8) | Int(low)
        guard let hashedArea = r.read(count: hashedLen) else { return nil }
        return findKeyFlagsSubpacket(hashedArea)
    }

    /// Walk a hashed-subpacket area looking for the key-flags
    /// subpacket (type 27). Subpacket length encoding follows RFC 9580
    /// §5.2.3.1: 1, 2, or 5 octets.
    private static func findKeyFlagsSubpacket(_ area: Data) -> UInt8? {
        var r = ByteReader(data: area)
        while r.position < area.endIndex {
            guard let first = r.readUInt8() else { return nil }
            let totalLen: Int
            switch first {
            case 0..<192:
                totalLen = Int(first)
            case 192..<255:
                guard let second = r.readUInt8() else { return nil }
                totalLen = ((Int(first) - 192) << 8) + Int(second) + 192
            case 255:
                guard let bytes = r.read(count: 4) else { return nil }
                totalLen = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16)
                         | (Int(bytes[2]) << 8) | Int(bytes[3])
            default:
                return nil
            }
            guard totalLen >= 1 else { return nil }
            guard let typeByte = r.readUInt8() else { return nil }
            // High bit of the type byte is the "critical" flag —
            // strip it before comparing.
            let type = typeByte & 0x7F
            let bodyLen = totalLen - 1
            guard let bodyBytes = r.read(count: bodyLen) else { return nil }
            if type == 27, let first = bodyBytes.first {
                return first
            }
        }
        return nil
    }

    // Key-flags → capability mapping lives on
    // ``OpenPGPSubkey/capabilityFromKeyFlags`` so the same logic
    // covers both fresh imports and ``withKeyFlags`` updates.

    // MARK: - Secret-key packet body

    private static func parseSecretKeyPacket(_ body: Data, isPrimary: Bool) throws -> OpenPGPSubkey? {
        var r = ByteReader(data: body)

        // Public-key portion: version + ctime + algo + algo-specific
        // public params (RFC 9580 §5.5.2).
        guard let version: UInt8 = r.readUInt8() else { throw OpenPGPParseError.truncated }
        guard version == 4 else { throw OpenPGPParseError.unsupportedVersion(version) }

        guard let ctime: UInt32 = r.readUInt32BE() else { throw OpenPGPParseError.truncated }
        guard let algoByte: UInt8 = r.readUInt8() else { throw OpenPGPParseError.truncated }

        let (algorithm, publicMaterial, kdfParams, publicParamsRange) = try readPublicParams(reader: &r, algoByte: algoByte)
        if case .unsupported = algorithm {
            // Not usable — skip silently. We've still walked past the
            // public-params bytes via `skipToEnd`, so subsequent packets
            // parse correctly.
            return nil
        }

        // Secret-key portion: S2K usage byte determines whether the
        // secret material is encrypted. MVP rejects any encryption.
        guard let s2kUsage: UInt8 = r.readUInt8() else { throw OpenPGPParseError.truncated }
        guard s2kUsage == 0 else { throw OpenPGPParseError.encryptedSecretKey }

        let secretMaterial: OpenPGPSubkey.SecretMaterial
        switch algorithm {
        case .rsa:
            guard let d = r.readMPI(), let p = r.readMPI(), let q = r.readMPI(), let u = r.readMPI() else {
                throw OpenPGPParseError.malformedMPI
            }
            secretMaterial = .rsa(d: d, p: p, q: q, u: u)
        case .ecdsa, .eddsaLegacy, .ecdh:
            guard let d = r.readMPI() else { throw OpenPGPParseError.malformedMPI }
            secretMaterial = .ec(d: d)
        case .ed25519Native, .x25519Native:
            // v6 raw scalar — 32 bytes verbatim, no MPI framing.
            guard let scalar = r.read(count: 32) else { throw OpenPGPParseError.truncated }
            secretMaterial = .ec(d: scalar)
        case .unsupported:
            return nil
        }

        // 2-byte checksum (sum of secret bytes mod 65536) follows for
        // S2K usage 0. We don't validate it — if the bytes round-tripped
        // through the user's `gpg` install they're already trustworthy.
        _ = r.read(count: 2)

        let fingerprint = computeV4Fingerprint(
            version: version,
            creationTime: ctime,
            algoByte: algoByte,
            publicParams: body.subdata(in: publicParamsRange)
        )
        let keygrip = try Keygrip.compute(algorithm: algorithm, publicMaterial: publicMaterial)

        return OpenPGPSubkey(
            algorithm: algorithm,
            creationTime: ctime,
            publicMaterial: publicMaterial,
            secretMaterial: secretMaterial,
            fingerprint: fingerprint,
            keygrip: keygrip,
            isPrimary: isPrimary,
            capability: capability(for: algoByte),
            keyFlags: nil,
            kdfParams: kdfParams
        )
    }

    /// Default capability per OpenPGP public-key algorithm byte
    /// (RFC 9580 §9.1). The algorithm byte alone is *not* the source
    /// of truth for sign / encrypt usage — that lives in the
    /// self-signature's key-flags subpacket. ``parseSignatureKeyFlags``
    /// overrides this default once a signature arrives. The values
    /// here are conservative starting points used if the export omits
    /// signatures (rare) or if signature parsing fails:
    ///
    /// * RSA primaries (algo 1) often serve [SC] only with encryption
    ///   delegated to a dedicated subkey, so we default to ``.sign``
    ///   rather than ``.signAndEncrypt``.
    /// * Algo-pinned roles (ECDH = 18, X25519 = 25) keep their
    ///   single-purpose defaults; an ECDH subkey can only ever
    ///   encrypt regardless of what its (missing) self-sig might say.
    private static func capability(for algoByte: UInt8) -> OpenPGPSubkey.Capability {
        switch algoByte {
        case 1: return .sign                  // RSA — conservative; signatures upgrade to SCE
        case 2: return .encrypt               // RSA encrypt-only
        case 3: return .sign                  // RSA sign-only
        case 17: return .sign                 // DSA
        case 18: return .encrypt              // ECDH
        case 19: return .sign                 // ECDSA
        case 22: return .sign                 // EdDSA legacy
        case 25: return .encrypt              // X25519 native (v6)
        case 27: return .sign                 // Ed25519 native (v6)
        default: return .sign
        }
    }

    private static func readPublicParams(
        reader r: inout ByteReader,
        algoByte: UInt8
    ) throws -> (OpenPGPAlgorithm, OpenPGPSubkey.PublicMaterial, OpenPGPSubkey.KDFParams?, Range<Data.Index>) {
        let start = r.position

        switch algoByte {
        case 1, 2, 3:  // RSA (sign+encrypt, encrypt-only, sign-only)
            guard let n = r.readMPI(), let e = r.readMPI() else { throw OpenPGPParseError.malformedMPI }
            return (.rsa, .rsa(n: n, e: e), nil, start..<r.position)

        case 18:  // ECDH
            guard let oid = r.readShortOID() else { throw OpenPGPParseError.malformedOID }
            guard let curve = ECCurve.from(oidBytes: oid) else { throw OpenPGPParseError.unsupportedCurve }
            // ECDH is defined for cv25519 and P-256 in this build. Other
            // curves (P-384, P-521, brainpool, X448) need their own
            // keygrip + decryption plumbing.
            guard curve == .p256 || curve == .cv25519 else { throw OpenPGPParseError.unsupportedCurve }
            guard let q = r.readMPI() else { throw OpenPGPParseError.malformedMPI }
            // KDF parameter block (RFC 9580 §5.5.5.6):
            //   1 octet  length of the following fields (always 3)
            //   1 octet  reserved (always 1)
            //   1 octet  KDF hash algorithm
            //   1 octet  KEK symmetric algorithm
            guard let kdfLen = r.readUInt8(), kdfLen == 3,
                  let reserved = r.readUInt8(), reserved == 0x01,
                  let hashAlgo = r.readUInt8(),
                  let kekAlgo = r.readUInt8() else {
                throw OpenPGPParseError.malformedKDFParams
            }
            let kdf = OpenPGPSubkey.KDFParams(hashAlgo: hashAlgo, kekAlgo: kekAlgo)
            return (.ecdh(curve), .ec(q: q), kdf, start..<r.position)

        case 19:  // ECDSA
            guard let oid = r.readShortOID() else { throw OpenPGPParseError.malformedOID }
            guard let curve = ECCurve.from(oidBytes: oid) else { throw OpenPGPParseError.unsupportedCurve }
            // Only P-256 is in scope for the MVP. Reject e.g. P-384 keys
            // up-front so we don't claim to support a curve we can't sign with.
            guard curve == .p256 else { throw OpenPGPParseError.unsupportedCurve }
            guard let q = r.readMPI() else { throw OpenPGPParseError.malformedMPI }
            return (.ecdsa(curve), .ec(q: q), nil, start..<r.position)

        case 22:  // EdDSA (legacy Ed25519)
            guard let oid = r.readShortOID() else { throw OpenPGPParseError.malformedOID }
            guard let curve = ECCurve.from(oidBytes: oid), curve == .ed25519 else {
                throw OpenPGPParseError.unsupportedCurve
            }
            guard let q = r.readMPI() else { throw OpenPGPParseError.malformedMPI }
            return (.eddsaLegacy(curve), .ec(q: q), nil, start..<r.position)

        case 25:  // X25519 native (RFC 9580 v6) — 32-byte raw public point, no MPI
            guard let q = r.read(count: 32) else { throw OpenPGPParseError.truncated }
            return (.x25519Native, .ec(q: q), nil, start..<r.position)

        case 27:  // Ed25519 native (RFC 9580 v6) — 32-byte raw public point, no MPI
            guard let q = r.read(count: 32) else { throw OpenPGPParseError.truncated }
            return (.ed25519Native, .ec(q: q), nil, start..<r.position)

        default:
            // Step the cursor to the end of the packet — we'll be ignoring
            // this subkey anyway, but the outer loop expects the reader to
            // be at a packet boundary.
            r.skipToEnd()
            return (.unsupported(rawID: algoByte), .ec(q: Data()), nil, start..<r.position)
        }
    }

    // MARK: - Fingerprint

    /// RFC 9580 §5.5.4 v4 fingerprint: SHA-1 over a structured prefix
    /// plus the public-key packet's public-portion bytes.
    private static func computeV4Fingerprint(
        version: UInt8,
        creationTime: UInt32,
        algoByte: UInt8,
        publicParams: Data
    ) -> Data {
        // The hashed prefix is: 0x99 || 2-byte length || version || ctime || algo || publicParams
        // The length covers everything after the length itself: 1 (version) + 4 (ctime) + 1 (algo) + |publicParams|.
        let innerLength = 1 + 4 + 1 + publicParams.count
        var buf = Data()
        buf.append(0x99)
        buf.append(UInt8((innerLength >> 8) & 0xFF))
        buf.append(UInt8(innerLength & 0xFF))
        buf.append(version)
        buf.appendUInt32BE(creationTime)
        buf.append(algoByte)
        buf.append(publicParams)
        return Data(Insecure.SHA1.hash(data: buf))
    }

    // MARK: - ASCII Armor

    private static func dearmorIfNeeded(_ input: Data) throws -> Data {
        // Cheap detection: starts with "-----BEGIN PGP".
        let prefix = Data("-----BEGIN PGP".utf8)
        guard input.starts(with: prefix) else { return input }

        guard let text = String(data: input, encoding: .utf8) else {
            throw OpenPGPParseError.malformedPacketHeader
        }

        // Reject public-key blocks up-front with a clearer error than
        // "no usable subkeys". The header line is the only piece of
        // metadata we have that distinguishes a public export from a
        // secret export before parsing the packets.
        if text.contains("-----BEGIN PGP PUBLIC KEY BLOCK-----") {
            throw OpenPGPParseError.publicKeyBlockProvided
        }

        var inBody = false
        var b64 = ""
        // omittingEmptySubsequences MUST stay false — the empty line
        // that separates armor headers from the base64 body is what
        // flips us into body-collection mode below. Dropping it means
        // `inBody` never becomes true and b64 stays empty.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN PGP") {
                // Skip headers up to the blank line.
                inBody = false
                continue
            }
            if line.hasPrefix("-----END PGP") {
                break
            }
            if !inBody {
                // The first blank line marks end of armor headers.
                if line.isEmpty { inBody = true }
                continue
            }
            // CRC line starts with "=" and is followed by 4 base64 chars.
            // We don't verify the CRC for MVP — gpg already produced it.
            if line.hasPrefix("=") { continue }
            b64 += line
        }

        guard let decoded = Data(base64Encoded: b64) else {
            throw OpenPGPParseError.malformedPacketHeader
        }
        return decoded
    }
}

// MARK: - Packet framing

private nonisolated struct ParsedPacket {
    let tag: Int
    let body: Data
}

private nonisolated struct PacketReader {
    let data: Data
    var position: Data.Index

    init(data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    var hasMore: Bool { position < data.endIndex }

    /// Read one OpenPGP packet (RFC 9580 §4). Supports both legacy
    /// format (bit 6 of tag byte clear) and new format (bit 6 set) with
    /// one-, two-, and five-octet length headers. The rare
    /// partial-body-length encoding is rejected — secret-key packets
    /// don't use it.
    mutating func readPacket() throws -> ParsedPacket? {
        guard position < data.endIndex else { return nil }
        let tagByte = data[position]; position = data.index(after: position)
        guard (tagByte & 0x80) != 0 else { throw OpenPGPParseError.malformedPacketHeader }

        let newFormat = (tagByte & 0x40) != 0
        let tag: Int
        let length: Int
        if newFormat {
            tag = Int(tagByte & 0x3F)
            guard let lengthFirst = consume() else { throw OpenPGPParseError.truncated }
            switch lengthFirst {
            case 0..<192:
                length = Int(lengthFirst)
            case 192..<224:
                guard let second = consume() else { throw OpenPGPParseError.truncated }
                length = ((Int(lengthFirst) - 192) << 8) + Int(second) + 192
            case 255:
                guard let bytes = consume(4) else { throw OpenPGPParseError.truncated }
                length = (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
            default:
                // 224..254 → partial body lengths, not used by secret-key packets.
                throw OpenPGPParseError.malformedPacketHeader
            }
        } else {
            tag = Int((tagByte & 0x3C) >> 2)
            let lengthType = Int(tagByte & 0x03)
            switch lengthType {
            case 0:
                guard let b = consume() else { throw OpenPGPParseError.truncated }
                length = Int(b)
            case 1:
                guard let bs = consume(2) else { throw OpenPGPParseError.truncated }
                length = (Int(bs[0]) << 8) | Int(bs[1])
            case 2:
                guard let bs = consume(4) else { throw OpenPGPParseError.truncated }
                length = (Int(bs[0]) << 24) | (Int(bs[1]) << 16) | (Int(bs[2]) << 8) | Int(bs[3])
            default:
                throw OpenPGPParseError.malformedPacketHeader
            }
        }

        guard length >= 0, data.index(position, offsetBy: length, limitedBy: data.endIndex) != nil else {
            throw OpenPGPParseError.truncated
        }
        let end = data.index(position, offsetBy: length)
        let body = data.subdata(in: position..<end)
        position = end
        return ParsedPacket(tag: tag, body: body)
    }

    private mutating func consume() -> UInt8? {
        guard position < data.endIndex else { return nil }
        let v = data[position]
        position = data.index(after: position)
        return v
    }

    private mutating func consume(_ n: Int) -> [UInt8]? {
        guard let end = data.index(position, offsetBy: n, limitedBy: data.endIndex) else { return nil }
        let slice = Array(data[position..<end])
        position = end
        return slice
    }
}

// MARK: - Byte reader for packet bodies

private nonisolated struct ByteReader {
    let data: Data
    var position: Data.Index

    init(data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    mutating func readUInt8() -> UInt8? {
        guard position < data.endIndex else { return nil }
        let v = data[position]
        position = data.index(after: position)
        return v
    }

    mutating func readUInt32BE() -> UInt32? {
        guard let end = data.index(position, offsetBy: 4, limitedBy: data.endIndex) else { return nil }
        var v: UInt32 = 0
        for i in position..<end {
            v = (v << 8) | UInt32(data[i])
        }
        position = end
        return v
    }

    mutating func read(count: Int) -> Data? {
        guard let end = data.index(position, offsetBy: count, limitedBy: data.endIndex) else { return nil }
        let chunk = data.subdata(in: position..<end)
        position = end
        return chunk
    }

    mutating func skipToEnd() {
        position = data.endIndex
    }

    /// OpenPGP MPI: 2-byte big-endian bit length, then ceil(bits/8) bytes.
    /// Returned bytes are exactly what the packet held — no leading zeros
    /// added, no stripping. Callers that need a fixed-width canonical
    /// form must pad themselves.
    mutating func readMPI() -> Data? {
        guard let high = readUInt8(), let low = readUInt8() else { return nil }
        let bitLen = (Int(high) << 8) | Int(low)
        let byteLen = (bitLen + 7) / 8
        return read(count: byteLen)
    }

    /// OpenPGP "short" OID encoding used in ECDSA/EdDSA public keys: one
    /// length byte (≤127) followed by that many bytes of raw OID DER
    /// (without the outer tag/length prefix).
    mutating func readShortOID() -> Data? {
        guard let len = readUInt8() else { return nil }
        // 0 and 0xFF are reserved per RFC 9580.
        guard len > 0 && len < 0xFF else { return nil }
        return read(count: Int(len))
    }
}

// MARK: - Data helpers

private nonisolated extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}
