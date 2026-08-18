//
//  GPGKeyManager.swift
//  rootshell
//
//  Manages imported GPG (OpenPGP) secret keys. Parallel structure to
//  ``SSHKeyManager``: metadata is published on the main actor for UI
//  binding, the actual secret material lives in the Keychain under a
//  separate service and is loaded on demand with optional biometric
//  auth.
//
//  The "load only when needed" pattern matters here for the same
//  reason it does on the SSH side: Assuan `HAVEKEY` / `KEYINFO`
//  lookups happen frequently during a single signing operation (gpg
//  often probes keygrips before sending the real `PKSIGN`), and we
//  don't want to surface a biometric prompt for each one. All probing
//  resolves against the in-memory keygrip index; the secret material
//  is only fetched once the user has approved a real signing request.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
import LocalAuthentication
import os.log

/// Cleartext envelope persisted to the Keychain under the GPG secret
/// key service. Holding it as JSON (rather than re-serialising as
/// OpenPGP packets) keeps the loader code tiny — the parser is only
/// needed once at import time.
private struct StoredGPGSecret: Codable {
    let subkeys: [StoredSubkey]

    struct StoredSubkey: Codable {
        let keygripHex: String
        let algorithm: GPGSubkeyInfo.PersistedAlgorithm
        let creationTime: UInt32
        let publicMaterial: GPGSubkeyInfo.PersistedPublicMaterial
        let secretMaterial: StoredSecret
        let fingerprint: Data
        let isPrimary: Bool
        /// Sign / encrypt / both. Older stored blobs default to ``.sign``.
        let capability: OpenPGPSubkey.Capability
        /// Raw key-flags byte from the binding/self-signature. `nil`
        /// for older imports that pre-date signature parsing.
        let keyFlags: UInt8?
        /// ECDH KDF parameters. `nil` for non-ECDH subkeys.
        let kdfParams: OpenPGPSubkey.KDFParams?

        init(
            keygripHex: String,
            algorithm: GPGSubkeyInfo.PersistedAlgorithm,
            creationTime: UInt32,
            publicMaterial: GPGSubkeyInfo.PersistedPublicMaterial,
            secretMaterial: StoredSecret,
            fingerprint: Data,
            isPrimary: Bool,
            capability: OpenPGPSubkey.Capability = .sign,
            keyFlags: UInt8? = nil,
            kdfParams: OpenPGPSubkey.KDFParams? = nil
        ) {
            self.keygripHex = keygripHex
            self.algorithm = algorithm
            self.creationTime = creationTime
            self.publicMaterial = publicMaterial
            self.secretMaterial = secretMaterial
            self.fingerprint = fingerprint
            self.isPrimary = isPrimary
            self.capability = capability
            self.keyFlags = keyFlags
            self.kdfParams = kdfParams
        }

        private enum CodingKeys: String, CodingKey {
            case keygripHex, algorithm, creationTime, publicMaterial,
                 secretMaterial, fingerprint, isPrimary, capability,
                 keyFlags, kdfParams
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keygripHex = try c.decode(String.self, forKey: .keygripHex)
            algorithm = try c.decode(GPGSubkeyInfo.PersistedAlgorithm.self, forKey: .algorithm)
            creationTime = try c.decode(UInt32.self, forKey: .creationTime)
            publicMaterial = try c.decode(GPGSubkeyInfo.PersistedPublicMaterial.self, forKey: .publicMaterial)
            secretMaterial = try c.decode(StoredSecret.self, forKey: .secretMaterial)
            fingerprint = try c.decode(Data.self, forKey: .fingerprint)
            isPrimary = try c.decode(Bool.self, forKey: .isPrimary)
            capability = try c.decodeIfPresent(OpenPGPSubkey.Capability.self, forKey: .capability) ?? .sign
            keyFlags = try c.decodeIfPresent(UInt8.self, forKey: .keyFlags)
            kdfParams = try c.decodeIfPresent(OpenPGPSubkey.KDFParams.self, forKey: .kdfParams)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(keygripHex, forKey: .keygripHex)
            try c.encode(algorithm, forKey: .algorithm)
            try c.encode(creationTime, forKey: .creationTime)
            try c.encode(publicMaterial, forKey: .publicMaterial)
            try c.encode(secretMaterial, forKey: .secretMaterial)
            try c.encode(fingerprint, forKey: .fingerprint)
            try c.encode(isPrimary, forKey: .isPrimary)
            try c.encode(capability, forKey: .capability)
            try c.encodeIfPresent(keyFlags, forKey: .keyFlags)
            try c.encodeIfPresent(kdfParams, forKey: .kdfParams)
        }

