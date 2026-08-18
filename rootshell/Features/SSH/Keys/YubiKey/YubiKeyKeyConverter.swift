//
//  YubiKeyKeyConverter.swift
//  rootshell
//
//  Converts parsed SSH keys to YubiKit native types for PIV import
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log
import YubiKit
import Crypto
import NIOSSH

/// Converts parsed SSH private keys to YubiKit native types for PIV import
@MainActor
final class YubiKeyKeyConverter {
    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyKeyConverter"
    )

    // MARK: - Conversion Result

    /// Result of converting a key for YubiKey import
    enum ConvertedKey: Sendable {
        case ed25519(Ed25519.PrivateKey)
        case ec(EC.PrivateKey)
        case rsa(RSA.PrivateKey)
    }

    // MARK: - Ed25519 Conversion

    /// Convert Ed25519 key from seed bytes to YubiKit Ed25519.PrivateKey
    /// - Parameter seed: 32-byte Ed25519 private key seed
    /// - Returns: YubiKit Ed25519.PrivateKey
    static func convertEd25519(seed: Data) throws -> Ed25519.PrivateKey {
        Self.logger.info("Converting Ed25519 key from \(seed.count)-byte seed")

        guard seed.count == 32 else {
            throw YubiKeyError.keyConversionFailed("Ed25519 seed must be 32 bytes, got \(seed.count)")
        }

        guard let yubiKitKey = Ed25519.PrivateKey(seed: seed) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit Ed25519 private key from seed")
        }

        Self.logger.info("Ed25519 conversion successful")
        return yubiKitKey
    }

    // MARK: - ECDSA Conversion

    /// Convert ECDSA key from scalar and public point to YubiKit EC.PrivateKey
    /// - Parameters:
    ///   - scalar: Private scalar (k) bytes
    ///   - publicPoint: Uncompressed public point (0x04 || x || y) - optional, can derive from scalar
    ///   - curve: Elliptic curve type
    /// - Returns: YubiKit EC.PrivateKey
    static func convertECDSA(
        scalar: Data,
        publicPoint: Data?,
        curve: SSHKey.KeyType
    ) throws -> EC.PrivateKey {
        Self.logger.info("Converting ECDSA key: scalar=\(scalar.count) bytes, curve=\(curve.rawValue)")

        let ecCurve: EC.Curve
        let expectedScalarSize: Int

        switch curve {
        case .ecdsaP256:
            ecCurve = .secp256r1
            expectedScalarSize = 32
        case .ecdsaP384:
            ecCurve = .secp384r1
            expectedScalarSize = 48
        default:
            throw YubiKeyError.unsupportedKeyTypeForImport(curve.rawValue)
        }

        // Handle scalar that may have leading zero padding or be missing leading zeros
        var scalarData = scalar
        while scalarData.count > expectedScalarSize && scalarData.first == 0x00 {
            scalarData = scalarData.dropFirst()
        }
        while scalarData.count < expectedScalarSize {
            scalarData = Data([0x00]) + scalarData
        }

        guard scalarData.count == expectedScalarSize else {
            throw YubiKeyError.keyConversionFailed("ECDSA scalar must be \(expectedScalarSize) bytes, got \(scalarData.count)")
        }

        // Derive public key using CryptoKit, then create YubiKit key
        let yubiKitKey: EC.PrivateKey

        switch ecCurve {
        case .secp256r1:
            // Use CryptoKit to derive the public key from the scalar
            let cryptoKitKey = try P256.Signing.PrivateKey(rawRepresentation: scalarData)
            let publicKeyData = cryptoKitKey.publicKey.x963Representation

            // Parse uncompressed point to get x, y
            guard let parsedKey = EC.PrivateKey(x963: publicKeyData + scalarData, curve: .secp256r1) else {
                throw YubiKeyError.keyConversionFailed("Failed to create YubiKit EC private key for P-256")
            }
            yubiKitKey = parsedKey

        case .secp384r1:
            // Use CryptoKit to derive the public key from the scalar
            let cryptoKitKey = try P384.Signing.PrivateKey(rawRepresentation: scalarData)
            let publicKeyData = cryptoKitKey.publicKey.x963Representation

            // Parse uncompressed point to get x, y
            guard let parsedKey = EC.PrivateKey(x963: publicKeyData + scalarData, curve: .secp384r1) else {
                throw YubiKeyError.keyConversionFailed("Failed to create YubiKit EC private key for P-384")
            }
            yubiKitKey = parsedKey
        }

        let curveDesc = ecCurve == .secp256r1 ? "P-256" : "P-384"
        Self.logger.info("ECDSA conversion successful for \(curveDesc)")
        return yubiKitKey
    }

    // MARK: - RSA Conversion

    /// Convert RSA key from CRT parameters to YubiKit RSA.PrivateKey
    /// - Parameter crtParams: RSA CRT parameters (n, e, d, p, q, dP, dQ, qInv)
    /// - Returns: YubiKit RSA.PrivateKey
    static func convertRSA(crtParams: SSHKeyParser.RSACRTParameters) throws -> RSA.PrivateKey {
        Self.logger.info("Converting RSA key: n=\(crtParams.n.count) bytes")

        // YubiKit RSA.PrivateKey requires all CRT parameters
        guard let yubiKitKey = RSA.PrivateKey(
            n: crtParams.n,
            e: crtParams.e,
            d: crtParams.d,
            p: crtParams.p,
            q: crtParams.q,
            dP: crtParams.dP,
            dQ: crtParams.dQ,
            qInv: crtParams.qInv
        ) else {
            throw YubiKeyError.keyConversionFailed("Failed to create YubiKit RSA private key from CRT parameters")
        }

        Self.logger.info("RSA conversion successful, key size: \(yubiKitKey.size.rawValue) bits")
        return yubiKitKey
    }

    // MARK: - Auto-Detection Conversion

    /// Convert a parsed SSH key to the appropriate YubiKit key type
    /// - Parameters:
    ///   - parsedKey: The parsed SSH key from SSHKeyParser
    ///   - keyType: The SSH key type
    /// - Returns: ConvertedKey containing the YubiKit key
    static func convert(parsedKey: SSHKeyParser.ParsedKey) throws -> ConvertedKey {
        switch parsedKey.keyType {
        case .ed25519:
            // For Ed25519, we need to extract the seed from the NIO key
            guard let nioKey = parsedKey.nioSSHKey else {
                throw YubiKeyError.keyConversionFailed("Missing NIO SSH key for Ed25519")
            }
            let seed = try extractEd25519Seed(from: nioKey)
            let yubiKitKey = try convertEd25519(seed: seed)
            return .ed25519(yubiKitKey)

        case .ecdsaP256, .ecdsaP384:
            guard let nioKey = parsedKey.nioSSHKey else {
                throw YubiKeyError.keyConversionFailed("Missing NIO SSH key for ECDSA")
            }
            let scalar = try extractECDSAScalar(from: nioKey, keyType: parsedKey.keyType)
            let yubiKitKey = try convertECDSA(scalar: scalar, publicPoint: nil, curve: parsedKey.keyType)
            return .ec(yubiKitKey)

        case .rsa:
            guard let crtParams = parsedKey.rsaCRTParams else {
                throw YubiKeyError.missingCRTParameters
            }
            let yubiKitKey = try convertRSA(crtParams: crtParams)
            return .rsa(yubiKitKey)

        case .ecdsaP521:
            throw YubiKeyError.unsupportedKeyTypeForImport("ECDSA P-521 (not supported by YubiKey PIV)")

        case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
            throw YubiKeyError.unsupportedKeyTypeForImport("ML-DSA (not supported by YubiKey PIV)")

        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            throw YubiKeyError.keyAlreadyOnHardware

        case .externalAgent:
            throw YubiKeyError.unsupportedKeyTypeForImport("external SSH agent key (no private material)")
        }
    }

    // MARK: - Private Helpers

    /// Extract Ed25519 seed from NIOSSHPrivateKey
    private static func extractEd25519Seed(from nioKey: NIOSSHPrivateKey) throws -> Data {
        // NIOSSHPrivateKey wraps Curve25519.Signing.PrivateKey
        // We need to access the raw representation (seed)
        // Unfortunately NIOSSHPrivateKey doesn't expose this directly,
        // so we need to use reflection or re-parse the key

        // The cleanest approach is to use the key's signing capability to derive the seed
        // However, NIOSSHPrivateKey doesn't expose rawRepresentation

        // Alternative: When we parse the key, we have access to the seed in the parse functions
        // For now, throw an error - the importer should use the raw seed from parsing
        throw YubiKeyError.keyConversionFailed(
            "Ed25519 seed extraction requires raw key data. Use the seed from key parsing directly."
        )
    }

    /// Extract ECDSA scalar from NIOSSHPrivateKey
    private static func extractECDSAScalar(from nioKey: NIOSSHPrivateKey, keyType: SSHKey.KeyType) throws -> Data {
        // Similar to Ed25519, NIOSSHPrivateKey doesn't expose the raw scalar
        throw YubiKeyError.keyConversionFailed(
            "ECDSA scalar extraction requires raw key data. Use the scalar from key parsing directly."
        )
    }
}

// MARK: - Extended ParsedKey Conversion

extension SSHKeyParser.ParsedKey {
    /// Check if this key type can be imported to YubiKey PIV
    var canImportToYubiKey: Bool {
        switch keyType {
        case .ed25519, .ecdsaP256, .ecdsaP384, .rsa:
            return true
        case .ecdsaP521, .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
            // Not supported by YubiKey PIV
            return false
        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            // Already on hardware / hardware-protected
            return false
        case .externalAgent:
            // No private material in the app to move to hardware
            return false
        }
    }

    /// Reason why this key cannot be imported, or nil if it can be imported
    var importBlockReason: String? {
        switch keyType {
        case .ecdsaP521:
            return "ECDSA P-521 is not supported by YubiKey PIV"
        case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87:
            return "ML-DSA keys are not supported by YubiKey PIV"
        case .yubiKeyPIV, .yubiKeyFIDO2, .appleFIDO2, .applePasskey, .secureEnclaveP256:
            return "Key is already stored on hardware"
        default:
            return nil
        }
    }
}
