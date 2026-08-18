//
//  VPNKeyParser.swift
//  VPNTunnelExtension
//
//  Self-contained SSH key parser for the VPN extension.
//  Handles OpenSSH and PEM formats, including encrypted keys.
//  Adapted from the main app's SSHKeyParser + OpenSSHKeyDecryption.
//

import Foundation
import Crypto
import NIOSSH
import NIOCore
import NIOFoundationCompat
@preconcurrency import Citadel
import CCryptoBoringSSL
import CCitadelBcrypt

/// Parsed key result — returns the raw CryptoKit/Citadel key type.
enum VPNParsedKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case ecdsaP256(P256.Signing.PrivateKey)
    case ecdsaP384(P384.Signing.PrivateKey)
    case ecdsaP521(P521.Signing.PrivateKey)
    case rsa(Insecure.RSA.PrivateKey)
}

enum VPNKeyParserError: LocalizedError {
    case invalidFormat
    case unsupportedKeyType(String)
    case encryptedKeyNeedsPassphrase
    case incorrectPassphrase
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Invalid SSH key format"
        case .unsupportedKeyType(let t): return "Unsupported key type: \(t)"
        case .encryptedKeyNeedsPassphrase: return "Encrypted key requires passphrase"
        case .incorrectPassphrase: return "Incorrect passphrase"
        case .parseError(let m): return "Key parse error: \(m)"
        }
    }
}

// Initialize bcrypt SHA512 for encrypted key decryption
private nonisolated enum BCryptInit {
    static let done: Bool = {
        citadel_set_crypto_hash_sha512 { output, input, inputLength in
            CCryptoBoringSSL_EVP_Digest(input, Int(inputLength), output, nil, CCryptoBoringSSL_EVP_sha512(), nil)
        }
        return true
    }()
    static func ensure() { _ = done }
}

