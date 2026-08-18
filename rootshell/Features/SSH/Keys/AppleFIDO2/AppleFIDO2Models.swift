//
//  AppleFIDO2Models.swift
//  rootshell
//
//  Data models for Apple AuthenticationServices WebAuthn SSH key support.
//  Credentials may be backed by either an external FIDO2 security key or a
//  platform passkey held by the user's passkey provider.
//
//  Supports: sk-ecdsa-sha2-nistp256@openssh.com (ECDSA P-256 only)
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

// MARK: - Credential Backing

/// The Authentication Services credential store that owns the private key.
///
/// Raw values are persisted in SSH key metadata. Do not rename them.
nonisolated enum AppleFIDO2CredentialBacking: String, Codable, Hashable, Sendable {
    case securityKey
    case platformPasskey

    var isPasskey: Bool { self == .platformPasskey }
}

// MARK: - Apple FIDO2 Credential Info

/// Information about a FIDO2 credential created via Apple AuthenticationServices
/// This data is stored alongside SSH key metadata for signing operations
nonisolated struct AppleFIDO2CredentialInfo: Codable, Hashable, Sendable {
    /// Credential ID returned from registration (opaque blob)
    let credentialID: Data

    /// Relying Party ID - always "ssh:" for SSH keys per OpenSSH standard
    let rpID: String

    /// User handle provided during credential creation
    let userHandle: Data

    /// User name associated with the credential (for display)
    let userName: String

    /// Public key in uncompressed EC point format (65 bytes: 0x04 + x + y)
    let publicKeyPoint: Data

    /// Date when the credential was created
    let createdDate: Date

    /// Whether the credential lives on an external authenticator or in the
    /// system passkey store. This determines which provider must be used for
    /// every future assertion.
    let backing: AppleFIDO2CredentialBacking

    /// Relying Party ID for FIDO2 credentials
    /// This must match the domain configured in Associated Domains entitlement
    /// and have a valid apple-app-site-association file at /.well-known/
    ///
    /// Note: OpenSSH uses "ssh:" but Apple requires a real web domain
    /// The domain only needs to serve the AASA file, not be a full website
    static let sshRpID = "beta.rootshell.com"

    /// SSH key type for ECDSA P-256 SK keys
    static let sshKeyType = "sk-ecdsa-sha2-nistp256@openssh.com"

    /// Public key in SSH wire format for authorized_keys
    var publicKeySSH: Data {
        buildSSHPublicKeyBlob()
    }

    /// Public key string for authorized_keys file
    var sshPublicKeyString: String {
        let base64 = publicKeySSH.base64EncodedString()
        return "\(Self.sshKeyType) \(base64) \(userName)"
    }

    init(
        credentialID: Data,
        rpID: String = AppleFIDO2CredentialInfo.sshRpID,
        userHandle: Data,
        userName: String,
        publicKeyPoint: Data,
        backing: AppleFIDO2CredentialBacking = .securityKey,
        createdDate: Date = Date()
    ) {
        self.credentialID = credentialID
        self.rpID = rpID
        self.userHandle = userHandle
        self.userName = userName
        self.publicKeyPoint = publicKeyPoint
        self.backing = backing
        self.createdDate = createdDate
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case credentialID, rpID, userHandle, userName, publicKeyPoint
        case createdDate, backing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentialID = try container.decode(Data.self, forKey: .credentialID)
        rpID = try container.decode(String.self, forKey: .rpID)
        userHandle = try container.decode(Data.self, forKey: .userHandle)
        userName = try container.decode(String.self, forKey: .userName)
        publicKeyPoint = try container.decode(Data.self, forKey: .publicKeyPoint)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        // Metadata written before passkey support only represented external
        // security keys, so that is the safe backward-compatible default.
        backing = try container.decodeIfPresent(
            AppleFIDO2CredentialBacking.self,
            forKey: .backing
        ) ?? .securityKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentialID, forKey: .credentialID)
        try container.encode(rpID, forKey: .rpID)
        try container.encode(userHandle, forKey: .userHandle)
        try container.encode(userName, forKey: .userName)
        try container.encode(publicKeyPoint, forKey: .publicKeyPoint)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(backing, forKey: .backing)
    }

    /// Build SSH wire format public key blob
    /// Format: algorithm || curve || point || application
    private func buildSSHPublicKeyBlob() -> Data {
        var buffer = Data()

        // Algorithm string
        let algo = Self.sshKeyType
        var algoLength = UInt32(algo.utf8.count).bigEndian
        buffer.append(Data(bytes: &algoLength, count: 4))
        buffer.append(algo.data(using: .utf8)!)

        // Curve identifier
        let curve = "nistp256"
        var curveLength = UInt32(curve.utf8.count).bigEndian
        buffer.append(Data(bytes: &curveLength, count: 4))
        buffer.append(curve.data(using: .utf8)!)

        // EC point (uncompressed)
        var pointLength = UInt32(publicKeyPoint.count).bigEndian
        buffer.append(Data(bytes: &pointLength, count: 4))
        buffer.append(publicKeyPoint)

        // Application (rpID)
        let appData = rpID.data(using: .utf8) ?? Data()
        var appLength = UInt32(appData.count).bigEndian
        buffer.append(Data(bytes: &appLength, count: 4))
        buffer.append(appData)

        return buffer
    }
}

