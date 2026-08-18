//
//  OpenPGPPublicKeyExport.swift
//  rootshell
//
//  Produces an ASCII-armored OpenPGP "transferable public key" block
//  from an ``SSHKey`` so the remote can `gpg --import` it and then
//  ask the forwarded GPG agent to sign with the corresponding
//  keygrip. Without this, agent-forwarded signing is unreachable —
//  the remote has no way to know the key exists.
//
//  Structure of the emitted block (RFC 9580 §10.1):
//    * Primary Public-Key packet (tag 6) — version 4, algorithm-
//      specific public params built from the SSH key's cached public
//      material.
//    * User-ID packet (tag 13) — UTF-8 string like "Name <email>".
//    * Positive certification self-signature (tag 2, sig type 0x13) —
//      computed by signing the key + user-ID + hashed subpackets
//      with the SSH key itself via ``SSHKeyGPGBridge/signRaw``. This
//      is the step that triggers a biometric / NFC / YubiKey prompt.
//
//  The hashed subpackets we emit are the minimum set the GPG client
//  requires to accept the import: signature creation time, key flags
//  (certify + sign), preferred hash algorithm (SHA-256), and the
//  issuer fingerprint. The issuer key ID goes in the unhashed area
//  for client compatibility.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto

/// `@MainActor` because `export` takes `SSHKeyManager.shared` / `GPGKeyManager.shared`
/// as default arguments — those globals are MainActor-isolated and the
/// default-argument expression has to resolve in a MainActor context.
/// The body itself runs async and offloads CPU-bound work to the
/// nonisolated GPG helpers (`SSHKeyGPGBridge.signRaw`, etc.) which
/// hop to the cooperative pool on their own.
@MainActor
enum OpenPGPPublicKeyExport {

    /// Errors surfaced by the export path. Failures from the
    /// underlying signer (auth cancelled, hardware not present, etc.)
    /// surface their original error untouched.
    enum ExportError: Error, LocalizedError {
        case keyTypeUnsupported(String)
        case noCachedPublicMaterial
        case userIDEmpty
        case keyAuthRequired(String)

        var errorDescription: String? {
            switch self {
            case .keyTypeUnsupported(let what):
                return "OpenPGP export is not supported for \(what)."
            case .noCachedPublicMaterial:
                return "This key has no cached public material; reopen the app to backfill, then try again."
            case .userIDEmpty:
                return "Please provide a user ID (name or email) for the OpenPGP key."
            case .keyAuthRequired(let detail):
                return "Authentication required to export: \(detail)"
            }
        }
    }