/// SSH key parser for the VPN extension. Supports Ed25519, ECDSA, and RSA keys
/// in OpenSSH and PEM formats, including encrypted keys.
nonisolated enum VPNKeyParser {

    static func parse(keyString: String, passphrase: String? = nil) throws -> VPNParsedKey {
        let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSH(keyString: trimmed, passphrase: passphrase)
        }

        if trimmed.hasPrefix("-----BEGIN PRIVATE KEY-----") ||
           trimmed.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") {
            return try parsePEM(keyString: trimmed)
        }

        throw VPNKeyParserError.invalidFormat
    }

    // MARK: - OpenSSH Format

    private static func parseOpenSSH(keyString: String, passphrase: String?) throws -> VPNParsedKey {
        let lines = keyString.components(separatedBy: .newlines)
        let b64 = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        guard let data = Data(base64Encoded: b64) else {
            throw VPNKeyParserError.parseError("Invalid base64")
        }

        var buf = ByteBuffer(data: data)

        // Magic: "openssh-key-v1\0"
        guard buf.readString(length: 14) == "openssh-key-v1",
              buf.readInteger(as: UInt8.self) == 0x00 else {
            throw VPNKeyParserError.parseError("Invalid OpenSSH magic")
        }

        // Cipher and KDF
        guard let cipherName = buf.readSSHString() else {
            throw VPNKeyParserError.parseError("Missing cipher")
        }
        guard let kdfName = buf.readSSHString() else {
            throw VPNKeyParserError.parseError("Missing KDF name")
        }
        guard var kdfOpts = buf.readSSHBuffer() else {
            throw VPNKeyParserError.parseError("Missing KDF options")
        }

        let isEncrypted = cipherName != "none"
        if isEncrypted && passphrase == nil {
            throw VPNKeyParserError.encryptedKeyNeedsPassphrase
        }

        // Number of keys
        guard let numKeys = buf.readInteger(as: UInt32.self), numKeys == 1 else {
            throw VPNKeyParserError.parseError("Multiple keys not supported")
        }

        // Skip public key blob
        guard buf.readSSHBuffer() != nil else {
            throw VPNKeyParserError.parseError("Missing public key")
        }

        // Private key blob
        guard var privBuf = buf.readSSHBuffer() else {
            throw VPNKeyParserError.parseError("Missing private key")
        }

        // Decrypt if encrypted
        if isEncrypted {
            let (keyLen, ivLen) = try cipherLengths(cipherName)
            let derivedKey = try deriveKey(
                kdfName: kdfName, kdfOpts: &kdfOpts,
                passphrase: passphrase!, totalLen: keyLen + ivLen
            )
            let key = Array(derivedKey[..<keyLen])
            let iv = Array(derivedKey[keyLen...])
            try decryptAES(cipherName: cipherName, buffer: &privBuf, key: key, iv: iv)
        }

        // Verify check bytes
        guard let c1 = privBuf.readInteger(as: UInt32.self),
              let c2 = privBuf.readInteger(as: UInt32.self),
              c1 == c2 else {
            throw VPNKeyParserError.incorrectPassphrase
        }

        guard let keyType = privBuf.readSSHString() else {
            throw VPNKeyParserError.parseError("Missing key type")
        }

        switch keyType {
        case "ssh-ed25519":
            return try parseOpenSSHEd25519(&privBuf)
        case _ where keyType.hasPrefix("ecdsa-sha2-"):
            return try parseOpenSSHECDSA(&privBuf)
        case "ssh-rsa":
            return try parseOpenSSHRSA(&privBuf)
        default:
            throw VPNKeyParserError.unsupportedKeyType(keyType)
        }
    }

    private static func parseOpenSSHEd25519(_ buf: inout ByteBuffer) throws -> VPNParsedKey {
        // Public key (32 bytes)
        guard buf.readSSHBuffer() != nil else {
            throw VPNKeyParserError.parseError("Missing ed25519 public key")
        }
        // Private key (64 bytes: 32 seed + 32 public)
        guard var privBuf = buf.readSSHBuffer(), privBuf.readableBytes >= 32,
              let seed = privBuf.readBytes(length: 32) else {
            throw VPNKeyParserError.parseError("Invalid ed25519 private key")
        }
        return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }

    private static func parseOpenSSHECDSA(_ buf: inout ByteBuffer) throws -> VPNParsedKey {
        guard let curveName = buf.readSSHString() else {
            throw VPNKeyParserError.parseError("Missing curve name")
        }
        // Public point
        guard buf.readSSHBuffer() != nil else {
            throw VPNKeyParserError.parseError("Missing ECDSA public key")
        }
        // Private scalar
        guard let scalarBuf = buf.readSSHBuffer(),
              let scalar = scalarBuf.getData(at: scalarBuf.readerIndex, length: scalarBuf.readableBytes) else {
            throw VPNKeyParserError.parseError("Missing ECDSA private key")
        }

        switch curveName {
        case "nistp256":
            return .ecdsaP256(try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case "nistp384":
            return .ecdsaP384(try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case "nistp521":
            return .ecdsaP521(try P521.Signing.PrivateKey(rawRepresentation: scalar))
        default:
            throw VPNKeyParserError.unsupportedKeyType(curveName)
        }
    }

    private static func parseOpenSSHRSA(_ buf: inout ByteBuffer) throws -> VPNParsedKey {
        // OpenSSH RSA: n, e, d, iqmp, p, q
        guard let nLen = buf.readInteger(as: UInt32.self),
              let nBytes = buf.readBytes(length: Int(nLen)),
              let eLen = buf.readInteger(as: UInt32.self),
              let eBytes = buf.readBytes(length: Int(eLen)),
              let dLen = buf.readInteger(as: UInt32.self),
              let dBytes = buf.readBytes(length: Int(dLen)) else {
            throw VPNKeyParserError.parseError("Failed to read RSA components")
        }
        // Skip iqmp, p, q (not needed for auth)
        let rsaKey = try createRSAKey(n: Data(nBytes), e: Data(eBytes), d: Data(dBytes))
        return .rsa(rsaKey)
    }

    // MARK: - PEM Format

    private static func parsePEM(keyString: String) throws -> VPNParsedKey {
        let lines = keyString.components(separatedBy: .newlines)
        let b64 = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }.joined()
        guard let der = Data(base64Encoded: b64) else {
            throw VPNKeyParserError.parseError("Invalid PEM base64")
        }

        if keyString.contains("BEGIN RSA PRIVATE KEY") {
            return try parsePKCS1RSA(der)
        }

        // PKCS8 — try each key type
        if let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: extractPKCS8Key(der, expectedLen: 32)) {
            return .ed25519(k)
        }
        if let k = try? P256.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP256(k) }
        if let k = try? P384.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP384(k) }
        if let k = try? P521.Signing.PrivateKey(derRepresentation: der) { return .ecdsaP521(k) }

        throw VPNKeyParserError.invalidFormat
    }

    /// Extract raw key bytes from PKCS8 DER for Ed25519.
    private static func extractPKCS8Key(_ der: Data, expectedLen: Int) throws -> Data {
        // PKCS8: SEQUENCE { INTEGER(version), SEQUENCE(algorithm), OCTET STRING { OCTET STRING(key) } }
        var off = 0
        guard der.count >= 48, der[off] == 0x30 else { throw VPNKeyParserError.invalidFormat }
        off += 1
        let (_, o1) = try readASN1Length(der, off); off = o1
        // Skip version INTEGER
        guard der[off] == 0x02 else { throw VPNKeyParserError.invalidFormat }
        off += 1
        let (vl, o2) = try readASN1Length(der, off); off = o2 + vl
        // Skip algorithm SEQUENCE
        guard der[off] == 0x30 else { throw VPNKeyParserError.invalidFormat }
        off += 1
        let (al, o3) = try readASN1Length(der, off); off = o3 + al
        // Outer OCTET STRING
        guard der[off] == 0x04 else { throw VPNKeyParserError.invalidFormat }
        off += 1
        let (_, o4) = try readASN1Length(der, off); off = o4
        // Inner OCTET STRING
        guard der[off] == 0x04 else { throw VPNKeyParserError.invalidFormat }
        off += 1
        let (kl, o5) = try readASN1Length(der, off); off = o5
        guard kl == expectedLen, off + expectedLen <= der.count else { throw VPNKeyParserError.invalidFormat }
        return der.subdata(in: off..<(off + expectedLen))
    }

    private static func parsePKCS1RSA(_ der: Data) throws -> VPNParsedKey {
        var off = 0
        guard der[off] == 0x30 else { throw VPNKeyParserError.parseError("Not a SEQUENCE") }
        off += 1
        let (_, o1) = try readASN1Length(der, off); off = o1
        // Skip version
        let (_, o2) = try readASN1Integer(der, off); off = o2
        let (n, o3) = try readASN1Integer(der, off); off = o3
        let (e, o4) = try readASN1Integer(der, off); off = o4
        let (d, _) = try readASN1Integer(der, off)
        return .rsa(try createRSAKey(n: n, e: e, d: d))
    }

    // MARK: - ASN.1 Helpers

    private static func readASN1Length(_ data: Data, _ offset: Int) throws -> (Int, Int) {
        guard offset < data.count else { throw VPNKeyParserError.parseError("Truncated ASN.1") }
        let b = data[offset]
        if b & 0x80 == 0 { return (Int(b), offset + 1) }
        let nb = Int(b & 0x7F)
        guard offset + 1 + nb <= data.count else { throw VPNKeyParserError.parseError("Truncated length") }
        var len = 0
        for i in 0..<nb { len = (len << 8) | Int(data[offset + 1 + i]) }
        return (len, offset + 1 + nb)
    }

    private static func readASN1Integer(_ data: Data, _ offset: Int) throws -> (Data, Int) {
        guard offset < data.count, data[offset] == 0x02 else {
            throw VPNKeyParserError.parseError("Not an INTEGER")
        }
        let (len, co) = try readASN1Length(data, offset + 1)
        guard co + len <= data.count else { throw VPNKeyParserError.parseError("Truncated INTEGER") }
        var d = data.subdata(in: co..<(co + len))
        if d.count > 1 && d[d.startIndex] == 0x00 { d = d.dropFirst() }
        return (d, co + len)
    }

    // MARK: - RSA Key Construction (via BoringSSL)

    private static func createRSAKey(n: Data, e: Data, d: Data) throws -> Insecure.RSA.PrivateKey {
        // Citadel's Insecure.RSA.PrivateKey takes raw BIGNUM pointers (d, e, n)
        guard let d_bn = CCryptoBoringSSL_BN_bin2bn(Array(d), d.count, nil) else {
            throw VPNKeyParserError.parseError("Failed to create RSA BIGNUM for d")
        }
        guard let e_bn = CCryptoBoringSSL_BN_bin2bn(Array(e), e.count, nil) else {
            throw VPNKeyParserError.parseError("Failed to create RSA BIGNUM for e")
        }
        guard let n_bn = CCryptoBoringSSL_BN_bin2bn(Array(n), n.count, nil) else {
            throw VPNKeyParserError.parseError("Failed to create RSA BIGNUM for n")
        }

        return Insecure.RSA.PrivateKey(
            privateExponent: d_bn,
            publicExponent: e_bn,
            modulus: n_bn
        )
    }

    // MARK: - Encryption Support

    private static func cipherLengths(_ name: String) throws -> (keyLen: Int, ivLen: Int) {
        switch name {
        case "aes128-ctr": return (16, 16)
        case "aes256-ctr": return (32, 16)
        default: throw VPNKeyParserError.parseError("Unsupported cipher: \(name)")
        }
    }

    private static func deriveKey(
        kdfName: String, kdfOpts: inout ByteBuffer,
        passphrase: String, totalLen: Int
    ) throws -> [UInt8] {
        guard kdfName == "bcrypt" else {
            throw VPNKeyParserError.parseError("Unsupported KDF: \(kdfName)")
        }
        BCryptInit.ensure()

        guard var salt = kdfOpts.readSSHBuffer(),
              let iterations = kdfOpts.readInteger(as: UInt32.self) else {
            throw VPNKeyParserError.parseError("Invalid bcrypt KDF options")
        }
        guard let saltBytes = salt.readBytes(length: salt.readableBytes) else {
            throw VPNKeyParserError.parseError("Failed to read salt")
        }

        let passData = passphrase.data(using: .utf8)!
        return try passData.withUnsafeBytes { passBuf in
            guard let base = passBuf.baseAddress else {
                throw VPNKeyParserError.parseError("Empty passphrase")
            }
            var derived = [UInt8](repeating: 0, count: totalLen)
            guard citadel_bcrypt_pbkdf(
                base, passBuf.count,
                saltBytes, saltBytes.count,
                &derived, totalLen,
                iterations
            ) == 0 else {
                throw VPNKeyParserError.incorrectPassphrase
            }
            return derived
        }
    }

    private static func decryptAES(
        cipherName: String, buffer: inout ByteBuffer,
        key: [UInt8], iv: [UInt8]
    ) throws {
        let cipher: OpaquePointer
        switch cipherName {
        case "aes128-ctr": cipher = CCryptoBoringSSL_EVP_aes_128_ctr()
        case "aes256-ctr": cipher = CCryptoBoringSSL_EVP_aes_256_ctr()
        default: throw VPNKeyParserError.parseError("Unsupported cipher: \(cipherName)")
        }

        guard buffer.readableBytes % 16 == 0, buffer.readableBytes > 0 else { return }

        let ctx = CCryptoBoringSSL_EVP_CIPHER_CTX_new()
        defer { CCryptoBoringSSL_EVP_CIPHER_CTX_free(ctx) }

        guard CCryptoBoringSSL_EVP_CipherInit(ctx, cipher, key, iv, 0) == 1 else {
            throw VPNKeyParserError.parseError("AES init failed")
        }

        try buffer.withUnsafeMutableReadableBytes { raw in
            guard var ptr = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16) { tmp in
                guard let tmpBase = tmp.baseAddress else { return }
                for _ in 0..<raw.count / 16 {
                    guard CCryptoBoringSSL_EVP_Cipher(ctx, tmpBase, ptr, 16) == 1 else {
                        throw VPNKeyParserError.parseError("AES decrypt failed")
                    }
                    ptr.update(from: tmpBase, count: 16)
                    ptr += 16
                }
            }
        }
    }
}

// MARK: - ByteBuffer SSH Extensions (for VPN extension)

nonisolated extension ByteBuffer {
    /// Read SSH string (4-byte length + UTF-8 data). Only defined in VPN extension scope.
    mutating func readSSHString() -> String? {
        guard var buf = readSSHBuffer() else { return nil }
        guard let data = buf.readData(length: buf.readableBytes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Read SSH buffer (4-byte length + data).
    mutating func readSSHBuffer() -> ByteBuffer? {
        guard let length = readInteger(as: UInt32.self) else { return nil }
        return readSlice(length: Int(length))
    }
}
