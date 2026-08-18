//
//  ExternalAgentNIOSSHKeys.swift
//  rootshell
//
//  NIOSSH custom-key wrappers whose signatures are produced by an external
//  OpenSSH agent. NIOSSH's signing hook is synchronous (it runs on the SSH
//  event loop while building the userauth request), and the agent client is
//  blocking socket I/O, so signing calls straight through — same event-loop
//  blocking contract as the YubiKey semaphore bridge.
//
//  NIOSSH requires static algorithm prefixes, so types are generic over a
//  per-algorithm spec instead of hand-copied per family. The actual signer
//  is injected: the app signs against the agent socket directly, the VPN
//  system extension signs via the host broker.
//

#if (targetEnvironment(macCatalyst) && STANDALONE) || os(macOS)

import Foundation
import NIOSSH
import NIOCore
import os.log

nonisolated private let agentNIOSSHLogger = Logger(
    subsystem: "com.rootshell",
    category: "ExternalAgentNIOSSH"
)

/// Produces raw SSH signature blobs (`string algorithm, string signature`)
/// for a public key held by an external agent.
nonisolated protocol ExternalAgentSignatureProvider: Sendable {
    func signBlob(keyBlob: Data, data: Data, flags: UInt32) throws -> Data
}

/// Static algorithm names for one key family. `signFlags` is what goes into
/// the agent SIGN_REQUEST (RSA asks for SHA-256 so the returned algorithm
/// matches `signatureName`).
nonisolated protocol ExternalAgentAlgorithmSpec: Sendable {
    static var keyName: String { get }
    static var signatureName: String { get }
    static var signFlags: UInt32 { get }
}

nonisolated enum AgentEd25519Spec: ExternalAgentAlgorithmSpec {
    static var keyName: String { "ssh-ed25519" }
    static var signatureName: String { "ssh-ed25519" }
    static var signFlags: UInt32 { 0 }
}

nonisolated enum AgentECDSAP256Spec: ExternalAgentAlgorithmSpec {
    static var keyName: String { "ecdsa-sha2-nistp256" }
    static var signatureName: String { "ecdsa-sha2-nistp256" }
    static var signFlags: UInt32 { 0 }
}

nonisolated enum AgentECDSAP384Spec: ExternalAgentAlgorithmSpec {
    static var keyName: String { "ecdsa-sha2-nistp384" }
    static var signatureName: String { "ecdsa-sha2-nistp384" }
    static var signFlags: UInt32 { 0 }
}

nonisolated enum AgentECDSAP521Spec: ExternalAgentAlgorithmSpec {
    static var keyName: String { "ecdsa-sha2-nistp521" }
    static var signatureName: String { "ecdsa-sha2-nistp521" }
    static var signFlags: UInt32 { 0 }
}

nonisolated enum AgentRSASpec: ExternalAgentAlgorithmSpec {
    static var keyName: String { "ssh-rsa" }
    static var signatureName: String { "rsa-sha2-256" }
    // SSH_AGENT_RSA_SHA2_256
    static var signFlags: UInt32 { 2 }
}

// MARK: - Public key

nonisolated struct ExternalAgentPublicKey<Spec: ExternalAgentAlgorithmSpec>: NIOSSHPublicKeyProtocol, Hashable, Sendable {
    static var publicKeyPrefix: String { Spec.keyName }
    /// The algorithm advertised in the userauth request must match the
    /// signature the agent produces: for RSA that is rsa-sha2-256, not the
    /// default ssh-rsa (which modern servers reject as SHA-1). Identical to
    /// the key name for every other family.
    static var authAlgorithmName: String { Spec.signatureName }

    let publicKeyBlob: Data
    /// Blob minus the leading algorithm string — already in canonical SSH
    /// wire layout for every family (Ed25519: string key; ECDSA: string
    /// curve + string point; RSA: mpint e + mpint n), so it is re-emitted
    /// verbatim.
    private let keyData: Data

    init(publicKeyBlob: Data) {
        self.publicKeyBlob = publicKeyBlob
        var reader = SSHAgentReader(publicKeyBlob)
        _ = reader.readStringData()
        self.keyData = reader.readRemaining()
    }

    var rawRepresentation: Data { keyData }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false  // Server verifies signatures
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeBytes(keyData)
        return keyData.count
    }

    static func read(from buffer: inout ByteBuffer) throws -> ExternalAgentPublicKey<Spec> {
        throw ExternalAgentError.protocolError("Cannot read external-agent public key from wire format")
    }
}

// MARK: - Signature

