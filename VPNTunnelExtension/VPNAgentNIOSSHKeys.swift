//
//  VPNAgentNIOSSHKeys.swift
//  VPNTunnelExtension (macOS sysext only)
//
//  Agent-backed NIOSSH keys for the packet tunnel. Reuses the shared
//  generic wrappers from ExternalAgentNIOSSHKeys.swift; only the signer
//  differs — the sysext can't reach the user's agent socket, so signatures
//  are brokered through the host via VPNAgentSignBroker.
//

#if os(macOS)

import Foundation
import NIOSSH

/// Signs by parking the request on the broker until the host's poll loop
/// picks it up, signs against the agent socket, and submits the result.
nonisolated struct VPNBrokeredAgentSigner: ExternalAgentSignatureProvider {
    let socketPath: String

    func signBlob(keyBlob: Data, data: Data, flags: UInt32) throws -> Data {
        try VPNAgentSignBroker.shared.sign(
            socketPath: socketPath,
            keyBlob: keyBlob,
            data: data,
            flags: flags
        )
    }
}

/// Sysext factory for an agent-backed key from a resolved `.agentKey`
/// credential.
nonisolated func createVPNAgentKey(
    publicKeyBlob: Data,
    algorithm: String,
    socketPath: String
) throws -> any NIOSSHPrivateKeyProtocol {
    try makeExternalAgentPrivateKey(
        publicKeyBlob: publicKeyBlob,
        algorithm: algorithm,
        signer: VPNBrokeredAgentSigner(socketPath: socketPath)
    )
}

#endif
