#if !targetEnvironment(macCatalyst)

import Foundation

/// Errors that can occur during a croc transfer.
nonisolated enum CrocError: LocalizedError {
    // MARK: - Connection
    case connectionFailed(String)
    case connectionTimeout
    case relayFull
    case relayAuthFailed
    case badPassword

    // MARK: - PAKE / Crypto
    case pakeInitFailed(String)
    case pakeExchangeFailed(String)
    case channelNotSecured
    case decryptionFailed
    case encryptionFailed
    case invalidKey

    // MARK: - Transfer
    case transferCancelled
    case transferFailed(String)
    case hashMismatch(filename: String)
    case fileTooLarge(needed: Int64, available: Int64)
    case fileNotFound(String)
    case invalidFilename(String)
    case pathTraversalDetected(String)
    case filesRejected

    // MARK: - Protocol
    case invalidMagic
    case messageTooLarge(Int)
    case invalidMessage(String)
    case unexpectedMessageType(String)
    case protocolError(String)
    case sameRole

    // MARK: - Peer
    case peerDisconnected
    case peerError(String)

    // MARK: - System
    case cancelled
    case ioError(String)
    case compressionFailed
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let host):
            return "Failed to connect to \(host)"
        case .connectionTimeout:
            return "Connection timed out"
        case .relayFull:
            return "Relay room is full"
        case .relayAuthFailed:
            return "Relay authentication failed"
        case .badPassword:
            return "Bad relay password"
        case .pakeInitFailed(let reason):
            return "PAKE initialization failed: \(reason)"
        case .pakeExchangeFailed(let reason):
            return "PAKE exchange failed: \(reason)"
        case .channelNotSecured:
            return "Could not secure channel"
        case .decryptionFailed:
            return "Decryption failed — incorrect passphrase"
        case .encryptionFailed:
            return "Encryption failed"
        case .invalidKey:
            return "Invalid encryption key"
        case .transferCancelled:
            return "Transfer cancelled"
        case .transferFailed(let reason):
            return "Transfer failed: \(reason)"
        case .hashMismatch(let filename):
            return "Hash mismatch for '\(filename)' — file may be corrupted"
        case .fileTooLarge(let needed, let available):
            return "Not enough disk space (need \(CrocUtils.byteCountDecimal(needed)), have \(CrocUtils.byteCountDecimal(available)))"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidFilename(let name):
            return "Invalid filename: \(name)"
        case .pathTraversalDetected(let path):
            return "Path traversal detected: \(path)"
        case .filesRejected:
            return "Transfer rejected by recipient"
        case .invalidMagic:
            return "Invalid message magic bytes"
        case .messageTooLarge(let size):
            return "Message too large: \(size) bytes"
        case .invalidMessage(let reason):
            return "Invalid message: \(reason)"
        case .unexpectedMessageType(let type):
            return "Unexpected message type: \(type)"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        case .sameRole:
            return "Both sides have the same role"
        case .peerDisconnected:
            return "Peer disconnected"
        case .peerError(let message):
            return "Peer error: \(message)"
        case .cancelled:
            return "Operation cancelled"
        case .ioError(let reason):
            return "I/O error: \(reason)"
        case .compressionFailed:
            return "Compression failed"
        case .decompressionFailed:
            return "Decompression failed"
        }
    }

    /// Whether this error is related to authentication/PAKE.
    var isAuthenticationRelated: Bool {
        switch self {
        case .pakeInitFailed, .pakeExchangeFailed, .channelNotSecured,
             .decryptionFailed, .badPassword, .relayAuthFailed:
            return true
        default:
            return false
        }
    }

    /// Whether this error indicates the user cancelled.
    var isCancellation: Bool {
        switch self {
        case .cancelled, .transferCancelled:
            return true
        default:
            return false
        }
    }
}

/// Utility namespace for croc helper functions used in error messages.
nonisolated enum CrocUtils {
    static func byteCountDecimal(_ bytes: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1000 && unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

#endif
