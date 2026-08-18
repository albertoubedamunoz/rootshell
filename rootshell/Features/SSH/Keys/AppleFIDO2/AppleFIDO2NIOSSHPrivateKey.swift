//
//  AppleFIDO2NIOSSHPrivateKey.swift
//  rootshell
//
//  NIOSSH integration for Apple FIDO2 SK (Security Key) SSH authentication
//  Routes signing through AppleFIDO2Signer and formats responses for
//  sk-ecdsa-sha2-nistp256@openssh.com
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOSSH
import NIOCore
import os.log

// MARK: - Shared Logger

nonisolated private let appleFIDO2NIOSSHLogger = Logger(
    subsystem: "com.rootshell",
    category: "AppleFIDO2NIOSSH"
)

// MARK: - Apple FIDO2 Reference

/// Reference to an Apple FIDO2 credential for use in SSHPrivateKeyVariant
/// Contains only the information needed to locate and use the credential
struct AppleFIDO2Reference: Sendable, Hashable {
    /// SSHKey.id for looking up metadata
    let keyID: UUID

    /// Credential ID from registration
    let credentialID: Data

    /// Cached public key blob in SSH wire format
    let publicKeyBlob: Data

    /// User name for display
    let userName: String

    /// Authentication Services credential store used for assertions.
    let backing: AppleFIDO2CredentialBacking
}

// MARK: - ECDSA-SK P-256 Public Key for Apple FIDO2