    /// Build an ASCII-armored OpenPGP public key for `sshKey` with
    /// the given user ID string (typically `"Name <email>"`).
    ///
    /// `creationDate` lets callers pin the OpenPGP creation timestamp
    /// — it's part of the v4 fingerprint, so re-exporting with a
    /// different value yields a different OpenPGP key. Default is the
    /// SSH key's import date so successive exports of the same SSH
    /// key produce the same OpenPGP key.
    ///
    /// Performs up to two private-key operations (self-signature plus
    /// the encryption subkey's binding signature when one is emitted),
    /// which will surface the SSH key's normal auth prompts — Face ID,
    /// passcode, YubiKey PIN/touch — exactly as if the user were
    /// using the key for SSH.
    static func export(
        sshKey: SSHKey,
        userID: String,
        creationDate: Date? = nil,
        keyManager: SSHKeyManager? = nil
    ) async throws -> String {
        // Default-arg expressions in Swift 6 evaluate in a nonisolated
        // context, so `keyManager: SSHKeyManager = .shared` would
        // trip strict-concurrency (the global is MainActor-isolated).
        // Resolve inside the body where the enum's MainActor isolation
        // is in scope.
        let keyManager = keyManager ?? SSHKeyManager.shared
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty else { throw ExportError.userIDEmpty }

        // 1. Resolve algorithm + public material from the SSH key.
        let variant: SSHPrivateKeyVariant
        if sshKey.authRequirement == .none {
            variant = try await keyManager.loadPrivateKey(id: sshKey.id)
        } else {
            variant = try await keyManager.loadPrivateKeyWithAuth(id: sshKey.id)
        }
        guard let (algorithm, publicMaterial) = SSHKeyGPGBridge.openPGPPublicMaterial(
            for: variant, keyType: sshKey.keyType
        ) else {
            throw ExportError.keyTypeUnsupported(sshKey.keyType.rawValue)
        }

        // 2. Build the public-key packet body (v4) and compute its
        //    fingerprint. Using the SSH key's createdDate keeps the
        //    OpenPGP fingerprint stable across re-exports.
        let ctime = UInt32(truncatingIfNeeded: Int(
            (creationDate ?? sshKey.createdDate).timeIntervalSince1970
        ))
        let pubKeyBody = buildPublicKeyPacketBody(
            version: 4,
            ctime: ctime,
            algorithm: algorithm,
            publicMaterial: publicMaterial
        )
        let fingerprint = computeV4Fingerprint(packetBody: pubKeyBody)

        // 3. Build the user-ID packet body.
        let userIDBody = Data(trimmedUserID.utf8)

        // 4. Build the hashed subpackets for a positive-certification
        //    self-signature. Order doesn't matter to gpg but the
        //    bytes are part of the signed digest so they MUST be
        //    written identically to what we hash. Key flags reflect
        //    the primary's actual capability: RSA bridges to SCE,
        //    ECDSA / EdDSA to sign-only (encryption needs a subkey).
        let primaryCapability = sshKeyCapability(for: algorithm)
        let hashedSubpackets = buildHashedSubpackets(
            ctime: ctime,
            fingerprint: fingerprint,
            keyFlags: primaryKeyFlags(for: primaryCapability)
        )
        let unhashedSubpackets = buildUnhashedSubpackets(fingerprint: fingerprint)

        // 5. Compute the to-be-signed digest per RFC 9580 §5.2.4.
        let pubAlgoByte = openPGPPublicKeyAlgorithmByte(for: algorithm)
        let sigData = buildSignatureDataForHashing(
            version: 4,
            sigType: 0x13,  // positive certification of a user ID and public key
            pubKeyAlgo: pubAlgoByte,
            hashAlgo: 8,    // SHA-256
            hashedSubpackets: hashedSubpackets
        )
        let toBeHashed = buildCertificationHashInput(
            publicKeyPacketBody: pubKeyBody,
            userIDBody: userIDBody,
            sigData: sigData
        )
        let digest = Data(SHA256.hash(data: toBeHashed))

        // 6. Sign the digest with the SSH key.
        let rawSig: SSHKeyGPGBridge.RawSignature
        do {
            rawSig = try await SSHKeyGPGBridge.signRaw(
                variant: variant,
                keyType: sshKey.keyType,
                hash: digest,
                hashAlgorithm: .sha256
            )
        } catch {
            throw ExportError.keyAuthRequired(error.localizedDescription)
        }

        // 7. Assemble the signature packet body.
        let sigPacketBody = buildSignaturePacketBody(
            sigData: sigData,
            unhashedSubpackets: unhashedSubpackets,
            digestLeft16: Data(digest.prefix(2)),
            rawSignature: rawSig,
            algorithm: algorithm
        )

        // 8. Wrap each packet body in an OpenPGP packet header (new
        //    format, tag + length) and concatenate.
        var stream = Data()
        stream.append(writeNewFormatPacket(tag: 6, body: pubKeyBody))     // Primary public key
        stream.append(writeNewFormatPacket(tag: 13, body: userIDBody))    // User ID
        stream.append(writeNewFormatPacket(tag: 2, body: sigPacketBody))  // Self-signature

        // 9. Optional ECDH encryption subkey. RSA primaries already
        //    advertise encryption on the self-signature (SCE), so the
        //    subkey would be redundant. ECDSA / Ed25519 primaries
        //    can't encrypt cryptographically, so we emit a separate
        //    ECDH subkey: P-256 ECDH for ECDSA, cv25519 ECDH (with
        //    X25519 public point derived from the Ed25519 seed) for
        //    Ed25519.
        if !primaryCapability.canEncrypt,
           let (encAlg, encMaterial) = SSHKeyGPGBridge.openPGPEncryptionPublicMaterial(
               for: variant, keyType: sshKey.keyType
           ) {
            let subkeyPackets = try await buildEncryptionSubkeyAndBinding(
                primaryPublicKeyBody: pubKeyBody,
                primarySigningVariant: variant,
                primaryKeyType: sshKey.keyType,
                primarySigningAlgorithm: algorithm,
                ctime: ctime,
                encryptionAlgorithm: encAlg,
                encryptionPublicMaterial: encMaterial
            )
            stream.append(subkeyPackets)
        }

        // 10. ASCII-armor and return.
        return armor(blockType: "PGP PUBLIC KEY BLOCK", body: stream)
    }

    /// Build an ECDH public-subkey packet (tag 14) plus its
    /// subkey-binding signature (tag 2, sig type 0x18) signed by the
    /// primary key. Returns the concatenated packet bytes.
    private static func buildEncryptionSubkeyAndBinding(
        primaryPublicKeyBody: Data,
        primarySigningVariant: SSHPrivateKeyVariant,
        primaryKeyType: SSHKey.KeyType,
        primarySigningAlgorithm: OpenPGPAlgorithm,
        ctime: UInt32,
        encryptionAlgorithm: OpenPGPAlgorithm,
        encryptionPublicMaterial: OpenPGPSubkey.PublicMaterial
    ) async throws -> Data {
        // Build the subkey's public-key packet body. For ECDH this is
        // version + ctime + algo(18) + OID + MPI(q) + KDF params (03 01 hash kek).
        let subkeyBody = buildECDHSubkeyPacketBody(
            version: 4,
            ctime: ctime,
            algorithm: encryptionAlgorithm,
            publicMaterial: encryptionPublicMaterial
        )

        let primaryPubAlgoByte = openPGPPublicKeyAlgorithmByte(for: primarySigningAlgorithm)
        // Subkey-binding signature: sig type 0x18, key flags 0x0C
        // (encrypt-comms + encrypt-storage). The primary's fingerprint
        // goes in the issuer subpackets.
        let primaryFingerprint = computeV4Fingerprint(packetBody: primaryPublicKeyBody)
        let bindingHashed = buildSubkeyBindingHashedSubpackets(
            ctime: ctime,
            primaryFingerprint: primaryFingerprint
        )
        let bindingUnhashed = buildUnhashedSubpackets(fingerprint: primaryFingerprint)
        let bindingSigData = buildSignatureDataForHashing(
            version: 4,
            sigType: 0x18,  // subkey-binding
            pubKeyAlgo: primaryPubAlgoByte,
            hashAlgo: 8,    // SHA-256
            hashedSubpackets: bindingHashed
        )
        let bindingHashInput = buildSubkeyBindingHashInput(
            primaryKeyPacketBody: primaryPublicKeyBody,
            subkeyPacketBody: subkeyBody,
            sigData: bindingSigData
        )
        let bindingDigest = Data(SHA256.hash(data: bindingHashInput))
        let bindingRawSig: SSHKeyGPGBridge.RawSignature
        do {
            bindingRawSig = try await SSHKeyGPGBridge.signRaw(
                variant: primarySigningVariant,
                keyType: primaryKeyType,
                hash: bindingDigest,
                hashAlgorithm: .sha256
            )
        } catch {
            throw ExportError.keyAuthRequired(error.localizedDescription)
        }
        let bindingSigBody = buildSignaturePacketBody(
            sigData: bindingSigData,
            unhashedSubpackets: bindingUnhashed,
            digestLeft16: Data(bindingDigest.prefix(2)),
            rawSignature: bindingRawSig,
            algorithm: primarySigningAlgorithm
        )

        var out = Data()
        out.append(writeNewFormatPacket(tag: 14, body: subkeyBody))     // Public subkey
        out.append(writeNewFormatPacket(tag: 2, body: bindingSigBody))  // Subkey-binding signature
        return out
    }