nonisolated struct ExternalAgentSignature<Spec: ExternalAgentAlgorithmSpec>: NIOSSHSignatureProtocol, Hashable, Sendable {
    static var signaturePrefix: String { Spec.signatureName }

    /// Inner signature payload as returned by the agent (the bytes after the
    /// algorithm string), emitted verbatim.
    let signatureData: Data

    var rawRepresentation: Data { signatureData }

    func write(to buffer: inout ByteBuffer) -> Int {
        var written = buffer.writeInteger(UInt32(signatureData.count))
        written += buffer.writeBytes(signatureData)
        return written
    }

    static func read(from buffer: inout ByteBuffer) throws -> ExternalAgentSignature<Spec> {
        guard let length = buffer.readInteger(as: UInt32.self),
              let bytes = buffer.readBytes(length: Int(length)) else {
            throw ExternalAgentError.protocolError("Failed to read signature data")
        }
        return ExternalAgentSignature<Spec>(signatureData: Data(bytes))
    }
}

// MARK: - Private key

nonisolated final class ExternalAgentPrivateKey<Spec: ExternalAgentAlgorithmSpec>: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { Spec.keyName }
    /// Matches the public key: advertise the signature algorithm (rsa-sha2-256
    /// for RSA), not the key format name.
    static var authAlgorithmName: String { Spec.signatureName }

    private let publicKeyBlob: Data
    private let cachedPublicKey: ExternalAgentPublicKey<Spec>
    private let signer: any ExternalAgentSignatureProvider

    init(publicKeyBlob: Data, signer: any ExternalAgentSignatureProvider) {
        self.publicKeyBlob = publicKeyBlob
        self.cachedPublicKey = ExternalAgentPublicKey<Spec>(publicKeyBlob: publicKeyBlob)
        self.signer = signer
    }

    var publicKey: NIOSSHPublicKeyProtocol { cachedPublicKey }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        agentNIOSSHLogger.info("\(Spec.signatureName, privacy: .public) signature requested from external agent")
        let blob = try signer.signBlob(
            keyBlob: publicKeyBlob,
            data: Data(data),
            flags: Spec.signFlags
        )
        // Agent response blob: string(algorithm) + string(signature).
        var reader = SSHAgentReader(blob)
        guard let algorithm = reader.readString(),
              let rawSignature = reader.readStringData() else {
            throw ExternalAgentError.protocolError("malformed signature blob from agent")
        }
        guard algorithm == Spec.signatureName else {
            throw ExternalAgentError.protocolError(
                "agent signed with \(algorithm), expected \(Spec.signatureName)"
            )
        }
        return ExternalAgentSignature<Spec>(signatureData: rawSignature)
    }
}

// MARK: - Factory

/// Build the right per-algorithm wrapper for an agent identity. Throws for
/// algorithms we don't offer (certificates, sk-*), which the import UI
/// already refuses.
nonisolated func makeExternalAgentPrivateKey(
    publicKeyBlob: Data,
    algorithm: String,
    signer: any ExternalAgentSignatureProvider
) throws -> any NIOSSHPrivateKeyProtocol {
    switch algorithm {
    case AgentEd25519Spec.keyName:
        return ExternalAgentPrivateKey<AgentEd25519Spec>(publicKeyBlob: publicKeyBlob, signer: signer)
    case AgentECDSAP256Spec.keyName:
        return ExternalAgentPrivateKey<AgentECDSAP256Spec>(publicKeyBlob: publicKeyBlob, signer: signer)
    case AgentECDSAP384Spec.keyName:
        return ExternalAgentPrivateKey<AgentECDSAP384Spec>(publicKeyBlob: publicKeyBlob, signer: signer)
    case AgentECDSAP521Spec.keyName:
        return ExternalAgentPrivateKey<AgentECDSAP521Spec>(publicKeyBlob: publicKeyBlob, signer: signer)
    case AgentRSASpec.keyName:
        return ExternalAgentPrivateKey<AgentRSASpec>(publicKeyBlob: publicKeyBlob, signer: signer)
    default:
        throw ExternalAgentError.protocolError("unsupported agent key algorithm \(algorithm)")
    }
}

nonisolated extension ExternalSSHAgentClient: ExternalAgentSignatureProvider {
    func signBlob(keyBlob: Data, data: Data, flags: UInt32) throws -> Data {
        try sign(keyBlob: keyBlob, data: data, flags: flags)
    }
}

#if targetEnvironment(macCatalyst) && STANDALONE
/// App-side factory: signs directly against the agent's unix socket.
nonisolated func createExternalAgentPrivateKey(
    reference: ExternalAgentKeyReference
) throws -> any NIOSSHPrivateKeyProtocol {
    try makeExternalAgentPrivateKey(
        publicKeyBlob: reference.publicKeyBlob,
        algorithm: reference.algorithm,
        signer: ExternalSSHAgentClient(socketPath: reference.socketPath)
    )
}
#endif

#endif
