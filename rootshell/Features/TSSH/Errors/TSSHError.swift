//
//  TSSHError.swift
//  rootshell
//
//  Error types for trzsz-ssh sessions
//

import Foundation

/// Errors that can occur during trzsz-ssh sessions
enum TrzszError: LocalizedError, Sendable {
    /// Session was already started
    case sessionAlreadyStarted

    /// tsshd binary not found on the server
    case tsshNotFound

    /// Failed to parse tsshd JSON output
    case invalidServerInfo(reason: String)

    /// SSH connection failed
    case sshConnectionFailed(reason: String)

    /// Failed to spawn tsshd server
    case serverSpawnFailed(reason: String)

    /// QUIC connection failed
    case quicConnectionFailed(reason: String)

    /// KCP connection failed
    case kcpConnectionFailed(reason: String)

    /// KCP encryption/decryption failed
    case kcpCryptoFailed(reason: String)

    /// Invalid certificate data from server
    case invalidCertificate(reason: String)

    /// Session key/credential mismatch during resume
    case credentialMismatch(reason: String)

    /// Session expired
    case sessionExpired

    /// Transport disconnected unexpectedly
    case transportDisconnected(reason: String)

    /// Authentication failed during proxy reconnection
    case proxyAuthenticationFailed

    /// Proxy transport error
    case proxyError(reason: String)

    /// Resume failed, need fresh session
    case resumeFallback(reason: String)

    /// Generic connection failed
    case connectionFailed(_ reason: String)

    /// Authentication failed
    case authenticationFailed(_ reason: String)

    // MARK: - LocalizedError

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyStarted:
            return "Session already started"
        case .tsshNotFound:
            return "tsshd not found on server. See install instructions at https://github.com/trzsz/tsshd"
        case .invalidServerInfo(let reason):
            return "Invalid server info: \(reason)"
        case .sshConnectionFailed(let reason):
            return "SSH connection failed: \(reason)"
        case .serverSpawnFailed(let reason):
            return "Failed to start tsshd: \(reason)"
        case .quicConnectionFailed(let reason):
            return "QUIC connection failed: \(reason)"
        case .kcpConnectionFailed(let reason):
            return "KCP connection failed: \(reason)"
        case .kcpCryptoFailed(let reason):
            return "KCP encryption error: \(reason)"
        case .invalidCertificate(let reason):
            return "Invalid certificate: \(reason)"
        case .credentialMismatch(let reason):
            return "Session credential mismatch: \(reason)"
        case .sessionExpired:
            return "Session expired"
        case .transportDisconnected(let reason):
            return "Connection lost: \(reason)"
        case .proxyAuthenticationFailed:
            return "Session authentication failed during reconnection"
        case .proxyError(let reason):
            return "Proxy error: \(reason)"
        case .resumeFallback(let reason):
            return "Resume failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason)"
        }
    }

    // MARK: - Error Classification

    /// Whether the error is recoverable through reconnection
    var isRecoverable: Bool {
        switch self {
        case .transportDisconnected, .resumeFallback:
            return true
        default:
            return false
        }
    }

    /// Whether the error requires a fresh SSH spawn (not just UDP reconnect)
    var requiresFreshSession: Bool {
        switch self {
        case .sessionExpired, .credentialMismatch, .proxyAuthenticationFailed:
            return true
        default:
            return false
        }
    }

    /// Whether the error is related to authentication
    var isAuthenticationRelated: Bool {
        switch self {
        case .sshConnectionFailed(let reason):
            return reason.lowercased().contains("auth")
        case .proxyAuthenticationFailed, .authenticationFailed:
            return true
        default:
            return false
        }
    }
}