    /// Public-key packet body for an ECDH subkey. Same structure as
    /// `buildPublicKeyPacketBody` for ECDSA/EdDSA, with the addition
    /// of the trailing KDF parameter block (RFC 9580 §5.5.5.6):
    /// `0x03 0x01 hash_algo kek_algo`. Pinned to SHA-256 + AES-128
    /// — that's what `gpg --gen-key` writes for new cv25519 subkeys.
    private static func buildECDHSubkeyPacketBody(
        version: UInt8,
        ctime: UInt32,
        algorithm: OpenPGPAlgorithm,
        publicMaterial: OpenPGPSubkey.PublicMaterial
    ) -> Data {
        var body = Data()
        body.append(version)
        body.appendUInt32BE(ctime)
        body.append(openPGPPublicKeyAlgorithmByte(for: algorithm))

        switch (algorithm, publicMaterial) {
        case (.ecdh(let curve), .ec(let q)):
            let oid = openPGPCurveOID(for: curve)
            body.append(UInt8(oid.count))
            body.append(oid)
            body.append(encodeMPI(q))
        case (.rsa, .rsa(let n, let e)):
            // Treating an RSA key as an "encryption subkey" reuses
            // the same modulus + exponent shape as the signing
            // primary. Capability-only distinction.
            body.append(encodeMPI(n))
            body.append(encodeMPI(e))
        default:
            // Unhandled algorithm; caller checked first, so this is
            // defensive only.
            break
        }
        // KDF params: 03 01 hash kek (RFC 9580 §5.5.5.6). Only emit
        // for ECDH algorithms — RSA doesn't use this block.
        if case .ecdh = algorithm {
            body.append(0x03)  // length of the rest of this subpacket
            body.append(0x01)  // reserved
            body.append(0x08)  // SHA-256
            body.append(0x07)  // AES-128
        }
        return body
    }

    /// Hashed subpackets for an ECDH subkey-binding signature:
    /// creation time + key flags (encrypt-only). Key flags 0x0C =
    /// encrypt-communications (0x04) | encrypt-storage (0x08).
    private static func buildSubkeyBindingHashedSubpackets(
        ctime: UInt32,
        primaryFingerprint: Data
    ) -> Data {
        var subs = Data()

        var ctimeBytes = Data()
        ctimeBytes.appendUInt32BE(ctime)
        subs.append(writeSubpacket(type: 2, body: ctimeBytes))

        // Key flags = 0x04 (encrypt-comm) + 0x08 (encrypt-storage) = 0x0C
        subs.append(writeSubpacket(type: 27, body: Data([0x0C])))

        // Issuer fingerprint (type 33): 0x04 + 20-byte v4 fingerprint
        var issuerFp = Data([0x04])
        issuerFp.append(primaryFingerprint)
        subs.append(writeSubpacket(type: 33, body: issuerFp))

        return subs
    }

    /// Hash input for a subkey-binding signature (sig type 0x18):
    ///   0x99 || len2(primaryBody) || primaryBody ||
    ///   0x99 || len2(subkeyBody)  || subkeyBody  ||
    ///   sigData ||
    ///   0x04 || 0xFF || len4(sigData)
    private static func buildSubkeyBindingHashInput(
        primaryKeyPacketBody: Data,
        subkeyPacketBody: Data,
        sigData: Data
    ) -> Data {
        var buf = Data()
        // Primary public-key hashing prefix
        buf.append(0x99)
        buf.append(UInt8((primaryKeyPacketBody.count >> 8) & 0xFF))
        buf.append(UInt8(primaryKeyPacketBody.count & 0xFF))
        buf.append(primaryKeyPacketBody)

        // Subkey public-key hashing prefix
        buf.append(0x99)
        buf.append(UInt8((subkeyPacketBody.count >> 8) & 0xFF))
        buf.append(UInt8(subkeyPacketBody.count & 0xFF))
        buf.append(subkeyPacketBody)

        buf.append(sigData)

        buf.append(0x04)
        buf.append(0xFF)
        buf.appendUInt32BE(UInt32(sigData.count))
        return buf
    }

