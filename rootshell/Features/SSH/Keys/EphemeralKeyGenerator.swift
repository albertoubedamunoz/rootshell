//
//  EphemeralKeyGenerator.swift
//  rootshell
//
//  Generates ephemeral Ed25519 SSH key pairs for EC2 Serial Console.
//  Keys are never persisted - they exist only in memory for the connection.
//

import Foundation
import Crypto
import NIOSSH

/// Ephemeral SSH key pair for EC2 Serial Console authentication.
/// The key is only valid for 60 seconds after being uploaded to AWS.
struct EphemeralSSHKey: Sendable {
    /// The private key for SSH authentication
    let privateKey: Curve25519.Signing.PrivateKey

    /// The NIO SSH private key wrapper for use with SSHSession
    let nioSSHPrivateKey: NIOSSHPrivateKey

    /// Public key in OpenSSH format for AWS API (e.g., "ssh-ed25519 AAAA...")
    let publicKeyOpenSSH: String

    /// Generate a new ephemeral Ed25519 key pair
    static func generate() -> EphemeralSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let nioKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        let publicKeyOpenSSH = formatAsOpenSSHPublicKey(privateKey.publicKey)

        return EphemeralSSHKey(
            privateKey: privateKey,
            nioSSHPrivateKey: nioKey,
            publicKeyOpenSSH: publicKeyOpenSSH
        )
    }

    /// Format Ed25519 public key in OpenSSH wire format
    /// Format: "ssh-ed25519 BASE64(type-string-length + type-string + key-length + key)"
    private static func formatAsOpenSSHPublicKey(_ publicKey: Curve25519.Signing.PublicKey) -> String {
        let keyType = "ssh-ed25519"
        let keyTypeData = keyType.data(using: .utf8)!
        let rawKeyData = publicKey.rawRepresentation

        // Build SSH wire format: string(keyType) + string(publicKey)
        var wireFormat = Data()

        // Write key type as SSH string (4-byte big-endian length + UTF-8 bytes)
        var keyTypeLength = UInt32(keyTypeData.count).bigEndian
        wireFormat.append(Data(bytes: &keyTypeLength, count: 4))
        wireFormat.append(keyTypeData)

        // Write public key as SSH string (4-byte big-endian length + key bytes)
        var keyLength = UInt32(rawKeyData.count).bigEndian
        wireFormat.append(Data(bytes: &keyLength, count: 4))
        wireFormat.append(rawKeyData)

        // Base64 encode the wire format
        let base64 = wireFormat.base64EncodedString()

        return "\(keyType) \(base64)"
    }
}

/// Utility for generating ephemeral SSH keys
enum EphemeralKeyGenerator {
    /// Generate an ephemeral Ed25519 key pair for EC2 Serial Console
    /// - Returns: EphemeralSSHKey containing NIO private key and OpenSSH public key string
    static func generateEd25519() -> EphemeralSSHKey {
        return EphemeralSSHKey.generate()
    }
}