// MARK: - Apple FIDO2 Signature Result

/// Result from an Apple AuthenticationServices FIDO2 assertion
nonisolated struct AppleFIDO2SignatureResult: Sendable {
    /// Raw signature from the authenticator (ECDSA DER format)
    let signature: Data

    /// Authenticator data containing flags and counter
    let authenticatorData: Data

    /// Raw client data JSON from WebAuthn (needed for webauthn-sk signature format)
    let clientDataJSON: Data

    /// Extracted flags byte from authenticator data
    var flags: UInt8 {
        guard authenticatorData.count >= 33 else { return 0x01 }
        return authenticatorData[32]
    }

    /// Extracted signature counter from authenticator data
    var counter: UInt32 {
        guard authenticatorData.count >= 37 else { return 0 }
        // Read bytes individually to avoid misaligned memory access
        return UInt32(authenticatorData[33]) << 24
             | UInt32(authenticatorData[34]) << 16
             | UInt32(authenticatorData[35]) << 8
             | UInt32(authenticatorData[36])
    }

    /// Extract origin from clientDataJSON
    var origin: String {
        guard let json = try? JSONSerialization.jsonObject(with: clientDataJSON) as? [String: Any],
              let origin = json["origin"] as? String else {
            return ""
        }
        return origin
    }

    /// Convert DER signature to SSH mpint format (r || s)
    /// SSH ECDSA signatures use two mpints, not DER encoding
    var sshSignatureData: Data {
        guard let (r, s) = parseDERSignature(signature) else {
            return signature
        }
        return buildSSHECDSASignature(r: r, s: s)
    }

    init(signature: Data, authenticatorData: Data, clientDataJSON: Data) {
        self.signature = signature
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
    }

    /// Parse DER-encoded ECDSA signature into r and s components
    private func parseDERSignature(_ der: Data) -> (r: Data, s: Data)? {
        let bytes = [UInt8](der)
        var offset = 0

        // SEQUENCE tag
        guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
        offset += 1

        // Length byte (may be multi-byte for long signatures, but P-256 fits in single byte)
        guard offset < bytes.count else { return nil }
        if bytes[offset] & 0x80 != 0 {
            // Multi-byte length - skip length bytes
            let numLengthBytes = Int(bytes[offset] & 0x7F)
            offset += 1 + numLengthBytes
        } else {
            offset += 1
        }

        // First INTEGER (r)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1

        guard offset < bytes.count else { return nil }
        let rLength = Int(bytes[offset])
        offset += 1

        guard offset + rLength <= bytes.count else { return nil }
        var rBytes = [UInt8](bytes[offset..<offset+rLength])
        offset += rLength

        // Second INTEGER (s)
        guard offset < bytes.count, bytes[offset] == 0x02 else { return nil }
        offset += 1

        guard offset < bytes.count else { return nil }
        let sLength = Int(bytes[offset])
        offset += 1

        guard offset + sLength <= bytes.count else { return nil }
        var sBytes = [UInt8](bytes[offset..<offset+sLength])

        // Remove leading zero bytes added for positive sign
        while rBytes.count > 32 && rBytes[0] == 0 {
            rBytes.removeFirst()
        }
        while sBytes.count > 32 && sBytes[0] == 0 {
            sBytes.removeFirst()
        }

        // Pad to 32 bytes if needed
        while rBytes.count < 32 {
            rBytes.insert(0, at: 0)
        }
        while sBytes.count < 32 {
            sBytes.insert(0, at: 0)
        }

        return (Data(rBytes), Data(sBytes))
    }

    /// Build SSH ECDSA signature format: mpint(r) || mpint(s)
    private func buildSSHECDSASignature(r: Data, s: Data) -> Data {
        var buffer = Data()

        // Write r as mpint
        let rMpint = toSSHMpint(r)
        var rLength = UInt32(rMpint.count).bigEndian
        buffer.append(Data(bytes: &rLength, count: 4))
        buffer.append(rMpint)

        // Write s as mpint
        let sMpint = toSSHMpint(s)
        var sLength = UInt32(sMpint.count).bigEndian
        buffer.append(Data(bytes: &sLength, count: 4))
        buffer.append(sMpint)

        return buffer
    }

    /// Convert unsigned integer bytes to SSH mpint format
    /// Adds leading zero if high bit is set (to indicate positive)
    private func toSSHMpint(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0]) }

        // Convert to array to avoid SubSequence indexing issues
        var bytes = [UInt8](data)

        // Skip leading zeros
        while bytes.count > 1 && bytes[0] == 0 {
            bytes.removeFirst()
        }

        // Add leading zero if high bit set (to keep positive)
        if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }

        return Data(bytes)
    }
}