    /// GPGKey-flavoured export, parallel to ``export(sshKey:userID:)``
    /// for keys that were imported as native OpenPGP secret blocks
    /// (`Settings → GPG Keys`). Emits the chosen signing key as a
    /// standalone OpenPGP primary key — every other subkey is dropped.
    ///
    /// This is deliberate: the forwarded agent advertises each
    /// imported subkey's keygrip independently, and the remote `gpg`
    /// only knows about the keygrips whose public material is in its
    /// keyring. By exporting the *specific* keygrip the user wants
    /// the remote to sign with, we guarantee the remote has the
    /// matching public material. The cost is that the cert-only
    /// primary (when it exists) isn't part of the exported block — the
    /// fingerprint of the exported key matches the original *signing
    /// subkey*'s fingerprint, not the parent primary's.
    ///
    /// Pass `selectedKeygripHex` to target a specific subkey;
    /// otherwise the export prefers the primary (`isPrimary == true`)
    /// and falls back to the first subkey when there's no primary.
    ///
    /// The OpenPGP creation time is taken from the chosen subkey, so
    /// the v4 fingerprint matches the original — a remote that had
    /// imported the same key before will recognise it as the same key
    /// with a fresh self-signature and new user ID.
    static func export(
        gpgKey: GPGKey,
        userID: String,
        selectedKeygripHex: String? = nil,
        keyManager: GPGKeyManager? = nil
    ) async throws -> String {
        // See the SSH-export overload above for why the default arg is
        // resolved inside the body instead of via `= .shared`.
        let keyManager = keyManager ?? GPGKeyManager.shared
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty else { throw ExportError.userIDEmpty }

        let loaded: GPGLoadedKey
        do {
            loaded = try await keyManager.loadKeyWithAuth(
                id: gpgKey.id,
                reason: "Generate OpenPGP public-key block for \(gpgKey.name)"
            )
        } catch {
            throw ExportError.keyAuthRequired(error.localizedDescription)
        }

        let subkey: OpenPGPSubkey
        if let hex = selectedKeygripHex?.uppercased() {
            guard let match = loaded.subkey(forKeygrip: hex) else {
                throw ExportError.keyTypeUnsupported("requested keygrip not found in this key")
            }
            // The exported block self-signs its user ID and binds any
            // encryption subkey — both operations require a signing
            // key. Picking an encryption-only subkey here would
            // fail later at sign time with a confusing error.
            guard match.capability.canSign else {
                throw ExportError.keyTypeUnsupported("selected subkey can't sign (it's an encryption subkey)")
            }
            subkey = match
        } else if let picked = pickSigningSubkey(from: loaded.subkeys) {
            subkey = picked
        } else {
            throw ExportError.keyTypeUnsupported("no signing-capable subkey")
        }

        let pubKeyBody = buildPublicKeyPacketBody(
            version: 4,
            ctime: subkey.creationTime,
            algorithm: subkey.algorithm,
            publicMaterial: subkey.publicMaterial
        )
        // Use the fingerprint we already computed at import time —
        // recomputing would yield the same bytes (the public-key
        // packet is deterministic from algorithm + publicMaterial +
        // ctime), but this saves the SHA-1 hash.
        let fingerprint = subkey.fingerprint

        let userIDBody = Data(trimmedUserID.utf8)

        // Key flags: prefer the raw byte the importer captured from
        // the binding/self-signature, so a [C]-only primary stays
        // [C] on round-trip instead of being upgraded to [SC]. Fall
        // back to deriving from capability when the imported key
        // pre-dates signature parsing (schemaVersion=1).
        let flagsByte = subkey.keyFlags ?? primaryKeyFlags(for: subkey.capability)
        let hashedSubpackets = buildHashedSubpackets(
            ctime: subkey.creationTime,
            fingerprint: fingerprint,
            keyFlags: flagsByte
        )
        let unhashedSubpackets = buildUnhashedSubpackets(fingerprint: fingerprint)

        let pubAlgoByte = openPGPPublicKeyAlgorithmByte(for: subkey.algorithm)
        let sigData = buildSignatureDataForHashing(
            version: 4,
            sigType: 0x13,
            pubKeyAlgo: pubAlgoByte,
            hashAlgo: 8,
            hashedSubpackets: hashedSubpackets
        )
        let toBeHashed = buildCertificationHashInput(
            publicKeyPacketBody: pubKeyBody,
            userIDBody: userIDBody,
            sigData: sigData
        )
        let digest = Data(SHA256.hash(data: toBeHashed))

        let rawSig: SSHKeyGPGBridge.RawSignature
        do {
            rawSig = try GPGSigner.signRaw(
                subkey: subkey,
                hash: digest,
                hashAlgorithm: .sha256
            )
        } catch {
            throw ExportError.keyAuthRequired(error.localizedDescription)
        }

        let sigPacketBody = buildSignaturePacketBody(
            sigData: sigData,
            unhashedSubpackets: unhashedSubpackets,
            digestLeft16: Data(digest.prefix(2)),
            rawSignature: rawSig,
            algorithm: subkey.algorithm
        )

        var stream = Data()
        stream.append(writeNewFormatPacket(tag: 6, body: pubKeyBody))
        stream.append(writeNewFormatPacket(tag: 13, body: userIDBody))
        stream.append(writeNewFormatPacket(tag: 2, body: sigPacketBody))

        // Optional ECDH subkey. Two distinct cases handled here:
        //   1. The primary itself encrypts (RSA SCE): no subkey
        //      needed — the self-signature already advertises the
        //      encrypt flags above.
        //   2. The imported keyring had a DIFFERENT encryption subkey
        //      (e.g. Ed25519 sign + cv25519 encrypt): emit it bound
        //      to the signing key. The keygrip-mismatch filter
        //      excludes the primary itself (which would otherwise
        //      get re-emitted as a duplicate subkey).
        if !subkey.capability.canEncrypt,
           let encSubkey = loaded.subkeys.first(where: {
               $0.capability.canEncrypt && $0.keygrip != subkey.keygrip
           }) {
            let subkeyPackets = try buildEncryptionSubkeyAndBindingFromGPGKey(
                primaryPublicKeyBody: pubKeyBody,
                primarySigningSubkey: subkey,
                encryptionSubkey: encSubkey
            )
            stream.append(subkeyPackets)
        }

        return armor(blockType: "PGP PUBLIC KEY BLOCK", body: stream)
    }

