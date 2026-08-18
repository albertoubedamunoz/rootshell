#if !targetEnvironment(macCatalyst)

import CryptoKit
import Foundation

/// AES-256-GCM encryption/decryption matching Go's `crypt.Encrypt`/`crypt.Decrypt`.
///
/// Wire format: `[nonce (12 bytes)][ciphertext + tag]`
/// Go produces: `append(ivBytes, aesgcm.Seal(nil, ivBytes, plaintext, nil)...)`
/// CryptoKit's `AES.GCM.SealedBox` uses the same format when constructed with combined representation.
nonisolated enum CrocEncryption {

    /// Encrypt plaintext using AES-256-GCM with a random 12-byte nonce.
    /// Output format: `[nonce (12)][ciphertext][tag (16)]` — matches Go's format.
    static func encrypt(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw CrocError.invalidKey }
        let symmetricKey = SymmetricKey(data: key)
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        // combined = nonce + ciphertext + tag — matches Go's wire format exactly
        guard let combined = sealedBox.combined else { throw CrocError.encryptionFailed }
        return combined
    }

    /// Decrypt data that was encrypted with AES-256-GCM.
    /// Input format: `[nonce (12)][ciphertext][tag (16)]`.
    static func decrypt(_ encrypted: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw CrocError.invalidKey }
        guard encrypted.count >= 13 else { throw CrocError.decryptionFailed }
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
}

#endif
