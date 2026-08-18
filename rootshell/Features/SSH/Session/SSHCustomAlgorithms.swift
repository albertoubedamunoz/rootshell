//
//  SSHCustomAlgorithms.swift
//  rootshell
//
//  Centralized registration of custom NIOSSH key algorithms.
//

import Foundation
import Crypto
import Citadel
import NIOSSH

/// Registers every custom public-key algorithm the app can parse (RSA,
/// ML-DSA hybrid + pure, Apple FIDO2). NIOSSH registration is global,
/// idempotent, and lock-protected; call from any path that parses keys,
/// certificates, or CA lines — those can all run before the first SSH
/// connection performs its own registration. MainActor (project default)
/// because `registerAppleFIDO2Algorithms()` is; all current callers are
/// MainActor-isolated managers and parsers.
enum SSHCustomAlgorithms {
    static func ensureRegistered() {
        // RSA (Citadel custom key) — normally registered by SSHClient.connect.
        NIOSSHAlgorithms.register(publicKey: Insecure.RSA.PublicKey.self, signature: Insecure.RSA.Signature.self)
        // ML-DSA hybrid (has a cert form) + pure.
        NIOSSHAlgorithms.registerPreferred(publicKey: MLDSA44Ed25519SSH.PublicKey.self, signature: MLDSA44Ed25519SSH.Signature.self)
        NIOSSHAlgorithms.registerPreferred(publicKey: MLDSA44SSH.PublicKey.self, signature: MLDSA44SSH.Signature.self)
        if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) {
            NIOSSHAlgorithms.registerPreferred(publicKey: MLDSA65SSH.PublicKey.self, signature: MLDSA65SSH.Signature.self)
            NIOSSHAlgorithms.registerPreferred(publicKey: MLDSA87SSH.PublicKey.self, signature: MLDSA87SSH.Signature.self)
        }
        // sk-ecdsa (Apple FIDO2 / security keys via AuthenticationServices).
        registerAppleFIDO2Algorithms()
    }
}