    /// Build an ECDH subkey + binding signature using an already-
    /// loaded GPG signing subkey. Same shape as the SSH-key variant
    /// but signed inline via ``GPGSigner.signRaw`` (no biometric
    /// re-prompt because the signing key's secret is already in
    /// memory).
    private static func buildEncryptionSubkeyAndBindingFromGPGKey(
        primaryPublicKeyBody: Data,
        primarySigningSubkey: OpenPGPSubkey,
        encryptionSubkey: OpenPGPSubkey
    ) throws -> Data {
        let subkeyBody = buildECDHSubkeyPacketBody(
            version: 4,
            ctime: encryptionSubkey.creationTime,
            algorithm: encryptionSubkey.algorithm,
            publicMaterial: encryptionSubkey.publicMaterial
        )

        let primaryPubAlgoByte = openPGPPublicKeyAlgorithmByte(for: primarySigningSubkey.algorithm)
        let primaryFingerprint = computeV4Fingerprint(packetBody: primaryPublicKeyBody)
        let bindingHashed = buildSubkeyBindingHashedSubpackets(
            ctime: encryptionSubkey.creationTime,
            primaryFingerprint: primaryFingerprint
        )
        let bindingUnhashed = buildUnhashedSubpackets(fingerprint: primaryFingerprint)
        let bindingSigData = buildSignatureDataForHashing(
            version: 4,
            sigType: 0x18,
            pubKeyAlgo: primaryPubAlgoByte,
            hashAlgo: 8,
            hashedSubpackets: bindingHashed
        )
        let bindingHashInput = buildSubkeyBindingHashInput(
            primaryKeyPacketBody: primaryPublicKeyBody,
            subkeyPacketBody: subkeyBody,
            sigData: bindingSigData
        )
        let bindingDigest = Data(SHA256.hash(data: bindingHashInput))
        let bindingRawSig = try GPGSigner.signRaw(
            subkey: primarySigningSubkey,
            hash: bindingDigest,
            hashAlgorithm: .sha256
        )
        let bindingSigBody = buildSignaturePacketBody(
            sigData: bindingSigData,
            unhashedSubpackets: bindingUnhashed,
            digestLeft16: Data(bindingDigest.prefix(2)),
            rawSignature: bindingRawSig,
            algorithm: primarySigningSubkey.algorithm
        )

        var out = Data()
        out.append(writeNewFormatPacket(tag: 14, body: subkeyBody))
        out.append(writeNewFormatPacket(tag: 2, body: bindingSigBody))
        return out
    }

    /// Prefer the primary (which on ed25519+cv25519 carries the
    /// signing flag) — if there isn't one, fall back to the first
    /// subkey our signer can handle. Encryption-only subkeys (cv25519,
    /// ECDH P-256) are filtered out here so the exported "primary" is
    /// always a signing key.
    private static func pickSigningSubkey(from subkeys: [OpenPGPSubkey]) -> OpenPGPSubkey? {
        if let primary = subkeys.first(where: { $0.isPrimary && $0.capability.canSign }) {
            return primary
        }
        return subkeys.first(where: { $0.capability.canSign })
    }

    // MARK: - Detached document signature (git commit signing)

    /// Build an ASCII-armored **detached OpenPGP document signature**
    /// (signature type 0x00) over `content`, signed by `subkey`. This is
    /// the form `git` stores in a commit's `gpgsig` header for
    /// `gpg.format=openpgp`: equivalent to `gpg -bsa` over the unsigned
    /// commit object.
    ///
    /// Unlike the certification (0x13) and subkey-binding (0x18)
    /// signatures built above, a document signature hashes the literal
    /// data directly — no 0x99 / 0xB4 public-key or user-ID prefix —
    /// followed by the signature data and the v4 trailer.
    static func detachedDocumentSignature(
        content: Data,
        subkey: OpenPGPSubkey,
        creationTime: UInt32
    ) throws -> String {
        let hashedSubpackets = buildDocumentHashedSubpackets(
            ctime: creationTime,
            fingerprint: subkey.fingerprint
        )
        let sigData = buildSignatureDataForHashing(
            version: 4,
            sigType: 0x00,  // signature of a binary document
            pubKeyAlgo: openPGPPublicKeyAlgorithmByte(for: subkey.algorithm),
            hashAlgo: 8,    // SHA-256
            hashedSubpackets: hashedSubpackets
        )
        let toBeHashed = buildDocumentHashInput(content: content, sigData: sigData)
        let digest = Data(SHA256.hash(data: toBeHashed))

        let rawSig = try GPGSigner.signRaw(
            subkey: subkey,
            hash: digest,
            hashAlgorithm: .sha256
        )

        let sigPacketBody = buildSignaturePacketBody(
            sigData: sigData,
            unhashedSubpackets: buildUnhashedSubpackets(fingerprint: subkey.fingerprint),
            digestLeft16: Data(digest.prefix(2)),
            rawSignature: rawSig,
            algorithm: subkey.algorithm
        )

        let stream = writeNewFormatPacket(tag: 2, body: sigPacketBody)
        return armor(blockType: "PGP SIGNATURE", body: stream)
    }

