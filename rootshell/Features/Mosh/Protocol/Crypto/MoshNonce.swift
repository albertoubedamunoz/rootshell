//
//  MoshNonce.swift
//  rootshell
//
//  Mosh protocol nonce handling for AES-OCB encryption
//

import Foundation

/// Represents a mosh protocol nonce (12 bytes for AES-OCB)
///
/// Wire format:
/// - 8 bytes sent on wire (sequence number portion)
/// - 12 bytes used for crypto (4 zero bytes + 8-byte sequence)
///
/// Sequence number encoding (8 bytes, big-endian):
/// - Bit 63: Direction (0 = TO_SERVER, 1 = TO_CLIENT)
/// - Bits 0-62: Monotonic counter
struct MoshNonce: Equatable, Sendable {

    /// Direction of the message
    enum Direction: UInt8, Sendable {
        case toServer = 0
        case toClient = 1
    }

    /// The direction of this nonce
    let direction: Direction

    /// The sequence number (bits 0-62)
    let sequenceNumber: UInt64

    // MARK: - Initialization

    /// Creates a nonce with the given direction and sequence number
    /// - Parameters:
    ///   - direction: Message direction
    ///   - sequenceNumber: Monotonic counter (must fit in 63 bits)
    nonisolated init(direction: Direction, sequenceNumber: UInt64) {
        precondition(sequenceNumber < (1 << 63), "Sequence number must fit in 63 bits")
        self.direction = direction
        self.sequenceNumber = sequenceNumber
    }

    /// Creates a nonce from wire format (8 bytes)
    /// - Parameter wireBytes: The 8-byte sequence number from the packet
    /// - Throws: MoshError.invalidPacketFormat if bytes are invalid
    nonisolated init(wireBytes: Data) throws {
        guard wireBytes.count == 8 else {
            throw MoshError.invalidPacketFormat(
                reason: "Nonce wire format must be 8 bytes, got \(wireBytes.count)"
            )
        }

        // Parse as big-endian UInt64
        let value = wireBytes.withUnsafeBytes { ptr -> UInt64 in
            var result: UInt64 = 0
            for i in 0..<8 {
                result = (result << 8) | UInt64(ptr[i])
            }
            return result
        }

        // Extract direction (bit 63)
        let directionBit = (value >> 63) & 1
        self.direction = directionBit == 1 ? .toClient : .toServer

        // Extract sequence number (bits 0-62)
        self.sequenceNumber = value & ((1 << 63) - 1)
    }

    // MARK: - Byte Representations

    /// The 8-byte wire format (sent in packets)
    nonisolated var wireBytes: Data {
        // Combine direction and sequence into 64-bit value
        var value = sequenceNumber
        if direction == .toClient {
            value |= (1 << 63)
        }

        // Convert to big-endian bytes
        var bytes = Data(count: 8)
        for i in (0..<8).reversed() {
            bytes[7 - i] = UInt8(value >> (i * 8) & 0xFF)
        }
        return bytes
    }

    /// The full 12-byte nonce for AES-OCB crypto
    /// Format: [4 zero bytes] + [8-byte wire format]
    nonisolated var cryptoBytes: Data {
        var result = Data(count: 12)
        // First 4 bytes are zero
        result[0] = 0
        result[1] = 0
        result[2] = 0
        result[3] = 0
        // Last 8 bytes are the wire format
        let wire = wireBytes
        for i in 0..<8 {
            result[4 + i] = wire[i]
        }
        return result
    }

    /// Returns the nonce bytes as an array (for crypto operations)
    nonisolated var bytes: [UInt8] {
        Array(cryptoBytes)
    }

    // MARK: - Sequence Operations

    /// Returns the next nonce in sequence (same direction)
    nonisolated func next() -> MoshNonce {
        MoshNonce(direction: direction, sequenceNumber: sequenceNumber + 1)
    }

    /// Validates that this nonce follows the expected sequence
    /// - Parameter expected: The expected sequence number
    /// - Returns: true if this nonce is at or after the expected sequence
    nonisolated func isValidAfter(expected: UInt64) -> Bool {
        // Allow for some packet reordering, but reject old packets
        // Mosh allows up to a window of packets
        let maxReorder: UInt64 = 256
        return sequenceNumber >= expected || (expected - sequenceNumber) <= maxReorder
    }
}

// MARK: - CustomStringConvertible

extension MoshNonce: CustomStringConvertible {
    nonisolated var description: String {
        let dir = direction == .toServer ? "S" : "C"
        return "Nonce(\(dir):\(sequenceNumber))"
    }
}

// MARK: - Nonce Generator

/// Generates nonces for a mosh session
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshCryptoSession which is @MainActor.
@MainActor
final class MoshNonceGenerator {
    private var nextSequence: UInt64 = 0
    private let direction: MoshNonce.Direction

    /// Creates a generator for the specified direction
    /// - Parameter direction: Whether generating client->server or server->client nonces
    init(direction: MoshNonce.Direction) {
        self.direction = direction
    }

    /// Creates a generator starting from a specific sequence (for session resume)
    /// - Parameters:
    ///   - direction: Whether generating client->server or server->client nonces
    ///   - startingSequence: The sequence number to start from
    init(direction: MoshNonce.Direction, startingSequence: UInt64) {
        self.direction = direction
        self.nextSequence = startingSequence
    }

    /// Generates the next nonce
    func next() -> MoshNonce {
        let nonce = MoshNonce(direction: direction, sequenceNumber: nextSequence)
        nextSequence += 1
        return nonce
    }

    /// Returns the current sequence number without incrementing
    var currentSequence: UInt64 {
        nextSequence
    }

    /// Resets the generator to the initial state
    func reset() {
        nextSequence = 0
    }

    /// Sets the sequence to a specific value (for session resume)
    func setSequence(_ sequence: UInt64) {
        nextSequence = sequence
    }
}
