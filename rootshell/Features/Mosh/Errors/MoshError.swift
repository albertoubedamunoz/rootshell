//
//  MoshError.swift
//  rootshell
//
//  Error types for Mosh protocol operations
//

import Foundation

/// Errors that can occur during Mosh protocol operations
enum MoshError: LocalizedError, Equatable, Sendable {

    // MARK: - Connection Errors

    /// Failed to spawn mosh-server via SSH
    case serverSpawnFailed(reason: String)

    /// mosh-server binary not found on remote host
    case moshServerNotFound

    /// Could not parse mosh-server response (expected "MOSH CONNECT <port> <key>")
    case invalidServerResponse(received: String)

    /// UDP connection to mosh-server failed
    case udpConnectionFailed(host: String, port: Int, reason: String)

    /// Network path became unavailable
    case networkUnavailable

    /// Connection timed out waiting for response
    case connectionTimeout

    /// UDP hole-punch failed (firewall traversal)
    case holePunchFailed(reason: String)

    // MARK: - Authentication/Crypto Errors

    /// Failed to parse session key from server
    case invalidSessionKey(reason: String)

    /// Decryption failed (bad MAC, corrupted data)
    case decryptionFailed(reason: String)

    /// Encryption failed
    case encryptionFailed(reason: String)

    /// Nonce sequence error (replay attack or out-of-order)
    case nonceSequenceError(expected: UInt64, received: UInt64)

    // MARK: - Protocol Errors

    /// Received packet with invalid format
    case invalidPacketFormat(reason: String)

    /// Protocol version mismatch
    case protocolVersionMismatch(expected: Int, received: Int)

    /// Failed to deserialize protobuf message
    case protobufDeserializationFailed(messageType: String, reason: String)

    /// Failed to serialize protobuf message
    case protobufSerializationFailed(messageType: String, reason: String)

    /// Compression/decompression error
    case compressionError(reason: String)

    /// Fragment reassembly failed
    case fragmentReassemblyFailed(reason: String)

    /// Payload exceeds maximum fragmentable size
    case payloadTooLarge(size: Int, maxSize: Int)

    // MARK: - State Sync Errors

    /// State number is out of sync
    case stateSyncFailed(reason: String)

    /// Received unexpected message in current state
    case unexpectedMessage(expected: String, received: String)

    /// Unrecoverable state desync after resume - requires fresh session
    /// This happens when the server has discarded states we need, typically
    /// because the client was suspended for too long without saving state.
    case stateDesync(reason: String)

    // MARK: - Transport Errors

    /// Failed to send UDP packet
    case sendFailed(reason: String)

    /// Receive error
    case receiveFailed(reason: String)

    /// Connection was reset
    case connectionReset

    // MARK: - Session Errors

    /// Session already started
    case sessionAlreadyStarted

    /// Session not started
    case sessionNotStarted

    /// Session was terminated
    case sessionTerminated(reason: String)

    /// SSH connection failed during server spawn
    case sshConnectionFailed(reason: String)

    // MARK: - LocalizedError Conformance

    var errorDescription: String? {
        switch self {
        case .serverSpawnFailed(let reason):
            return "Roam server refused to wake up: \(reason)"
        case .moshServerNotFound:
            return "mosh-server not installed. Install it on the remote host to use Roam."
        case .invalidServerResponse(let received):
            return "Roam server spoke in tongues: \(received)"
        case .udpConnectionFailed(let host, let port, let reason):
            return "Failed to connect UDP to \(host):\(port): \(reason)"
        case .networkUnavailable:
            return "Network unavailable"
        case .connectionTimeout:
            return "Connection timed out"
        case .holePunchFailed(let reason):
            return "Firewall traversal failed: \(reason)"
        case .invalidSessionKey(let reason):
            return "Invalid session key: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .nonceSequenceError(let expected, let received):
            return "Nonce sequence error: expected \(expected), received \(received)"
        case .invalidPacketFormat(let reason):
            return "Invalid packet format: \(reason)"
        case .protocolVersionMismatch(let expected, let received):
            return "Protocol version mismatch: expected \(expected), received \(received)"
        case .protobufDeserializationFailed(let messageType, let reason):
            return "Failed to deserialize \(messageType): \(reason)"
        case .protobufSerializationFailed(let messageType, let reason):
            return "Failed to serialize \(messageType): \(reason)"
        case .compressionError(let reason):
            return "Compression error: \(reason)"
        case .fragmentReassemblyFailed(let reason):
            return "Fragment reassembly failed: \(reason)"
        case .payloadTooLarge(let size, let maxSize):
            return "Payload too large: \(size) bytes exceeds maximum of \(maxSize) bytes"
        case .stateSyncFailed(let reason):
            return "State synchronization failed: \(reason)"
        case .unexpectedMessage(let expected, let received):
            return "Unexpected message: expected \(expected), received \(received)"
        case .stateDesync(let reason):
            return "State desync after resume: \(reason)"
        case .sendFailed(let reason):
            return "Failed to send: \(reason)"
        case .receiveFailed(let reason):
            return "Failed to receive: \(reason)"
        case .connectionReset:
            return "Connection was reset"
        case .sessionAlreadyStarted:
            return "Session already started"
        case .sessionNotStarted:
            return "Session not started"
        case .sessionTerminated(let reason):
            return "Session terminated: \(reason)"
        case .sshConnectionFailed(let reason):
            return "SSH connection failed: \(reason)"
        }
    }

    // MARK: - Error Classification

    /// Whether this error is recoverable (can retry)
    var isRecoverable: Bool {
        switch self {
        case .networkUnavailable, .connectionTimeout, .sendFailed, .receiveFailed:
            return true
        case .udpConnectionFailed, .holePunchFailed:
            return true  // Network path may change
        case .nonceSequenceError, .invalidPacketFormat, .compressionError, .fragmentReassemblyFailed:
            return true
        default:
            return false
        }
    }

    /// Whether this error indicates an authentication problem
    var isAuthenticationRelated: Bool {
        switch self {
        case .invalidSessionKey, .decryptionFailed, .nonceSequenceError:
            return true
        case .sshConnectionFailed(let reason):
            return reason.lowercased().contains("auth")
        default:
            return false
        }
    }

    /// Whether this error indicates a protocol/version incompatibility
    var isProtocolError: Bool {
        switch self {
        case .protocolVersionMismatch, .invalidPacketFormat, .protobufDeserializationFailed,
             .protobufSerializationFailed, .invalidServerResponse:
            return true
        default:
            return false
        }
    }

    /// Whether this error requires starting a fresh session (new SSH spawn)
    /// These errors cannot be recovered by simple retry - the session state is corrupted
    var requiresFreshSession: Bool {
        switch self {
        case .stateDesync:
            return true
        default:
            return false
        }
    }

    /// Whether this error indicates mosh-server is not installed on the remote host
    var isMoshServerNotInstalled: Bool {
        switch self {
        case .moshServerNotFound:
            return true
        default:
            return false
        }
    }
}