    /// Hashed subpackets for a detached document signature: just the
    /// signature creation time (type 2) and issuer fingerprint (type
    /// 33). The richer self-signature set (key flags, preferred
    /// algorithms, key-server prefs) is meaningless on a data signature.
    private static func buildDocumentHashedSubpackets(
        ctime: UInt32,
        fingerprint: Data
    ) -> Data {
        var subs = Data()

        var ctimeBytes = Data()
        ctimeBytes.appendUInt32BE(ctime)
        subs.append(writeSubpacket(type: 2, body: ctimeBytes))

        // Issuer fingerprint (type 33): 0x04 + 20-byte v4 fingerprint.
        var issuerFp = Data([0x04])
        issuerFp.append(fingerprint)
        subs.append(writeSubpacket(type: 33, body: issuerFp))

        return subs
    }

    /// Hash input for a binary-document signature (sig type 0x00):
    ///   content || sigData || 0x04 || 0xFF || len4(sigData)
    private static func buildDocumentHashInput(content: Data, sigData: Data) -> Data {
        var buf = Data()
        buf.append(content)
        buf.append(sigData)
        buf.append(0x04)
        buf.append(0xFF)
        buf.appendUInt32BE(UInt32(sigData.count))
        return buf
    }

    // MARK: - Packet body builders

    private static func buildPublicKeyPacketBody(
        version: UInt8,
        ctime: UInt32,
        algorithm: OpenPGPAlgorithm,
        publicMaterial: OpenPGPSubkey.PublicMaterial
    ) -> Data {
        var body = Data()
        body.append(version)
        body.appendUInt32BE(ctime)
        body.append(openPGPPublicKeyAlgorithmByte(for: algorithm))

        switch (algorithm, publicMaterial) {
        case (.rsa, .rsa(let n, let e)):
            body.append(encodeMPI(n))
            body.append(encodeMPI(e))
        case (.ecdsa(let curve), .ec(let q)),
             (.eddsaLegacy(let curve), .ec(let q)):
            let oid = openPGPCurveOID(for: curve)
            body.append(UInt8(oid.count))
            body.append(oid)
            body.append(encodeMPI(q))
        case (.ed25519Native, .ec(let q)):
            // v4 export emits Ed25519 in the legacy form (algo 22 with
            // 0x40-prefixed point) so importers without v6 support can
            // still consume it. Caller is expected to have set the
            // algorithm byte to 22 already; we just add the prefix.
            let oid = openPGPCurveOID(for: .ed25519)
            body.append(UInt8(oid.count))
            body.append(oid)
            var prefixed = Data([0x40])
            prefixed.append(q)
            body.append(encodeMPI(prefixed))
        default:
            // Caller guards against this; fall through with an empty
            // body so downstream consumers fail loudly.
            break
        }
        return body
    }

    /// Subpackets at minimum:
    ///   * 2  (creation time) — uint32 BE
    ///   * 27 (key flags) — derived from `keyFlags`
    ///   * 21 (preferred hash algorithms) — SHA-256, SHA-512
    ///   * 22 (preferred compression) — uncompressed, ZLIB, ZIP
    ///   * 33 (issuer fingerprint) — version (4) + 20-byte fingerprint
    ///   * 23 (key server preferences) — no-modify flag
    private static func buildHashedSubpackets(
        ctime: UInt32,
        fingerprint: Data,
        keyFlags: UInt8
    ) -> Data {
        var subs = Data()

        // Creation time (type 2)
        var ctimeBytes = Data()
        ctimeBytes.appendUInt32BE(ctime)
        subs.append(writeSubpacket(type: 2, body: ctimeBytes))

        // Key flags (type 27): bitmap per RFC 9580 §5.2.3.29.
        //   0x01 cert | 0x02 sign | 0x04 encrypt-comm | 0x08 encrypt-storage
        // Caller picks based on the primary's algorithm capability.
        subs.append(writeSubpacket(type: 27, body: Data([keyFlags])))

        // Preferred hash algorithms (type 21): SHA-256 (8), SHA-512 (10)
        subs.append(writeSubpacket(type: 21, body: Data([8, 10])))

        // Preferred symmetric algorithms (type 11): AES-256 (9), AES-128 (7)
        subs.append(writeSubpacket(type: 11, body: Data([9, 7])))

        // Preferred compression algorithms (type 22): Uncompressed (0), ZLIB (2), ZIP (1)
        subs.append(writeSubpacket(type: 22, body: Data([0, 2, 1])))

        // Issuer fingerprint (type 33): 0x04 + 20-byte v4 fingerprint
        var issuerFp = Data([0x04])
        issuerFp.append(fingerprint)
        subs.append(writeSubpacket(type: 33, body: issuerFp))

        // Key server preferences (type 23): no-modify flag (0x80)
        subs.append(writeSubpacket(type: 23, body: Data([0x80])))

        return subs
    }