// MARK: - Apple FIDO2 State

/// State for Apple FIDO2 operations (for UI feedback)
enum AppleFIDO2State: Equatable, Sendable {
    /// No operation in progress
    case idle

    /// Waiting for user interaction with security key
    case waitingForSecurityKey(operation: String)

    /// Operation completed successfully
    case success

    /// Operation failed
    case failed(String)

    var isWaiting: Bool {
        if case .waitingForSecurityKey = self { return true }
        return false
    }

    var operationDescription: String? {
        if case .waitingForSecurityKey(let operation) = self {
            return operation
        }
        return nil
    }
}

// MARK: - Apple FIDO2 Error

/// Errors specific to Apple AuthenticationServices FIDO2 operations
enum AppleFIDO2Error: LocalizedError, Sendable {
    /// User cancelled the operation
    case cancelled

    /// No security key available
    case noSecurityKey

    /// Passkeys cannot currently be created or used on this device.
    case passkeyUnavailable

    /// Credential not found on security key
    case credentialNotFound

    /// Invalid credential data
    case invalidCredential(String)

    /// Registration failed
    case registrationFailed(String)

    /// Assertion (signing) failed
    case assertionFailed(String)

    /// Platform not supported
    case platformNotSupported

    /// Invalid rpID for SSH
    case invalidRpID

    /// Unknown AuthenticationServices error
    case authServicesError(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return String(
                localized: "Operation was cancelled",
                comment: "WebAuthn SSH credential error: user cancelled"
            )
        case .noSecurityKey:
            return String(
                localized: "No security key detected. Connect your security key via USB-C, Lightning, or NFC.",
                comment: "WebAuthn SSH credential error: external security key unavailable"
            )
        case .passkeyUnavailable:
            return String(
                localized: "Passkeys are unavailable. Make sure a passkey provider is set up (iCloud Keychain, or a third-party manager like 1Password) and this device has a passcode.",
                comment: "WebAuthn SSH credential error: platform passkeys unavailable"
            )
        case .credentialNotFound:
            return String(
                localized: "Credential not found. It may not have synced to this device yet.",
                comment: "WebAuthn SSH credential error: saved credential is absent"
            )
        case .invalidCredential(let detail):
            return String(
                localized: "Invalid credential: \(detail)",
                comment: "WebAuthn SSH credential error with technical detail"
            )
        case .registrationFailed(let detail):
            return String(
                localized: "Failed to create credential: \(detail)",
                comment: "WebAuthn SSH credential registration error with technical detail"
            )
        case .assertionFailed(let detail):
            return String(
                localized: "Failed to sign: \(detail)",
                comment: "WebAuthn SSH credential signing error with technical detail"
            )
        case .platformNotSupported:
            return String(
                localized: "WebAuthn credentials are not supported on this device.",
                comment: "WebAuthn SSH credential error: unsupported platform"
            )
        case .invalidRpID:
            return String(
                localized: "Invalid relying party ID for SSH.",
                comment: "WebAuthn SSH credential error: invalid relying party"
            )
        case .authServicesError(let detail):
            return String(
                localized: "Authentication error: \(detail)",
                comment: "Authentication Services error with technical detail"
            )
        }
    }

    /// Whether this error indicates the user should retry
    var isRetryable: Bool {
        switch self {
        case .cancelled, .noSecurityKey, .passkeyUnavailable, .credentialNotFound:
            return true
        default:
            return false
        }
    }
}
