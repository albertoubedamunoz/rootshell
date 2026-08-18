#if !targetEnvironment(macCatalyst)

import CommonCrypto
import Foundation

/// PBKDF2-SHA256 key derivation matching Go's `crypt.New`.
///
/// Go implementation:
/// ```go
/// key = pbkdf2.Key(passphrase, salt, 100, 32, sha256.New)
/// ```
nonisolated enum CrocKeyDerivation {

    /// Derive a 32-byte AES key from a passphrase and salt using PBKDF2-SHA256.
    /// - Parameters:
    ///   - passphrase: The passphrase bytes (from PAKE session key).
    ///   - salt: 8-byte salt. If nil, generates random salt.
    /// - Returns: Tuple of (derived 32-byte key, salt used).
    static func deriveKey(passphrase: Data, salt: Data? = nil) throws -> (key: Data, salt: Data) {
        guard !passphrase.isEmpty else {
            throw CrocError.pakeInitFailed("passphrase too short")
        }

        let actualSalt: Data
        if let salt {
            actualSalt = salt
        } else {
            var randomSalt = Data(count: 8)
            let status = randomSalt.withUnsafeMutableBytes { ptr in
                SecRandomCopyBytes(kSecRandomDefault, 8, ptr.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw CrocError.encryptionFailed
            }
            actualSalt = randomSalt
        }

        var derivedKey = Data(count: 32)
        let result = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passphrase.withUnsafeBytes { passphrasePtr in
                actualSalt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphrasePtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passphrase.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        actualSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100, // iterations — matches Go's pbkdf2.Key(..., 100, ...)
                        derivedKeyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw CrocError.encryptionFailed
        }

        return (derivedKey, actualSalt)
    }
}

#endif