    /// Primary-key self-signature key flags for a given OpenPGP
    /// capability. The certification flag (0x01) is always set — the
    /// primary is always the cert root in our exports. Encrypt flags
    /// (0x04 | 0x08) appear when the algorithm can do EME (RSA);
    /// sign (0x02) appears for any signing-capable algorithm.
    private static func primaryKeyFlags(for capability: OpenPGPSubkey.Capability) -> UInt8 {
        var flags: UInt8 = 0x01  // certify
        if capability.canSign { flags |= 0x02 }
        if capability.canEncrypt { flags |= 0x04 | 0x08 }
        return flags
    }

    /// Map an SSH-derived primary algorithm to the OpenPGP capability
    /// gpg should see on the self-signature. RSA bridges to a SCE
    /// primary (one key handles all three roles); ECDSA / EdDSA
    /// bridge to sign-only because the cryptography itself can't
    /// encrypt — encryption needs a separate ECDH subkey.
    private static func sshKeyCapability(for algorithm: OpenPGPAlgorithm) -> OpenPGPSubkey.Capability {
        switch algorithm {
        case .rsa: return .signAndEncrypt
        case .ecdsa, .eddsaLegacy, .ed25519Native: return .sign
        case .ecdh, .x25519Native, .unsupported: return .sign
        }
    }

    private static func buildUnhashedSubpackets(fingerprint: Data) -> Data {
        // Issuer key ID (type 16) — last 8 bytes of the fingerprint.
        let keyID = Data(fingerprint.suffix(8))
        return writeSubpacket(type: 16, body: keyID)
    }

    /// The "sigData" prefix is everything from the signature packet
    /// up to and including the hashed subpackets. It's both
    /// (a) hashed as part of the to-be-signed input, and (b) emitted
    /// verbatim at the start of the signature packet body.
    private static func buildSignatureDataForHashing(
        version: UInt8,
        sigType: UInt8,
        pubKeyAlgo: UInt8,
        hashAlgo: UInt8,
        hashedSubpackets: Data
    ) -> Data {
        var data = Data()
        data.append(version)
        data.append(sigType)
        data.append(pubKeyAlgo)
        data.append(hashAlgo)
        // Hashed-subpacket-count (2 bytes BE), then the subpackets.
        let count = UInt16(hashedSubpackets.count)
        data.append(UInt8((count >> 8) & 0xFF))
        data.append(UInt8(count & 0xFF))
        data.append(hashedSubpackets)
        return data
    }

    /// Hash input for a positive-certification (sig type 0x13)
    /// signature over a user ID + primary key:
    ///   0x99 || len2(pubKeyBody) || pubKeyBody ||
    ///   0xB4 || len4(userIDBody) || userIDBody ||
    ///   sigData ||
    ///   0x04 || 0xFF || len4(sigData)
    private static func buildCertificationHashInput(
        publicKeyPacketBody: Data,
        userIDBody: Data,
        sigData: Data
    ) -> Data {
        var buf = Data()
        // Public-key hashing prefix
        buf.append(0x99)
        buf.append(UInt8((publicKeyPacketBody.count >> 8) & 0xFF))
        buf.append(UInt8(publicKeyPacketBody.count & 0xFF))
        buf.append(publicKeyPacketBody)

        // User-ID hashing prefix (0xB4 + 4-byte length)
        buf.append(0xB4)
        buf.appendUInt32BE(UInt32(userIDBody.count))
        buf.append(userIDBody)

        // Signature data
        buf.append(sigData)

        // Trailer: version, 0xFF, 4-byte BE length of sigData
        buf.append(0x04)
        buf.append(0xFF)
        buf.appendUInt32BE(UInt32(sigData.count))
        return buf
    }

    private static func buildSignaturePacketBody(
        sigData: Data,
        unhashedSubpackets: Data,
        digestLeft16: Data,
        rawSignature: SSHKeyGPGBridge.RawSignature,
        algorithm: OpenPGPAlgorithm
    ) -> Data {
        var body = Data()
        body.append(sigData)
        let uCount = UInt16(unhashedSubpackets.count)
        body.append(UInt8((uCount >> 8) & 0xFF))
        body.append(UInt8(uCount & 0xFF))
        body.append(unhashedSubpackets)
        body.append(digestLeft16)

        switch (rawSignature, algorithm) {
        case (.rsa(let s), .rsa):
            body.append(encodeMPI(s))
        case (.ed25519(let r, let s), .eddsaLegacy),
             (.ed25519(let r, let s), .ed25519Native):
            body.append(encodeMPI(leftPad(r, toCount: 32)))
            body.append(encodeMPI(leftPad(s, toCount: 32)))
        case (.ecdsa(let r, let s), .ecdsa):
            body.append(encodeMPI(leftPad(r, toCount: 32)))
            body.append(encodeMPI(leftPad(s, toCount: 32)))
        default:
            // Algorithm/signature mismatch — shouldn't happen given
            // the upstream switches.
            break
        }
        return body
    }

    // MARK: - Algorithm + curve plumbing

    /// OpenPGP public-key algorithm byte (RFC 9580 §9.1).
    private static func openPGPPublicKeyAlgorithmByte(for algorithm: OpenPGPAlgorithm) -> UInt8 {
        switch algorithm {
        case .rsa: return 1          // RSA sign-and-encrypt
        case .ecdsa: return 19       // ECDSA
        case .ecdh: return 18        // ECDH
        case .eddsaLegacy: return 22 // EdDSA legacy
        case .ed25519Native: return 22  // Emit as legacy for compatibility
        case .x25519Native: return 18    // Emit as cv25519 ECDH for compatibility
        case .unsupported(let id): return id
        }
    }

