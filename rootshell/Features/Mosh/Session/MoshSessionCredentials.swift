//
//  MoshSessionCredentials.swift
//  rootshell
//
//  Mosh session credentials for persistence and resume
//

import Foundation

/// Credentials for resuming a Mosh session after app relaunch
///
/// Contains the session key, UDP port, and host information needed to
/// reconnect directly to an existing mosh-server without spawning a new one.
///
/// Also includes sequence/state numbers required for proper protocol resume:
/// - Crypto layer needs sequence numbers to avoid nonce reuse (OCB security)
/// - State sync layer needs state numbers for diff-based synchronization
struct MoshSessionCredentials: Codable, Sendable {
    /// The 22-character base64 session key
    let sessionKeyBase64: String

    /// The UDP port mosh-server is listening on
    let udpPort: Int

    /// The host IP/hostname to connect to
    let host: String

    /// When the session was created
    let createdAt: Date

    /// The terminal UUID this session belongs to
    let terminalId: UUID

    /// Display name for logging (e.g., "user@host")
    let displayName: String

    // MARK: - Protocol State (for resume)

    /// Next outgoing sequence number for crypto nonce (prevents nonce reuse)
    /// This MUST continue from where the previous session left off.
    var outgoingSequence: UInt64

    /// Last received incoming sequence number (for validation)
    var lastIncomingSequence: UInt64

    /// Our last sent state number (for state sync layer)
    var sentStateNum: UInt64

    /// What we assume the server has acknowledged (for oldNum in instructions)
    var assumedReceiverStateNum: UInt64

    /// Last state number we received from server
    var lastReceivedStateNum: UInt64

    /// When state was last updated (for debugging)
    var stateUpdatedAt: Date

    // MARK: - Bootstrap SSH Crypto (captured before SSH closes)

    /// SSH key exchange algorithm negotiated during bootstrap
    var bootstrapKeyExchange: String?

    /// SSH host key algorithm negotiated during bootstrap
    var bootstrapHostKey: String?

    /// SSH cipher algorithm negotiated during bootstrap
    var bootstrapCipher: String?

    /// SSH MAC algorithm negotiated during bootstrap
    var bootstrapMac: String?

    // MARK: - TTL Configuration

    /// Maximum age of credentials before expiration (72 hours)
    static let maxAge: TimeInterval = 259200  // 72 hours

    /// Whether the credentials have expired
    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.maxAge
    }

    /// Human-readable age of the credentials
    var age: String {
        let interval = Date().timeIntervalSince(createdAt)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }

    // MARK: - Initialization

    /// Creates credentials from spawn result (for new sessions)
    /// - Parameters:
    ///   - key: The session key from mosh-server
    ///   - port: The UDP port
    ///   - host: The host to connect to
    ///   - terminalId: The terminal UUID
    ///   - displayName: Display name for logging
    init(
        key: MoshBase64Key,
        port: Int,
        host: String,
        terminalId: UUID,
        displayName: String,
        bootstrapKeyExchange: String? = nil,
        bootstrapHostKey: String? = nil,
        bootstrapCipher: String? = nil,
        bootstrapMac: String? = nil
    ) {
        self.sessionKeyBase64 = key.base64String
        self.udpPort = port
        self.host = host
        self.createdAt = Date()
        self.terminalId = terminalId
        self.displayName = displayName
        // Initial state for new sessions
        self.outgoingSequence = 0
        self.lastIncomingSequence = 0
        self.sentStateNum = 0
        self.assumedReceiverStateNum = 0
        self.lastReceivedStateNum = 0
        self.stateUpdatedAt = Date()
        self.bootstrapKeyExchange = bootstrapKeyExchange
        self.bootstrapHostKey = bootstrapHostKey
        self.bootstrapCipher = bootstrapCipher
        self.bootstrapMac = bootstrapMac
    }

    /// Creates credentials with full state (for resume updates)
    /// - Note: Pass nil for createdAt to use current date (new session),
    ///         or pass existing date to preserve TTL tracking (state update)
    init(
        key: MoshBase64Key,
        port: Int,
        host: String,
        terminalId: UUID,
        displayName: String,
        outgoingSequence: UInt64,
        lastIncomingSequence: UInt64,
        sentStateNum: UInt64,
        assumedReceiverStateNum: UInt64,
        lastReceivedStateNum: UInt64,
        createdAt: Date? = nil,
        bootstrapKeyExchange: String? = nil,
        bootstrapHostKey: String? = nil,
        bootstrapCipher: String? = nil,
        bootstrapMac: String? = nil
    ) {
        self.sessionKeyBase64 = key.base64String
        self.udpPort = port
        self.host = host
        self.createdAt = createdAt ?? Date()
        self.terminalId = terminalId
        self.displayName = displayName
        self.outgoingSequence = outgoingSequence
        self.lastIncomingSequence = lastIncomingSequence
        self.sentStateNum = sentStateNum
        self.assumedReceiverStateNum = assumedReceiverStateNum
        self.lastReceivedStateNum = lastReceivedStateNum
        self.stateUpdatedAt = Date()
        self.bootstrapKeyExchange = bootstrapKeyExchange
        self.bootstrapHostKey = bootstrapHostKey
        self.bootstrapCipher = bootstrapCipher
        self.bootstrapMac = bootstrapMac
    }

    // MARK: - Key Conversion

    /// Converts the stored base64 string back to a MoshBase64Key
    /// - Throws: MoshError.invalidSessionKey if the stored key is invalid
    func toKey() throws -> MoshBase64Key {
        try MoshBase64Key(base64String: sessionKeyBase64)
    }
}

// MARK: - CustomStringConvertible

extension MoshSessionCredentials: CustomStringConvertible {
    var description: String {
        let keyPrefix = String(sessionKeyBase64.prefix(4))
        return "MoshCredentials(\(displayName), port=\(udpPort), key=\(keyPrefix)..., age=\(age), seq=\(outgoingSequence), state=\(sentStateNum))"
    }
}
