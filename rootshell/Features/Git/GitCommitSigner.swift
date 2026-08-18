#if !targetEnvironment(macCatalyst)

//
//  GitCommitSigner.swift
//  rootshell
//
//  Produces the armored signature that the libgit2 commit path stores
//  in a commit's `gpgsig` header. Two formats, matching git's
//  `gpg.format`:
//
//    * openpgp — a detached OpenPGP document signature made with an
//      imported GPG key (``GPGKeyManager`` / ``GPGSigner``), assembled
//      via ``OpenPGPPublicKeyExport/detachedDocumentSignature``.
//    * ssh — an SSHSIG signature (OpenSSH `PROTOCOL.sshsig`) made with a
//      stored SSH key (``SSHKeyManager`` / ``SSHAgentSigner``), namespace
//      `"git"`.
//
//  The git command runs synchronously on a background queue, so the
//  blocking ``signBlocking`` bridge runs the async, `@MainActor` signing
//  on a detached task and waits on a semaphore — the same shape
//  ``GitSSHTransport`` uses to reach async key loading from libgit2's
//  synchronous transport callbacks. Blocking the background queue thread
//  (not the main thread) keeps the MainActor free to present Face ID.
//
//  Scope: signature *creation* only. Verification lives elsewhere.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Crypto
import NIOCore
import NIOFoundationCompat

/// Which signature format git wants (`gpg.format`).
enum GitSignFormat: Sendable {
    case openpgp
    case ssh
}

/// Errors surfaced while signing a commit. The commit path prints the
/// canonical git line `error: gpg failed to sign the data` and follows
/// it with `errorDescription` as the detail.
enum GitSignError: Error, LocalizedError {
    case noSigningKey(GitSignFormat)
    case keyNotFound(String)
    case noSigningSubkey
    case malformedPublicKey
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSigningKey(let format):
            switch format {
            case .openpgp:
                return "no GPG signing key configured. Set user.signingkey to a key fingerprint, or import exactly one GPG key."
            case .ssh:
                return "no SSH signing key configured. Set user.signingkey to a public key, a key file path, or a key name."
            }
        case .keyNotFound(let key):
            return "signing key \"\(key)\" not found among your stored keys."
        case .noSigningSubkey:
            return "the selected GPG key has no signing-capable subkey."
        case .malformedPublicKey:
            return "could not read the signing key's public material."
        case .signingFailed(let detail):
            return detail
        }
    }
}

/// Builds armored commit signatures from the app's GPG and SSH keys.
@MainActor
enum GitCommitSigner {

    // MARK: - Async entry point

    /// Sign `content` (the unsigned commit object bytes from
    /// `git_commit_create_buffer`) and return the armored signature
    /// string to store in the `gpgsig` header.
    ///
    /// - Parameters:
    ///   - content: exact bytes of the unsigned commit object.
    ///   - format: openpgp or ssh.
    ///   - signingKey: the resolved `user.signingkey` / `-S<key>` value.
    ///   - signatureTime: committer time — used as the OpenPGP signature
    ///     creation time so the signature timestamp matches the commit.
    static func armoredSignature(
        content: Data,
        format: GitSignFormat,
        signingKey: String?,
        signatureTime: Date,
        workingDirectory: String?
    ) async throws -> String {
        switch format {
        case .openpgp:
            return try await openPGPSignature(
                content: content,
                signingKey: signingKey,
                signatureTime: signatureTime
            )
        case .ssh:
            return try await sshSignature(
                content: content,
                signingKey: signingKey,
                workingDirectory: workingDirectory
            )
        }
    }

