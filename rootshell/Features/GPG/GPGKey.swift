//
//  GPGKey.swift
//  rootshell
//
//  Metadata for a GPG (OpenPGP) secret key imported into the app. The
//  encrypted secret material lives in the Keychain under
//  `com.ghostty.gpg.secretkey`; this struct holds only what's needed to
//  identify and label the key without touching the protected blob —
//  most importantly the keygrip list, so Assuan `HAVEKEY`/`KEYINFO`
//  lookups never trigger a biometric prompt.
//
//  Re-uses the same ``KeyStorageLevel`` and ``KeyAuthRequirement``
//  enums as ``SSHKey`` so users see one consistent set of security
//  tiers across both SSH and GPG key management.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// A GPG (OpenPGP) secret key import — primary plus any subkeys —
/// stored as one logical unit.
///
/// A real-world OpenPGP key typically has one certification-only
/// primary plus one or more subkeys (often a separate signing subkey).
/// For the MVP we store them as one ``GPGKey`` row holding multiple
/// keygrips, so the user manages "a key" as a whole, just like
/// `gpg --list-secret-keys` presents it.
/// Lookup-by-keygrip during `SIGKEY`/`HAVEKEY` resolves to a specific
/// subkey via the embedded ``keygripIndex``.
nonisolated struct GPGKey: Codable, Identifiable, Hashable, Sendable {

    /// Stable identifier for this key import (used as the Keychain
    /// account string for the secret blob).
    let id: UUID

    /// User-provided label (e.g., "Personal GPG", "Work signing").
    var name: String

    /// Date the key was imported.
    let createdDate: Date

    /// Primary v4 fingerprint (20 bytes, displayed as 40 hex chars).
    /// Mirrors what `gpg --fingerprint` shows.
    let primaryFingerprint: Data

    /// Per-subkey identity used for Assuan lookups. Indexed by keygrip
    /// (hex, uppercase, no separators) — both `KEYINFO` and `SIGKEY`
    /// receive keygrips, so this is the hot path on signing.
    var keygripIndex: [String: GPGSubkeyInfo]

    /// Storage tier — same semantics as ``KeyStorageLevel`` for SSH keys.
    var storageLevel: KeyStorageLevel

    /// Auth requirement — same semantics as ``KeyAuthRequirement`` for
    /// SSH keys. Note that for `PKSIGN`, even `.none` flows through the
    /// Assuan approval prompt unless ``GPGAgentConfig/ApprovalMode/autoApprove``
    /// is selected; the biometric tier only controls Keychain access.
    var authRequirement: KeyAuthRequirement

    /// Date when security settings were last modified.
    var securityModifiedDate: Date?

    /// Schema version of the stored data. Bumped when import-side
    /// parsing changes in a way that older imports can't backfill. Keys
    /// at v1 predate ECDH-subkey parsing — their `keygripIndex` may be
    /// missing the encryption subkeys that were in the original keyring.
    /// The detail view surfaces a "re-import to enable decryption"
    /// banner for these. Decoder defaults missing values to v1.
    var schemaVersion: Int = Self.currentSchemaVersion

    /// Current schema version emitted by the importer. Bump when import
    /// adds another piece of metadata that older entries can't infer.
    static let currentSchemaVersion: Int = 2

    private enum CodingKeys: String, CodingKey {
        case id, name, createdDate, primaryFingerprint, keygripIndex,
             storageLevel, authRequirement, securityModifiedDate, schemaVersion
    }

    init(
        id: UUID,
        name: String,
        createdDate: Date,
        primaryFingerprint: Data,
        keygripIndex: [String: GPGSubkeyInfo],
        storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement,
        securityModifiedDate: Date? = nil,
        schemaVersion: Int = Self.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.primaryFingerprint = primaryFingerprint
        self.keygripIndex = keygripIndex
        self.storageLevel = storageLevel
        self.authRequirement = authRequirement
        self.securityModifiedDate = securityModifiedDate
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdDate = try c.decode(Date.self, forKey: .createdDate)
        primaryFingerprint = try c.decode(Data.self, forKey: .primaryFingerprint)
        keygripIndex = try c.decode([String: GPGSubkeyInfo].self, forKey: .keygripIndex)
        storageLevel = try c.decode(KeyStorageLevel.self, forKey: .storageLevel)
        authRequirement = try c.decode(KeyAuthRequirement.self, forKey: .authRequirement)
        securityModifiedDate = try c.decodeIfPresent(Date.self, forKey: .securityModifiedDate)
        // Older rows pre-date this field — default to v1 so the UI can
        // offer a re-import to enable decryption.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdDate, forKey: .createdDate)
        try c.encode(primaryFingerprint, forKey: .primaryFingerprint)
        try c.encode(keygripIndex, forKey: .keygripIndex)
        try c.encode(storageLevel, forKey: .storageLevel)
        try c.encode(authRequirement, forKey: .authRequirement)
        try c.encodeIfPresent(securityModifiedDate, forKey: .securityModifiedDate)
        try c.encode(schemaVersion, forKey: .schemaVersion)
    }

    // MARK: - Display helpers

    /// `<short fingerprint>` — last 16 hex chars of the primary
    /// fingerprint, the same form `gpg --list-keys --keyid-format LONG`
    /// shows after the algorithm prefix.
    var shortPrimaryFingerprint: String {
        let hex = primaryFingerprint.gpgHexUpper
        return String(hex.suffix(16))
    }

    /// Full primary fingerprint as `XXXX XXXX XXXX XXXX XXXX  XXXX XXXX XXXX XXXX XXXX`
    /// — matching the `gpg --fingerprint` rendering with a wider gap in
    /// the middle. Decorative; use ``primaryFingerprint`` for matching.
    var formattedPrimaryFingerprint: String {
        let hex = primaryFingerprint.gpgHexUpper
        var out = ""
        var idx = hex.startIndex
        var blockNumber = 0
        while idx < hex.endIndex {
            let end = hex.index(idx, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            out += hex[idx..<end]
            blockNumber += 1
            idx = end
            if idx < hex.endIndex {
                out += blockNumber == 5 ? "  " : " "
            }
        }
        return out
    }

    /// Subkeys that can sign — i.e. anything that came in via the
    /// import. (We don't yet decode key-flag subpackets to filter out
    /// encryption-only subkeys, so today every subkey is offered for
    /// signing; signing-with-an-encryption-subkey produces an
    /// algorithm-mismatch error on the remote, which is fine for MVP.)
    var signingSubkeys: [GPGSubkeyInfo] {
        Array(keygripIndex.values)
    }
}

/// Per-subkey metadata recorded at import time. Holds everything needed
/// to answer Assuan probing without touching the secret material.
nonisolated struct GPGSubkeyInfo: Codable, Hashable, Sendable {
    /// Subkey fingerprint (v4, 20 bytes). Used for display only; the
    /// keygrip is the wire identifier.
    let fingerprint: Data

    /// Algorithm — encoded as a small payload so changes to
    /// ``OpenPGPAlgorithm`` (e.g. adding curves) don't break existing
    /// stored keys.
    let algorithm: PersistedAlgorithm

    /// Creation time (seconds since epoch).
    let creationTime: UInt32

    /// Whether this subkey is the primary key in the imported keyring.
    let isPrimary: Bool

    /// Public key material — kept here so the Assuan layer can compute
    /// fixed-width signature components without re-reading the
    /// Keychain. Small enough (RSA: up to a few hundred bytes, EC: ~70
    /// bytes) that the storage cost is irrelevant.
    let publicMaterial: PersistedPublicMaterial

    /// Sign / encrypt / both — what the agent should advertise this
    /// subkey for. Older imports default to ``.sign`` on decode.
    let capability: OpenPGPSubkey.Capability

    /// Raw key-flags byte from the binding/self-signature, preserved
    /// for fidelity on re-export. Nil for older imports or keys whose
    /// import didn't see a parseable signature.
    let keyFlags: UInt8?

    /// KDF parameters for ECDH subkeys. `nil` for non-ECDH subkeys.
    let kdfParams: OpenPGPSubkey.KDFParams?

    init(
        fingerprint: Data,
        algorithm: PersistedAlgorithm,
        creationTime: UInt32,
        isPrimary: Bool,
        publicMaterial: PersistedPublicMaterial,
        capability: OpenPGPSubkey.Capability = .sign,
        keyFlags: UInt8? = nil,
        kdfParams: OpenPGPSubkey.KDFParams? = nil
    ) {
        self.fingerprint = fingerprint
        self.algorithm = algorithm
        self.creationTime = creationTime
        self.isPrimary = isPrimary
        self.publicMaterial = publicMaterial
        self.capability = capability
        self.keyFlags = keyFlags
        self.kdfParams = kdfParams
    }

    private enum CodingKeys: String, CodingKey {
        case fingerprint, algorithm, creationTime, isPrimary, publicMaterial,
             capability, keyFlags, kdfParams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(Data.self, forKey: .fingerprint)
        algorithm = try c.decode(PersistedAlgorithm.self, forKey: .algorithm)
        creationTime = try c.decode(UInt32.self, forKey: .creationTime)
        isPrimary = try c.decode(Bool.self, forKey: .isPrimary)
        publicMaterial = try c.decode(PersistedPublicMaterial.self, forKey: .publicMaterial)
        // Older rows pre-date these fields — fall back to .sign (the
        // only capability we previously advertised) and no KDF.
        capability = try c.decodeIfPresent(OpenPGPSubkey.Capability.self, forKey: .capability) ?? .sign
        keyFlags = try c.decodeIfPresent(UInt8.self, forKey: .keyFlags)
        kdfParams = try c.decodeIfPresent(OpenPGPSubkey.KDFParams.self, forKey: .kdfParams)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(algorithm, forKey: .algorithm)
        try c.encode(creationTime, forKey: .creationTime)
        try c.encode(isPrimary, forKey: .isPrimary)
        try c.encode(publicMaterial, forKey: .publicMaterial)
        try c.encode(capability, forKey: .capability)
        try c.encodeIfPresent(keyFlags, forKey: .keyFlags)
        try c.encodeIfPresent(kdfParams, forKey: .kdfParams)
    }

    /// Codable mirror of ``OpenPGPAlgorithm`` — needed because the
    /// runtime enum carries associated curve values that don't survive
    /// JSON round-tripping cleanly.
    nonisolated enum PersistedAlgorithm: Codable, Hashable, Sendable {
        case rsa
        case ecdsaP256
        case eddsaEd25519
        case ed25519Native
        case ecdhCv25519
        case ecdhP256
        case x25519Native

        init(_ algo: OpenPGPAlgorithm) {
            switch algo {
            case .rsa: self = .rsa
            case .ecdsa(.p256): self = .ecdsaP256
            case .ecdsa(.ed25519), .ecdsa(.cv25519): self = .ecdsaP256  // Unreachable; parser rejects
            case .ecdh(.cv25519): self = .ecdhCv25519
            case .ecdh(.p256): self = .ecdhP256
            case .ecdh(.ed25519): self = .ecdhCv25519  // Unreachable; parser rejects
            case .eddsaLegacy: self = .eddsaEd25519
            case .ed25519Native: self = .ed25519Native
            case .x25519Native: self = .x25519Native
            case .unsupported: self = .rsa  // Unreachable; caller filters
            }
        }

        var displayName: String {
            switch self {
            case .rsa: return "RSA"
            case .ecdsaP256: return "ECDSA P-256"
            case .eddsaEd25519, .ed25519Native: return "Ed25519"
            case .ecdhCv25519, .x25519Native: return "X25519 (Curve25519)"
            case .ecdhP256: return "ECDH P-256"
            }
        }

        /// Reconstitute the runtime ``OpenPGPAlgorithm`` value.
        var runtime: OpenPGPAlgorithm {
            switch self {
            case .rsa: return .rsa
            case .ecdsaP256: return .ecdsa(.p256)
            case .eddsaEd25519: return .eddsaLegacy(.ed25519)
            case .ed25519Native: return .ed25519Native
            case .ecdhCv25519: return .ecdh(.cv25519)
            case .ecdhP256: return .ecdh(.p256)
            case .x25519Native: return .x25519Native
            }
        }
    }

    nonisolated enum PersistedPublicMaterial: Codable, Hashable, Sendable {
        case rsa(n: Data, e: Data)
        case ec(q: Data)

        init(_ material: OpenPGPSubkey.PublicMaterial) {
            switch material {
            case .rsa(let n, let e): self = .rsa(n: n, e: e)
            case .ec(let q): self = .ec(q: q)
            }
        }

        var runtime: OpenPGPSubkey.PublicMaterial {
            switch self {
            case .rsa(let n, let e): return .rsa(n: n, e: e)
            case .ec(let q): return .ec(q: q)
            }
        }
    }
}

/// Bundle returned when loading the secret material from the Keychain.
/// The `subkeys` array carries the fully decrypted (cleartext)
/// algorithm-specific scalars; the manager holds this only inside the
/// signing closure scope and lets it go as soon as the signature is
/// produced.
struct GPGLoadedKey: Sendable {
    let metadata: GPGKey
    let subkeys: [OpenPGPSubkey]

    /// Look up a specific subkey by keygrip hex string.
    func subkey(forKeygrip keygripHex: String) -> OpenPGPSubkey? {
        subkeys.first(where: { $0.keygrip.gpgHexUpper == keygripHex })
    }
}