        enum StoredSecret: Codable {
            case rsa(d: Data, p: Data, q: Data, u: Data)
            case ec(d: Data)

            init(_ material: OpenPGPSubkey.SecretMaterial) {
                switch material {
                case .rsa(let d, let p, let q, let u): self = .rsa(d: d, p: p, q: q, u: u)
                case .ec(let d): self = .ec(d: d)
                }
            }

            var runtime: OpenPGPSubkey.SecretMaterial {
                switch self {
                case .rsa(let d, let p, let q, let u): return .rsa(d: d, p: p, q: q, u: u)
                case .ec(let d): return .ec(d: d)
                }
            }
        }
    }
}

@MainActor
final class GPGKeyManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "GPGKeyManager")

    static let shared = GPGKeyManager()

    /// Published list of imported GPG keys (metadata only).
    @Published private(set) var savedKeys: [GPGKey] = []

    /// Fires when ``savedKeys`` changes — useful for listeners that
    /// need to refresh dependent caches.
    let keysDidChange = PassthroughSubject<Void, Never>()

    private let keychain: KeychainManager

    private init() {
        self.keychain = .shared
        loadKeys()
    }

    // MARK: - Import / delete

    /// Errors surfaced by import / delete flows.
    enum ImportError: LocalizedError {
        case invalidName
        case duplicateKey(fingerprint: String)
        case parseError(OpenPGPParseError)
        case keychainError(Error)
        case serializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Please provide a name for the key."
            case .duplicateKey(let fp): return "A GPG key with fingerprint \(fp) is already imported."
            case .parseError(let underlying): return underlying.errorDescription
            case .keychainError(let underlying): return underlying.localizedDescription
            case .serializationFailed: return "Failed to encode key material for storage."
            }
        }
    }

    enum LoadError: LocalizedError {
        case keyNotFound
        case authenticationCancelled
        case authenticationUnavailable
        case authenticationFailed
        case keyChangedDuringAuthentication
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .keyNotFound: return "GPG key not found in Keychain."
            case .authenticationCancelled: return "Authentication was cancelled."
            case .authenticationUnavailable: return "Device authentication is unavailable. Set a device passcode and try again."
            case .authenticationFailed: return "Authentication failed."
            case .keyChangedDuringAuthentication: return "This GPG key changed while authentication was in progress. Try again."
            case .decodeFailed: return "Stored GPG key data is corrupted."
            }
        }
    }

    /// Import a GPG secret-key export (ASCII-armored or binary). The
    /// payload must contain *cleartext* secret material — see notes on
    /// the MVP scope in ``OpenPGPPacket``.
    @discardableResult
    func importKey(
        name: String,
        keyData: Data,
        storageLevel: KeyStorageLevel = .backupOnly,
        authRequirement: KeyAuthRequirement = .none
    ) throws -> GPGKey {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw ImportError.invalidName }

        let parsed: OpenPGPSecretKeyImport
        do {
            parsed = try OpenPGPPacket.parseSecretKeyExport(keyData)
        } catch let err as OpenPGPParseError {
            throw ImportError.parseError(err)
        }

        // Pick the primary fingerprint (or, if no primary, fall back to
        // the first subkey — gpg occasionally exports subkey-only blobs).
        let primary = parsed.primary ?? parsed.subkeys.first!
        let primaryFingerprintHex = primary.fingerprint.gpgHexUpper

        if savedKeys.contains(where: { $0.primaryFingerprint == primary.fingerprint }) {
            throw ImportError.duplicateKey(fingerprint: primaryFingerprintHex)
        }

        // Build the in-memory metadata + the on-disk envelope.
        var keygripIndex: [String: GPGSubkeyInfo] = [:]
        var storedSubkeys: [StoredGPGSecret.StoredSubkey] = []
        for sub in parsed.subkeys {
            let keygripHex = sub.keygrip.gpgHexUpper
            keygripIndex[keygripHex] = GPGSubkeyInfo(
                fingerprint: sub.fingerprint,
                algorithm: GPGSubkeyInfo.PersistedAlgorithm(sub.algorithm),
                creationTime: sub.creationTime,
                isPrimary: sub.isPrimary,
                publicMaterial: GPGSubkeyInfo.PersistedPublicMaterial(sub.publicMaterial),
                capability: sub.capability,
                keyFlags: sub.keyFlags,
                kdfParams: sub.kdfParams
            )
            storedSubkeys.append(StoredGPGSecret.StoredSubkey(
                keygripHex: keygripHex,
                algorithm: GPGSubkeyInfo.PersistedAlgorithm(sub.algorithm),
                creationTime: sub.creationTime,
                publicMaterial: GPGSubkeyInfo.PersistedPublicMaterial(sub.publicMaterial),
                secretMaterial: StoredGPGSecret.StoredSubkey.StoredSecret(sub.secretMaterial),
                fingerprint: sub.fingerprint,
                isPrimary: sub.isPrimary,
                capability: sub.capability,
                keyFlags: sub.keyFlags,
                kdfParams: sub.kdfParams
            ))
        }

        let key = GPGKey(
            id: UUID(),
            name: trimmedName,
            createdDate: Date(),
            primaryFingerprint: primary.fingerprint,
            keygripIndex: keygripIndex,
            storageLevel: storageLevel,
            authRequirement: authRequirement,
            securityModifiedDate: nil
        )

        let envelope = StoredGPGSecret(subkeys: storedSubkeys)
        let encoder = JSONEncoder()
        let secretBlob: Data
        let metadataBlob: Data
        do {
            secretBlob = try encoder.encode(envelope)
            metadataBlob = try encoder.encode(key)
        } catch {
            throw ImportError.serializationFailed
        }

        do {
            try keychain.saveGPGSecretKey(
                secretBlob,
                identifier: key.id.uuidString,
                storageLevel: storageLevel,
                authRequirement: authRequirement
            )
            try keychain.saveGPGKeyMetadata(
                metadataBlob,
                identifier: key.id.uuidString,
                storageLevel: storageLevel
            )
        } catch {
            // Roll back the secret if metadata fails so we don't leak a
            // half-imported key into the Keychain.
            try? keychain.deleteGPGSecretKey(identifier: key.id.uuidString)
            throw ImportError.keychainError(error)
        }

        savedKeys.append(key)
        keysDidChange.send()
        Self.logger.info("Imported GPG key '\(trimmedName)' fp=\(primaryFingerprintHex) subkeys=\(storedSubkeys.count)")
        return key
    }

    func deleteKey(id: UUID) throws {
        guard let index = savedKeys.firstIndex(where: { $0.id == id }) else { return }
        try? keychain.deleteGPGSecretKey(identifier: id.uuidString)
        try? keychain.deleteGPGKeyMetadata(identifier: id.uuidString)
        savedKeys.remove(at: index)
        keysDidChange.send()
    }

    /// Rename an imported key. Persists the new name to Keychain
    /// metadata (synced via iCloud if the key's storage level enables
    /// it) and updates the published list in place. No-op if the id is
    /// unknown or the name is unchanged.
    func updateKeyName(id: UUID, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ImportError.invalidName }
        guard let index = savedKeys.firstIndex(where: { $0.id == id }) else { return }
        guard savedKeys[index].name != trimmed else { return }

        // Persist BEFORE touching savedKeys — if the Keychain write
        // fails, the in-memory list stays consistent with what's on
        // disk and the UI shows the original name instead of a name
        // that would revert on the next refresh / relaunch.
        var updated = savedKeys[index]
        updated.name = trimmed
        let blob = try JSONEncoder().encode(updated)
        do {
            try keychain.updateGPGKeyMetadata(blob, identifier: id.uuidString)
        } catch {
            throw ImportError.keychainError(error)
        }
        savedKeys[index] = updated
        keysDidChange.send()
    }

    // MARK: - Lookup

    /// Resolve a saved key + subkey from a keygrip hex string. Cheap —
    /// runs entirely against in-memory metadata and never touches the
    /// Keychain. Returns nil if the keygrip isn't in any imported key.
    func findSubkey(byKeygripHex keygripHex: String) -> (key: GPGKey, subkey: GPGSubkeyInfo)? {
        let normalised = keygripHex.uppercased()
        for key in savedKeys {
            if let sub = key.keygripIndex[normalised] {
                return (key, sub)
            }
        }
        return nil
    }

    /// Load the cleartext secret material for a key. Triggers a
    /// biometric / passcode prompt if the key's ``KeyAuthRequirement``
    /// requires one. Should only be invoked from inside a `PKSIGN`
    /// path, after the user has approved the operation.
    func loadKeyWithAuth(id: UUID, reason: String) async throws -> GPGLoadedKey {
        guard let metadata = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }

        let context: LAContext?
        if metadata.authRequirement != .none {
            let ctx = LAContext()
            ctx.localizedReason = reason
            ctx.touchIDAuthenticationAllowableReuseDuration = 0
            context = ctx
        } else {
            context = nil
        }

        // Synchronizable GPG secret items cannot carry device-bound
        // SecAccessControl. Enforce the metadata requirement explicitly on
        // the device performing PKSIGN before asking Keychain for the blob.
        if metadata.storageLevel == .iCloudSync, let context {
            try await Self.evaluateDeviceOwnerAuthentication(on: context, reason: reason)

            // The policy prompt is actor-reentrant. Abort if a sync refresh
            // replaced this metadata while authentication was in progress.
            guard savedKeys.first(where: { $0.id == id }) == metadata else {
                throw LoadError.keyChangedDuringAuthentication
            }
        }

        let data: Data
        do {
            data = try keychain.loadGPGSecretKey(
                identifier: id.uuidString,
                authRequirement: metadata.authRequirement,
                context: context
            )
        } catch KeychainManager.KeychainError.authenticationCancelled {
            throw LoadError.authenticationCancelled
        } catch KeychainManager.KeychainError.authenticationFailed {
            throw LoadError.authenticationFailed
        } catch KeychainManager.KeychainError.itemNotFound {
            throw LoadError.keyNotFound
        }

        let envelope: StoredGPGSecret
        do {
            envelope = try JSONDecoder().decode(StoredGPGSecret.self, from: data)
        } catch {
            throw LoadError.decodeFailed
        }

        let subs: [OpenPGPSubkey] = envelope.subkeys.compactMap { stored in
            guard let keygrip = GPGHex.decode(stored.keygripHex) else { return nil }
            return OpenPGPSubkey(
                algorithm: stored.algorithm.runtime,
                creationTime: stored.creationTime,
                publicMaterial: stored.publicMaterial.runtime,
                secretMaterial: stored.secretMaterial.runtime,
                fingerprint: stored.fingerprint,
                keygrip: keygrip,
                isPrimary: stored.isPrimary,
                capability: stored.capability,
                keyFlags: stored.keyFlags,
                kdfParams: stored.kdfParams
            )
        }
        return GPGLoadedKey(metadata: metadata, subkeys: subs)
    }

    nonisolated private static func evaluateDeviceOwnerAuthentication(
        on context: LAContext,
        reason: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else if let laError = error as? LAError,
                          laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                    continuation.resume(throwing: LoadError.authenticationCancelled)
                } else if let laError = error as? LAError, laError.code == .passcodeNotSet {
                    continuation.resume(throwing: LoadError.authenticationUnavailable)
                } else {
                    continuation.resume(throwing: LoadError.authenticationFailed)
                }
            }
        }
    }

    // MARK: - Persistence

    private func loadKeys() {
        savedKeys = Self.loadKeysFromKeychain()
    }

    /// Re-scan the Keychain for newly-synced keys from iCloud. Called on
    /// foreground resume and from the GPG keys settings view's
    /// pull-to-refresh. Without this the published list only reflects
    /// what was present at app launch — a key synced in from another
    /// device wouldn't appear until the next cold start.
    ///
    /// Runs the Keychain read off the main actor so a slow securityd
    /// doesn't stall the scene-update transaction during foreground
    /// resume.
    func refreshKeysAsync() async {
        let oldKeys = savedKeys
        let loaded = await Task.detached(priority: .utility) {
            Self.loadKeysFromKeychain()
        }.value

        // Stale-result guard: if savedKeys changed while we were off-
        // main (e.g. concurrent import), bail and let the next refresh
        // pick up the latest state.
        guard savedKeys == oldKeys else {
            Self.logger.info("Skipping refreshKeys apply: savedKeys mutated during background read")
            return
        }

        let oldIDs = Set(oldKeys.map { $0.id })
        let added = loaded.filter { !oldIDs.contains($0.id) }
        savedKeys = loaded
        if !added.isEmpty {
            Self.logger.info("GPG refresh added \(added.count) keys synced from iCloud")
            keysDidChange.send()
        }
    }

    /// Fire-and-forget variant for non-await call sites.
    func refreshKeys() {
        Task { await refreshKeysAsync() }
    }

    /// Loads metadata for every GPG key in the Keychain. nonisolated so
    /// it can be called from a detached Task without crossing the main
    /// actor on every Keychain call. Uses KeychainManager.shared
    /// directly because KeychainManager isn't Sendable (and the shared
    /// instance is what the rest of the manager uses anyway).
    private nonisolated static func loadKeysFromKeychain() -> [GPGKey] {
        let keychain = KeychainManager.shared
        let identifiers = keychain.listGPGKeyMetadataIdentifiers()
        var keys: [GPGKey] = []
        keys.reserveCapacity(identifiers.count)
        for id in identifiers {
            do {
                let data = try keychain.loadGPGKeyMetadata(identifier: id)
                let key = try JSONDecoder().decode(GPGKey.self, from: data)
                keys.append(key)
            } catch {
                logger.warning("Failed to load GPG key metadata for \(id): \(error.localizedDescription)")
            }
        }
        return keys.sorted { $0.createdDate < $1.createdDate }
    }
}
