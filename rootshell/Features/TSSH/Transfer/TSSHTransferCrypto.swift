//
//  TSSHTransferCrypto.swift
//  rootshell
//
//  X25519 + HKDF-SHA256 + ChaCha20-Poly1305 helpers for the Handoff
//  bootstrap channel. Apple's Continuity transport is already encrypted
//  end-to-end between iCloud-paired devices; this layer is defense in
//  depth — the bootstrap blob (server certs, kcp keys, sessionID) is
//  worth the few extra microseconds of crypto.
//

import CryptoKit
import Foundation

nonisolated enum TrzszTransferCrypto {
    /// HKDF info string. Bumped when the framing/format changes in a way
    /// that must reject older receivers/senders.
    static let hkdfInfo = "trzsz-transfer-v1".data(using: .utf8)!

    /// Generates a fresh ephemeral X25519 keypair. Single-use per transfer.
    static func generateEphemeralKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// Derives the symmetric session key. Both sides feed the same two
    /// raw pubkeys into the HKDF salt (sorted lexicographically so order
    /// doesn't matter), so the key is identical regardless of which side
    /// initiates the exchange.
    static func deriveSharedKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyRaw: Data
    ) throws -> SymmetricKey {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyRaw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)

        let ourPub = privateKey.publicKey.rawRepresentation
        let salt: Data
        if ourPub.lexicographicallyPrecedes(peerPublicKeyRaw) {
            salt = ourPub + peerPublicKeyRaw
        } else {
            salt = peerPublicKeyRaw + ourPub
        }

        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }

    /// Seals plaintext with ChaCha20-Poly1305. Returns the SealedBox's
    /// `combined` form (nonce ‖ ciphertext ‖ tag), which is what we send
    /// over the wire.
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        guard let combined = box.combined as Data? else {
            throw TrzszTransferError.cryptoFailed("Sealed box has no combined form")
        }
        return combined
    }

    /// Inverse of `seal`. Throws on tampering / wrong key.
    static func open(_ combined: Data, using key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: key)
    }
}

nonisolated enum TrzszTransferError: LocalizedError {
    case cryptoFailed(String)
    case streamClosed
    case streamError(String)
    case malformedFrame(String)
    case versionMismatch(received: Int, expected: Int)
    case missingPayloadField(String)
    case attachFailed(String)
    case timeout
    case cancelled
    case noSessionID

    var errorDescription: String? {
        switch self {
        case .cryptoFailed(let msg): return "Encryption failed: \(msg)"
        case .streamClosed: return "Continuity stream closed unexpectedly"
        case .streamError(let msg): return "Continuity stream error: \(msg)"
        case .malformedFrame(let msg): return "Malformed transfer frame: \(msg)"
        case .versionMismatch(let r, let e): return "Transfer version mismatch (got \(r), expected \(e))"
        case .missingPayloadField(let f): return "Missing transfer payload field: \(f)"
        case .attachFailed(let msg): return "Attach to remote session failed: \(msg)"
        case .timeout: return "Transfer timed out"
        case .cancelled: return "Transfer cancelled"
        case .noSessionID: return "Session has no resumable sessionID yet"
        }
    }
}

nonisolated extension String {
    /// Removes terminal control sequences from text that may be displayed in
    /// SwiftUI sheets. Some Go-side errors can carry ANSI color escapes.
    var trzszTransferDisplaySafe: String {
        var output = ""
        output.reserveCapacity(count)

        var iterator = makeIterator()
        while let character = iterator.next() {
            if character == "\u{1b}" {
                guard let next = iterator.next() else { break }
                if next == "[" {
                    while let c = iterator.next() {
                        if let scalar = c.unicodeScalars.first,
                           scalar.value >= 0x40,
                           scalar.value <= 0x7e {
                            break
                        }
                    }
                } else if next == "]" {
                    while let c = iterator.next() {
                        if c == "\u{7}" { break }
                        if c == "\u{1b}" {
                            _ = iterator.next()
                            break
                        }
                    }
                }
                continue
            }

            if character.unicodeScalars.allSatisfy({ scalar in
                scalar.value < 0x20 || scalar.value == 0x7f
            }) {
                if character == "\n" || character == "\r" || character == "\t" {
                    output.append(" ")
                }
                continue
            }

            output.append(character)
        }

        let collapsed = output
            .split { $0.isWhitespace }
            .joined(separator: " ")
        return collapsed.isEmpty ? "Transfer failed" : collapsed
    }
}

nonisolated extension Error {
    var trzszTransferDisplayDescription: String {
        localizedDescription.trzszTransferDisplaySafe
    }
}
