//
//  LegacyRSASignature.swift
//  rootshell
//
//  Legacy ssh-rsa signature support for compatibility with older SSH servers.
//  AWS EC2 Serial Console uses ssh-rsa signatures rather than modern rsa-sha2-256.
//

import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Citadel
import Crypto

// MARK: - Legacy RSA Signature

/// Legacy RSA signature type that uses the "ssh-rsa" prefix.
/// AWS EC2 Serial Console and many other servers still use this format.
public struct LegacyRSASignature: ContiguousBytes, NIOSSHSignatureProtocol {
    // Use the legacy ssh-rsa prefix instead of rsa-sha2-256
    public static let signaturePrefix = "ssh-rsa"

    public let rawRepresentation: Data

    public init<D>(rawRepresentation: D) where D: DataProtocol {
        self.rawRepresentation = Data(rawRepresentation)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try rawRepresentation.withUnsafeBytes(body)
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        // SSH signature format: string of raw signature bytes
        var written = buffer.writeInteger(UInt32(rawRepresentation.count))
        written += buffer.writeBytes(rawRepresentation)
        return written
    }

    public static func read(from buffer: inout ByteBuffer) throws -> LegacyRSASignature {
        guard let length = buffer.readInteger(as: UInt32.self),
              let data = buffer.readData(length: Int(length)) else {
            throw LegacyRSAError.invalidSignatureFormat
        }

        return LegacyRSASignature(rawRepresentation: data)
    }
}

// MARK: - Legacy RSA Public Key Wrapper

/// Wrapper around Citadel's RSA public key that accepts legacy ssh-rsa signatures.
/// This is needed because Citadel's RSA public key expects rsa-sha2-256 signatures,
/// but AWS EC2 Serial Console sends ssh-rsa (SHA-1 based) signatures.
public final class LegacyRSAPublicKey: NIOSSHPublicKeyProtocol {
    public static let publicKeyPrefix = "ssh-rsa"

    /// The wrapped Citadel RSA public key that does the actual crypto work
    private let wrapped: Insecure.RSA.PublicKey

    public var rawRepresentation: Data {
        wrapped.rawRepresentation
    }

    public init(wrapped: Insecure.RSA.PublicKey) {
        self.wrapped = wrapped
    }

    public func write(to buffer: inout ByteBuffer) -> Int {
        wrapped.write(to: &buffer)
    }

    public static func read(from buffer: inout ByteBuffer) throws -> LegacyRSAPublicKey {
        let citadelKey = try Insecure.RSA.PublicKey.read(from: &buffer)
        return LegacyRSAPublicKey(wrapped: citadelKey)
    }

    public func isValidSignature<D>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool where D: DataProtocol {
        // Accept either legacy ssh-rsa signatures or modern rsa-sha2-256 signatures
        if let legacySig = signature as? LegacyRSASignature {
            // Convert to Citadel signature format and validate
            let citadelSig = Insecure.RSA.Signature(rawRepresentation: legacySig.rawRepresentation)
            return wrapped.isValidSignature(citadelSig, for: data)
        } else if let modernSig = signature as? Insecure.RSA.Signature {
            return wrapped.isValidSignature(modernSig, for: data)
        }
        return false
    }
}

// MARK: - Errors

/// Error types for legacy RSA operations
enum LegacyRSAError: Error {
    case invalidSignatureFormat
}