    /// Synchronous bridge for the background git queue. Mirrors
    /// ``GitSSHTransport`` — a detached task runs the async signer while
    /// the calling (background) thread blocks on a semaphore.
    nonisolated static func signBlocking(
        content: String,
        format: GitSignFormat,
        signingKey: String?,
        signatureTime: Date,
        workingDirectory: String?
    ) -> Result<String, Error> {
        let contentData = Data(content.utf8)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        Task.detached {
            do {
                let sig = try await GitCommitSigner.armoredSignature(
                    content: contentData,
                    format: format,
                    signingKey: signingKey,
                    signatureTime: signatureTime,
                    workingDirectory: workingDirectory
                )
                box.result = .success(sig)
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        return box.result ?? .failure(GitSignError.signingFailed("the signer returned no result"))
    }

    /// Serializes the cross-actor handoff of the signing result. Access
    /// is ordered by the semaphore, so the unchecked Sendable is safe.
    private nonisolated final class ResultBox: @unchecked Sendable {
        var result: Result<String, Error>?
    }

    // MARK: - OpenPGP

    private static func openPGPSignature(
        content: Data,
        signingKey: String?,
        signatureTime: Date
    ) async throws -> String {
        let (gpgKey, preferredKeygripHex) = try resolveGPGKey(signingKey: signingKey)

        let loaded: GPGLoadedKey
        do {
            loaded = try await GPGKeyManager.shared.loadKeyWithAuth(
                id: gpgKey.id,
                reason: "Sign git commit with \(gpgKey.name)"
            )
        } catch {
            throw GitSignError.signingFailed(error.localizedDescription)
        }

        guard let subkey = pickSigningSubkey(loaded.subkeys, preferredKeygripHex: preferredKeygripHex) else {
            throw GitSignError.noSigningSubkey
        }

        let ctime = UInt32(truncatingIfNeeded: Int(signatureTime.timeIntervalSince1970))
        do {
            return try OpenPGPPublicKeyExport.detachedDocumentSignature(
                content: content,
                subkey: subkey,
                creationTime: ctime
            )
        } catch {
            throw GitSignError.signingFailed(error.localizedDescription)
        }
    }

    /// Resolve a GPG key (and optionally a specific subkey) from the
    /// `user.signingkey` value. Matching follows git/gpg norms — a
    /// fingerprint or short/long key ID matches the trailing hex of the
    /// primary or any subkey fingerprint (with an optional `0x`
    /// prefix) — plus a friendly fallback to the stored key name and
    /// auto-selection when exactly one key exists.
    private static func resolveGPGKey(signingKey: String?) throws -> (GPGKey, String?) {
        let keys = GPGKeyManager.shared.savedKeys

        let normalized = signingKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
            .replacingOccurrences(of: "0X", with: "", options: [.anchored])

        guard let id = normalized, !id.isEmpty else {
            // No key configured — use the only key if unambiguous.
            if keys.count == 1 { return (keys[0], nil) }
            throw GitSignError.noSigningKey(.openpgp)
        }

        // Match by fingerprint / key ID (trailing hex), primary first.
        for key in keys {
            if key.primaryFingerprint.gpgHexUpper.hasSuffix(id) {
                return (key, nil)
            }
            for (gripHex, info) in key.keygripIndex where info.fingerprint.gpgHexUpper.hasSuffix(id) {
                return (key, gripHex)
            }
        }

        // Fallback: stored key name (case-insensitive).
        if let raw = signingKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           let match = keys.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
            return (match, nil)
        }

        throw GitSignError.keyNotFound(signingKey ?? "")
    }

    /// Prefer a dedicated (non-primary) signing subkey, the way gpg
    /// signs with the signing subkey rather than the cert-only primary;
    /// honour an explicitly requested keygrip first.
    private static func pickSigningSubkey(
        _ subkeys: [OpenPGPSubkey],
        preferredKeygripHex: String?
    ) -> OpenPGPSubkey? {
        if let hex = preferredKeygripHex?.uppercased(),
           let match = subkeys.first(where: { $0.keygrip.gpgHexUpper == hex }),
           match.capability.canSign {
            return match
        }
        if let sub = subkeys.first(where: { !$0.isPrimary && $0.capability.canSign }) {
            return sub
        }
        if let primary = subkeys.first(where: { $0.isPrimary && $0.capability.canSign }) {
            return primary
        }
        return subkeys.first(where: { $0.capability.canSign })
    }

    // MARK: - SSH (SSHSIG)

    private static func sshSignature(content: Data, signingKey: String?, workingDirectory: String?) async throws -> String {
        let sshKey = try resolveSSHKey(signingKey: signingKey, workingDirectory: workingDirectory)

        let variant: SSHPrivateKeyVariant
        do {
            if sshKey.authRequirement == .none {
                variant = try await SSHKeyManager.shared.loadPrivateKey(id: sshKey.id)
            } else {
                variant = try await SSHKeyManager.shared.loadPrivateKeyWithAuth(id: sshKey.id)
            }
        } catch {
            throw GitSignError.signingFailed(error.localizedDescription)
        }

        let signer = SSHAgentSigner()

        // Public key blob for the SSHSIG `publickey` field — prefer the
        // cached blob (no Keychain access) and fall back to generating
        // it from the loaded key.
        let publicKeyBlob: ByteBuffer
        if let cached = sshKey.publicKeyBlob {
            publicKeyBlob = ByteBuffer(data: cached)
        } else {
            publicKeyBlob = signer.generatePublicKeyBlob(from: variant, keyType: sshKey.keyType)
        }

        // SSHSIG signs over: MAGIC ‖ namespace ‖ reserved ‖ hashAlg ‖ H(message).
        let hashAlg = "sha512"
        let messageHash = Data(SHA512.hash(data: content))

        var toBeSigned = ByteBufferAllocator().buffer(capacity: 128)
        toBeSigned.writeString("SSHSIG")               // 6-byte magic, no length
        toBeSigned.writeSSHString("git")               // namespace
        toBeSigned.writeSSHString("")                  // reserved
        toBeSigned.writeSSHString(hashAlg)             // hash algorithm
        toBeSigned.writeSSHBuffer(ByteBuffer(data: messageHash))

        // RSA SSHSIG uses rsa-sha2-512 (flag bit 0x4); Ed25519/ECDSA use 0.
        let flags: UInt32 = (sshKey.keyType == .rsa || sshKey.keyType == .yubiKeyPIV) ? 4 : 0

        let innerSignature: ByteBuffer
        do {
            innerSignature = try await signer.signAsync(
                keyVariant: variant,
                keyType: sshKey.keyType,
                data: toBeSigned,
                flags: flags
            )
        } catch {
            throw GitSignError.signingFailed(error.localizedDescription)
        }

        // Outer SSHSIG blob.
        var blob = ByteBufferAllocator().buffer(capacity: 256)
        blob.writeString("SSHSIG")                     // magic
        blob.writeInteger(UInt32(1))                   // SIG_VERSION
        blob.writeSSHBuffer(publicKeyBlob)             // publickey
        blob.writeSSHString("git")                     // namespace
        blob.writeSSHString("")                        // reserved
        blob.writeSSHString(hashAlg)                   // hash algorithm
        blob.writeSSHBuffer(innerSignature)            // signature

        return armorSSHSignature(Data(buffer: blob))
    }

    /// Resolve a stored SSH key from `user.signingkey`. Accepts a
    /// literal public key (`ssh-… AAAA…`, optionally `key::`-prefixed),
    /// a path to a public-key file, or — as a friendly fallback — the
    /// stored key's name. Auto-selects when exactly one key exists.
    private static func resolveSSHKey(signingKey: String?, workingDirectory: String?) throws -> SSHKey {
        let keys = SSHKeyManager.shared.savedKeys

        guard let raw = signingKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            if keys.count == 1 { return keys[0] }
            throw GitSignError.noSigningKey(.ssh)
        }

        // Literal public key (with or without `key::` prefix).
        if let blob = decodeSSHPublicKeyBlob(fromLiteral: raw),
           let match = keys.first(where: { $0.publicKeyBlob == blob }) {
            return match
        }

        // Path to a public-key file — expand a leading `~` and resolve
        // relative paths against the repo working directory, the way git
        // resolves user.signingkey relative to the cwd.
        let candidatePath = resolveKeyFilePath(raw, workingDirectory: workingDirectory)
        if FileManager.default.fileExists(atPath: candidatePath),
           let contents = try? String(contentsOfFile: candidatePath, encoding: .utf8) {
            for line in contents.split(separator: "\n") {
                if let blob = decodeSSHPublicKeyBlob(fromLiteral: String(line)),
                   let match = keys.first(where: { $0.publicKeyBlob == blob }) {
                    return match
                }
            }
        }

        // Fallback: stored key name (case-insensitive).
        if let match = keys.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
            return match
        }