    /// Raw OID bytes (no tag/length prefix) for the curves we emit.
    private static func openPGPCurveOID(for curve: ECCurve) -> Data {
        switch curve {
        case .p256:
            // 1.2.840.10045.3.1.7
            return Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        case .ed25519:
            // 1.3.6.1.4.1.11591.15.1
            return Data([0x2B, 0x06, 0x01, 0x04, 0x01, 0xDA, 0x47, 0x0F, 0x01])
        case .cv25519:
            // 1.3.6.1.4.1.3029.1.5.1
            return Data([0x2B, 0x06, 0x01, 0x04, 0x01, 0x97, 0x55, 0x01, 0x05, 0x01])
        }
    }

    // MARK: - Fingerprint

    /// v4 fingerprint per RFC 9580 §5.5.4 — SHA-1 over
    /// `0x99 || len2(body) || body` where `body` is the public-key
    /// packet body (version + ctime + algo + algo params, exactly
    /// what ``buildPublicKeyPacketBody`` produces).
    private static func computeV4Fingerprint(packetBody: Data) -> Data {
        var input = Data()
        input.append(0x99)
        input.append(UInt8((packetBody.count >> 8) & 0xFF))
        input.append(UInt8(packetBody.count & 0xFF))
        input.append(packetBody)
        return Data(Insecure.SHA1.hash(data: input))
    }

    // MARK: - Packet framing

    /// New-format OpenPGP packet header (RFC 9580 §4.2.2): one tag
    /// byte (0xC0 | tag) followed by a length encoding that scales
    /// from 1 byte (≤191), 2 bytes (≤8383), or 5 bytes (one 0xFF
    /// marker + 4-byte BE length).
    private static func writeNewFormatPacket(tag: UInt8, body: Data) -> Data {
        var out = Data()
        out.append(0xC0 | (tag & 0x3F))
        let len = body.count
        if len < 192 {
            out.append(UInt8(len))
        } else if len < 8384 {
            let normalised = len - 192
            out.append(UInt8((normalised >> 8) + 192))
            out.append(UInt8(normalised & 0xFF))
        } else {
            out.append(0xFF)
            out.appendUInt32BE(UInt32(len))
        }
        out.append(body)
        return out
    }

    private static func writeSubpacket(type: UInt8, body: Data) -> Data {
        // Subpacket length covers the type byte + body. Same length
        // encoding as packet length above except there's no 0xFF
        // marker — five-byte form is just a literal 0xFF followed by
        // a 4-byte BE length (different decode rule than packets).
        let totalLen = body.count + 1  // type byte
        var out = Data()
        if totalLen < 192 {
            out.append(UInt8(totalLen))
        } else if totalLen < 8384 {
            let normalised = totalLen - 192
            out.append(UInt8((normalised >> 8) + 192))
            out.append(UInt8(normalised & 0xFF))
        } else {
            out.append(0xFF)
            out.appendUInt32BE(UInt32(totalLen))
        }
        out.append(type)
        out.append(body)
        return out
    }

    // MARK: - MPI encoding

    /// OpenPGP MPI: 2-byte big-endian bit length, then ceil(bits/8)
    /// bytes of value. Leading zero bytes are stripped before
    /// computing the bit length so the MPI is canonical.
    private static func encodeMPI(_ value: Data) -> Data {
        let trimmed = stripLeadingZeros(value)
        if trimmed.isEmpty {
            return Data([0x00, 0x00])
        }
        let firstByte = trimmed.first!
        var topBitPosition = 8
        for shift in stride(from: 7, through: 0, by: -1) {
            if (firstByte >> shift) & 0x01 == 1 {
                topBitPosition = shift + 1
                break
            }
        }
        let bitLength = (trimmed.count - 1) * 8 + topBitPosition
        var out = Data()
        out.append(UInt8((bitLength >> 8) & 0xFF))
        out.append(UInt8(bitLength & 0xFF))
        out.append(trimmed)
        return out
    }

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

    // MARK: - ASCII armor

    /// RFC 9580 §6 ASCII armor: BEGIN/END headers, optional Version
    /// header, blank line, wrapped base64, CRC-24 checksum, END.
    static func armor(blockType: String, body: Data) -> String {
        let b64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let crc = crc24(body)
        var crcBytes = Data()
        crcBytes.append(UInt8((crc >> 16) & 0xFF))
        crcBytes.append(UInt8((crc >> 8) & 0xFF))
        crcBytes.append(UInt8(crc & 0xFF))
        let crcBase64 = crcBytes.base64EncodedString()

        var out = "-----BEGIN \(blockType)-----\n"
        out += "Version: rootshell\n"
        out += "\n"
        out += b64
        if !b64.hasSuffix("\n") { out += "\n" }
        out += "=\(crcBase64)\n"
        out += "-----END \(blockType)-----\n"
        return out
    }

    /// CRC-24 (CRC-24/OPENPGP). Polynomial 0x864CFB, init 0xB704CE,
    /// no reflection, no final XOR.
    private static func crc24(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xB704CE
        for byte in data {
            crc ^= UInt32(byte) << 16
            for _ in 0..<8 {
                crc <<= 1
                if crc & 0x01000000 != 0 {
                    crc ^= 0x01864CFB
                }
            }
        }
        return crc & 0xFFFFFF
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}
