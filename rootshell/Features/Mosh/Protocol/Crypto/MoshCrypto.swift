//
//  MoshCrypto.swift
//  rootshell
//
//  AES-128-OCB encryption for mosh protocol, via the MoshOCB.c kernel
//  (RFC 7253 on ARMv8 AES / AES-NI).
//

import Foundation

/// Mosh crypto session for encrypting/decrypting packets
///
/// Uses AES-128-OCB (Offset Codebook Mode) with:
/// - 128-bit (16-byte) key
/// - 96-bit (12-byte) nonce
/// - 128-bit (16-byte) authentication tag
///
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshTransport which is @MainActor.
@MainActor
final class MoshCryptoSession {

    /// Nonce generator for outgoing packets
    private let nonceGenerator: MoshNonceGenerator

    /// Expected sequence number for incoming packets
    private var expectedIncomingSequence: UInt64 = 0

    /// Direction of outgoing messages
    private let outgoingDirection: MoshNonce.Direction

    /// Expanded key schedule and OCB tables; nil only if the key was malformed.
    private let cryptor: MoshOCBCryptor?

    // MARK: - Initialization

    /// Creates a new crypto session with the given key
    /// - Parameters:
    ///   - key: The parsed mosh session key
    ///   - isClient: true if this is the client side (sends TO_SERVER)
    init(key: MoshBase64Key, isClient: Bool) {
        self.outgoingDirection = isClient ? .toServer : .toClient
        self.nonceGenerator = MoshNonceGenerator(direction: outgoingDirection)
        self.cryptor = MoshOCBCryptor(key: key.bytes)
    }

    /// Creates a crypto session for resuming with saved state
    /// - Parameters:
    ///   - key: The parsed mosh session key
    ///   - isClient: true if this is the client side (sends TO_SERVER)
    ///   - outgoingSequence: Starting sequence for outgoing packets
    ///   - expectedIncoming: Expected sequence for incoming packets
    init(key: MoshBase64Key, isClient: Bool, outgoingSequence: UInt64, expectedIncoming: UInt64) {
        self.outgoingDirection = isClient ? .toServer : .toClient
        self.nonceGenerator = MoshNonceGenerator(direction: outgoingDirection, startingSequence: outgoingSequence)
        self.expectedIncomingSequence = expectedIncoming
        self.cryptor = MoshOCBCryptor(key: key.bytes)
    }

    // MARK: - Encryption

    /// Encrypts a message for transmission
    /// - Parameter plaintext: The data to encrypt (timestamps + payload)
    /// - Returns: Encrypted packet (8-byte nonce + ciphertext + 16-byte tag)
    /// - Throws: MoshError.encryptionFailed if encryption fails
    func encrypt(_ plaintext: Data) throws -> Data {
        try encrypt(plaintext, withNonce: nonceGenerator.next())
    }

    /// Encrypts a message with specific nonce (for testing/special cases)
    /// - Parameters:
    ///   - plaintext: The data to encrypt
    ///   - nonce: The specific nonce to use
    /// - Returns: Encrypted packet
    func encrypt(_ plaintext: Data, withNonce nonce: MoshNonce) throws -> Data {
        guard let cryptor else {
            throw MoshError.encryptionFailed(reason: "Invalid session key")
        }
        // Packet: nonce (8 bytes) + ciphertext + tag
        guard let packet = cryptor.seal(plaintext, nonce: nonce.bytes, header: nonce.wireBytes) else {
            throw MoshError.encryptionFailed(reason: "OCB encryption failed")
        }
        return packet
    }

    // MARK: - Decryption

    /// Decrypts a received packet
    /// - Parameter packet: The received packet (8-byte nonce + ciphertext + tag)
    /// - Returns: The decrypted plaintext (timestamps + payload), and whether the
    ///   packet advances the incoming sequence. Reordered or duplicate packets
    ///   within the window still decrypt, but must not update timestamp tracking.
    /// - Throws: MoshError.decryptionFailed if decryption or authentication fails
    func decrypt(_ packet: Data) throws -> (plaintext: Data, nonce: MoshNonce, isInOrder: Bool) {
        // Minimum packet size: 8 (nonce) + 16 (tag) = 24 bytes
        guard packet.count >= 24 else {
            throw MoshError.decryptionFailed(
                reason: "Packet too short: \(packet.count) bytes"
            )
        }

        // Extract nonce (first 8 bytes)
        let nonceData = packet.prefix(8)
        let nonce = try MoshNonce(wireBytes: Data(nonceData))

        // Validate nonce sequence (allow some reordering)
        guard nonce.isValidAfter(expected: expectedIncomingSequence) else {
            throw MoshError.nonceSequenceError(
                expected: expectedIncomingSequence,
                received: nonce.sequenceNumber
            )
        }

        guard let cryptor else {
            throw MoshError.decryptionFailed(reason: "Invalid session key")
        }
        // Ciphertext + tag is everything after the nonce
        guard let plaintext = cryptor.open(packet, from: 8, nonce: nonce.bytes) else {
            throw MoshError.decryptionFailed(reason: "OCB authentication failed")
        }

        // Update expected sequence
        let isInOrder = nonce.sequenceNumber >= expectedIncomingSequence
        if isInOrder {
            expectedIncomingSequence = nonce.sequenceNumber + 1
        }

        return (plaintext: plaintext, nonce: nonce, isInOrder: isInOrder)
    }

    // MARK: - State Management

    /// Returns the current outgoing sequence number
    var currentOutgoingSequence: UInt64 {
        nonceGenerator.currentSequence
    }

    /// Returns the expected incoming sequence number
    var currentExpectedIncoming: UInt64 {
        expectedIncomingSequence
    }
}

// MARK: - Timestamp Encoding

/// Helper for encoding/decoding mosh packet timestamps
enum MoshTimestamp {
    /// Encodes two 16-bit timestamps into 4 bytes
    /// - Parameters:
    ///   - current: Current timestamp (ms mod 65536)
    ///   - reply: Echo reply timestamp (ms mod 65536)
    /// - Returns: 4-byte encoded timestamps
    nonisolated static func encode(current: UInt16, reply: UInt16) -> Data {
        var data = Data(count: 4)
        data[0] = UInt8(current >> 8)
        data[1] = UInt8(current & 0xFF)
        data[2] = UInt8(reply >> 8)
        data[3] = UInt8(reply & 0xFF)
        return data
    }

    /// Decodes 4 bytes into two timestamps
    /// - Parameter data: The 4-byte timestamp data
    /// - Returns: (current, reply) timestamps
    nonisolated static func decode(_ data: Data) -> (current: UInt16, reply: UInt16)? {
        guard data.count >= 4 else { return nil }
        let current = UInt16(data[0]) << 8 | UInt16(data[1])
        let reply = UInt16(data[2]) << 8 | UInt16(data[3])
        return (current, reply)
    }

    /// Returns current time as a 16-bit timestamp (ms mod 65536)
    nonisolated static var now: UInt16 {
        at(ms: ProtocolTiming.monotonicNowMs())
    }

    /// 16-bit timestamp for a `ProtocolTiming.monotonicNowMs()` reading.
    nonisolated static func at(ms: UInt64) -> UInt16 {
        // Avoid 0xFFFF which is reserved as "no timestamp" sentinel.
        var ts = UInt16(ms & 0xFFFF)
        if ts == UInt16.max {
            ts &+= 1
        }
        return ts
    }
}