/// ECDSA P-256 SK public key for Apple FIDO2 authentication
struct AppleFIDO2ECDSASKP256PublicKey: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    // Use WebAuthn-specific key type that matches the signature format
    static var publicKeyPrefix: String { "webauthn-sk-ecdsa-sha2-nistp256@openssh.com" }

    /// OpenSSH certificate support: certs minted by `ssh-keygen -s` over an sk-ecdsa
    /// public key carry this type name; the embedded components (curve, point,
    /// application) parse via `read(from:)`. The userauth signature stays the
    /// WebAuthn format above.
    static var certifiedKeyPrefix: String? { "sk-ecdsa-sha2-nistp256-cert-v01@openssh.com" }

    private let publicKeyPoint: Data  // Uncompressed EC point (65 bytes: 0x04 + x + y)
    private let application: String   // "ssh:" for SSH keys
    let publicKeyBlob: Data

    var rawRepresentation: Data { publicKeyPoint }

    init(reference: AppleFIDO2Reference) {
        self.publicKeyBlob = reference.publicKeyBlob
        self.application = AppleFIDO2CredentialInfo.sshRpID
        self.publicKeyPoint = Self.extractECPoint(from: reference.publicKeyBlob)
    }

    init(publicKeyPoint: Data, application: String = AppleFIDO2CredentialInfo.sshRpID) {
        self.publicKeyPoint = publicKeyPoint
        self.application = application
        self.publicKeyBlob = Self.buildPublicKeyBlob(publicKeyPoint: publicKeyPoint, application: application)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        return false  // Server verifies signatures
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = 0

        // Write curve identifier
        let curve = "nistp256"
        let curveData = curve.data(using: .utf8) ?? Data()
        written += buffer.writeInteger(UInt32(curveData.count))
        written += buffer.writeBytes(curveData)

        // Write EC point
        written += buffer.writeInteger(UInt32(publicKeyPoint.count))
        written += buffer.writeBytes(publicKeyPoint)

        // Write application string
        let appData = application.data(using: .utf8) ?? Data()
        written += buffer.writeInteger(UInt32(appData.count))
        written += buffer.writeBytes(appData)

        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> AppleFIDO2ECDSASKP256PublicKey {
        // Mirrors write(to:): string curve, string ec point, string application.
        // Used when parsing sk-ecdsa certificates (the cert embeds these components).
        guard
            let curveLength = buffer.readInteger(as: UInt32.self),
            let curve = buffer.readBytes(length: Int(curveLength)),
            String(decoding: curve, as: UTF8.self) == "nistp256",
            let pointLength = buffer.readInteger(as: UInt32.self),
            let point = buffer.readBytes(length: Int(pointLength)),
            let appLength = buffer.readInteger(as: UInt32.self),
            let app = buffer.readBytes(length: Int(appLength))
        else {
            throw AppleFIDO2Error.assertionFailed(
                String(
                    localized: "Invalid sk-ecdsa public key encoding.",
                    comment: "WebAuthn SSH key parsing error detail"
                )
            )
        }

        return AppleFIDO2ECDSASKP256PublicKey(
            publicKeyPoint: Data(point),
            application: String(decoding: app, as: UTF8.self)
        )
    }

    private static func extractECPoint(from blob: Data) -> Data {
        var offset = 0
        let bytes = [UInt8](blob)

        // Helper to read big-endian UInt32 without alignment issues
        func readUInt32(at index: Int) -> UInt32 {
            guard index + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[index]) << 24
                 | UInt32(bytes[index + 1]) << 16
                 | UInt32(bytes[index + 2]) << 8
                 | UInt32(bytes[index + 3])
        }

        guard bytes.count > 4 else { return Data() }

        // Skip algorithm string
        let algorithmLength = Int(readUInt32(at: offset))
        offset += 4 + algorithmLength

        // Skip curve identifier
        guard offset + 4 < bytes.count else { return Data() }
        let curveLength = Int(readUInt32(at: offset))
        offset += 4 + curveLength

        // Read EC point
        guard offset + 4 < bytes.count else { return Data() }
        let pointLength = Int(readUInt32(at: offset))
        offset += 4

        guard offset + pointLength <= bytes.count else { return Data() }
        return Data(bytes[offset..<offset+pointLength])
    }

    private static func buildPublicKeyBlob(publicKeyPoint: Data, application: String) -> Data {
        var buffer = Data()

        // Algorithm string
        let algo = "sk-ecdsa-sha2-nistp256@openssh.com"
        var algoLength = UInt32(algo.utf8.count).bigEndian
        buffer.append(Data(bytes: &algoLength, count: 4))
        buffer.append(algo.data(using: .utf8)!)

        // Curve identifier
        let curve = "nistp256"
        var curveLength = UInt32(curve.utf8.count).bigEndian
        buffer.append(Data(bytes: &curveLength, count: 4))
        buffer.append(curve.data(using: .utf8)!)

        // EC point
        var pointLength = UInt32(publicKeyPoint.count).bigEndian
        buffer.append(Data(bytes: &pointLength, count: 4))
        buffer.append(publicKeyPoint)

        // Application
        let appData = application.data(using: .utf8) ?? Data()
        var appLength = UInt32(appData.count).bigEndian
        buffer.append(Data(bytes: &appLength, count: 4))
        buffer.append(appData)

        return buffer
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKeyBlob)
    }

    public static func == (lhs: AppleFIDO2ECDSASKP256PublicKey, rhs: AppleFIDO2ECDSASKP256PublicKey) -> Bool {
        lhs.publicKeyBlob == rhs.publicKeyBlob
    }
}

// MARK: - WebAuthn ECDSA-SK P-256 Signature for Apple FIDO2

/// WebAuthn ECDSA P-256 SK signature format for Apple FIDO2
/// Uses webauthn-sk-ecdsa-sha2-nistp256@openssh.com format which includes clientData
struct AppleFIDO2ECDSASKP256Signature: NIOSSHSignatureProtocol, Hashable, Sendable {
    // WebAuthn-specific signature type that includes clientData
    static var signaturePrefix: String { "webauthn-sk-ecdsa-sha2-nistp256@openssh.com" }

    private let flags: UInt8
    private let counter: UInt32
    private let signatureData: Data  // ECDSA signature in SSH mpint format (r || s)
    private let origin: String       // Origin from clientDataJSON
    private let clientDataJSON: Data // Raw clientDataJSON from WebAuthn
    private let extensions: Data     // WebAuthn extensions (empty for now)

    var rawRepresentation: Data {
        var data = Data()
        data.append(flags)
        var counterBE = counter.bigEndian
        data.append(Data(bytes: &counterBE, count: 4))
        data.append(signatureData)
        return data
    }