        throw GitSignError.keyNotFound(raw)
    }

    /// Resolve a `user.signingkey` file path: expand a leading `~`
    /// against the shell HOME (falling back to the app container home),
    /// and resolve relative paths against the repo working directory
    /// rather than the process cwd.
    private static func resolveKeyFilePath(_ raw: String, workingDirectory: String?) -> String {
        var path = raw
        if path == "~" {
            path = homeDirectory()
        } else if path.hasPrefix("~/") {
            path = (homeDirectory() as NSString).appendingPathComponent(String(path.dropFirst(2)))
        }

        let ns = path as NSString
        if ns.isAbsolutePath {
            return ns.standardizingPath
        }
        if let wd = workingDirectory {
            return ((wd as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        return ns.standardizingPath
    }

    private static func homeDirectory() -> String {
        ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    }

    /// Decode the SSH wire-format public-key blob from an OpenSSH public
    /// key string: `<type> <base64-blob> [comment]`, optionally prefixed
    /// with `key::` (git's literal-key syntax).
    private static func decodeSSHPublicKeyBlob(fromLiteral literal: String) -> Data? {
        var s = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("key::") { s = String(s.dropFirst(5)) }
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// Wrap an SSHSIG binary blob in the OpenSSH armored format. Base64
    /// is wrapped at 70 columns, matching `ssh-keygen -Y sign` output.
    private static func armorSSHSignature(_ blob: Data) -> String {
        let b64 = blob.base64EncodedString()
        var wrapped = ""
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            wrapped += b64[idx..<end]
            wrapped += "\n"
            idx = end
        }
        return "-----BEGIN SSH SIGNATURE-----\n" + wrapped + "-----END SSH SIGNATURE-----\n"
    }
}

#endif