    init(flags: UInt8, counter: UInt32, signatureData: Data, origin: String, clientDataJSON: Data) {
        self.flags = flags
        self.counter = counter
        self.signatureData = signatureData
        self.origin = origin
        self.clientDataJSON = clientDataJSON
        self.extensions = Data()  // No extensions for now
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = 0

        // WebAuthn SK signature format per PROTOCOL.u2f:
        // string    ecdsa_signature
        // byte      flags
        // uint32    counter
        // string    origin
        // string    clientData
        // string    extensions

        // Write the ECDSA inner signature blob
        written += buffer.writeInteger(UInt32(signatureData.count))
        written += buffer.writeBytes(signatureData)

        // Write flags (1 byte)
        written += buffer.writeInteger(flags)

        // Write counter (4 bytes, big-endian)
        written += buffer.writeInteger(counter)

        // Write origin string
        let originData = origin.data(using: .utf8) ?? Data()
        written += buffer.writeInteger(UInt32(originData.count))
        written += buffer.writeBytes(originData)

        // Write clientData (raw JSON bytes)
        written += buffer.writeInteger(UInt32(clientDataJSON.count))
        written += buffer.writeBytes(clientDataJSON)

        // Write extensions (empty string for now)
        written += buffer.writeInteger(UInt32(extensions.count))
        written += buffer.writeBytes(extensions)

        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> AppleFIDO2ECDSASKP256Signature {
        guard let sigLength = buffer.readInteger(as: UInt32.self),
              let sigData = buffer.readBytes(length: Int(sigLength)),
              let flags = buffer.readInteger(as: UInt8.self),
              let counter = buffer.readInteger(as: UInt32.self),
              let originLength = buffer.readInteger(as: UInt32.self),
              let originData = buffer.readBytes(length: Int(originLength)),
              let clientDataLength = buffer.readInteger(as: UInt32.self),
              let clientData = buffer.readBytes(length: Int(clientDataLength)),
              let extLength = buffer.readInteger(as: UInt32.self),
              let _ = buffer.readBytes(length: Int(extLength)) else {
            throw AppleFIDO2Error.assertionFailed(
                String(
                    localized: "Failed to read the WebAuthn SK signature.",
                    comment: "WebAuthn SSH signature parsing error detail"
                )
            )
        }

        return AppleFIDO2ECDSASKP256Signature(
            flags: flags,
            counter: counter,
            signatureData: Data(sigData),
            origin: String(data: Data(originData), encoding: .utf8) ?? "",
            clientDataJSON: Data(clientData)
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(flags)
        hasher.combine(counter)
        hasher.combine(signatureData)
        hasher.combine(origin)
        hasher.combine(clientDataJSON)
    }

    static func == (lhs: AppleFIDO2ECDSASKP256Signature, rhs: AppleFIDO2ECDSASKP256Signature) -> Bool {
        lhs.flags == rhs.flags && lhs.counter == rhs.counter && lhs.signatureData == rhs.signatureData &&
        lhs.origin == rhs.origin && lhs.clientDataJSON == rhs.clientDataJSON
    }
}

// MARK: - ECDSA-SK P-256 Private Key for Apple FIDO2

/// ECDSA P-256 SK private key wrapper that routes signing through AppleFIDO2Signer
final class AppleFIDO2ECDSASKP256PrivateKey: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { "sk-ecdsa-sha2-nistp256@openssh.com" }

    private let reference: AppleFIDO2Reference
    private let cachedPublicKey: AppleFIDO2ECDSASKP256PublicKey
    private static let signingTimeout: TimeInterval = 60.0

    init(reference: AppleFIDO2Reference) {
        self.reference = reference
        self.cachedPublicKey = AppleFIDO2ECDSASKP256PublicKey(reference: reference)
        appleFIDO2NIOSSHLogger.info("Created AppleFIDO2ECDSASKP256PrivateKey for key: \(reference.keyID)")
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        appleFIDO2NIOSSHLogger.info("ECDSA-SK P-256 signature requested for key \(self.reference.keyID)")

        let (flags, counter, sigData, origin, clientDataJSON) = try performAppleFIDO2Signing(
            data: data,
            reference: reference,
            timeout: Self.signingTimeout
        )

        return AppleFIDO2ECDSASKP256Signature(
            flags: flags,
            counter: counter,
            signatureData: sigData,
            origin: origin,
            clientDataJSON: clientDataJSON
        )
    }
}

// MARK: - Shared Apple FIDO2 Signing Logic

/// Performs the actual FIDO2 signing operation via Apple AuthenticationServices
/// Bridges async signing to synchronous NIOSSH interface using semaphore
private func performAppleFIDO2Signing<D: DataProtocol>(
    data: D,
    reference: AppleFIDO2Reference,
    timeout: TimeInterval
) throws -> (flags: UInt8, counter: UInt32, signature: Data, origin: String, clientDataJSON: Data) {
    let semaphore = DispatchSemaphore(value: 0)
    var signingResult: Result<(UInt8, UInt32, Data, String, Data), Error>?

    Task.detached(priority: .high) {
        do {
            let dataArray = Array(data)
            let sessionData = Data(dataArray)

            appleFIDO2NIOSSHLogger.info("Apple FIDO2 signing with credential: \(reference.credentialID.prefix(16).base64EncodedString())...")

            // `AppleFIDO2Signer` is `@MainActor` (it owns the
            // ASAuthorizationController presentation), so calls into
            // it auto-hop to main. Previously this routed through
            // `MainActor.run { Task { … } }` which added an extra
            // wrapping Task that was awaited synchronously — same
            // outcome but two extra context flips per signature.
            let signer = await AppleFIDO2Signer()
            let signResult = try await signer.signSSHData(
                credentialID: reference.credentialID,
                backing: reference.backing,
                sessionData: sessionData
            )

            appleFIDO2NIOSSHLogger.info("Got signature: flags=0x\(String(format: "%02x", signResult.flags)), counter=\(signResult.counter), origin=\(signResult.origin)")

            signingResult = .success((signResult.flags, signResult.counter, signResult.sshSignatureData,
                                      signResult.origin, signResult.clientDataJSON))
        } catch {
            appleFIDO2NIOSSHLogger.error("Apple FIDO2 signing failed: \(error)")
            signingResult = .failure(error)
        }
        semaphore.signal()
    }

    let timeoutResult = semaphore.wait(timeout: .now() + timeout)

    guard timeoutResult == .success else {
        appleFIDO2NIOSSHLogger.error("Apple FIDO2 signing timed out after \(timeout) seconds")
        throw AppleFIDO2Error.assertionFailed(
            String(
                localized: "Signing timed out.",
                comment: "WebAuthn SSH signing error detail"
            )
        )
    }

    guard let result = signingResult else {
        throw AppleFIDO2Error.assertionFailed(
            String(
                localized: "The signing operation returned no result.",
                comment: "WebAuthn SSH signing error detail"
            )
        )
    }

    switch result {
    case .success(let components):
        return components
    case .failure(let error):
        throw error
    }
}

// MARK: - Factory Function

/// Creates an Apple FIDO2 NIOSSH private key implementation
/// - Parameter reference: The Apple FIDO2 reference containing credential metadata
/// - Returns: An ECDSA P-256 SK private key wrapper
func createAppleFIDO2PrivateKey(reference: AppleFIDO2Reference) -> any NIOSSHPrivateKeyProtocol {
    appleFIDO2NIOSSHLogger.info("Creating Apple FIDO2 private key for credential: \(reference.credentialID.prefix(16).base64EncodedString())...")
    return AppleFIDO2ECDSASKP256PrivateKey(reference: reference)
}

// MARK: - Algorithm Registration

/// Register Apple FIDO2 SK algorithm types with NIOSSH
/// Call this during app initialization before using Apple FIDO2 authentication
func registerAppleFIDO2Algorithms() {
    NIOSSHAlgorithms.register(
        publicKey: AppleFIDO2ECDSASKP256PublicKey.self,
        signature: AppleFIDO2ECDSASKP256Signature.self
    )

    appleFIDO2NIOSSHLogger.info("Registered Apple FIDO2 SK algorithms with NIOSSH")
}
