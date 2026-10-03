//
//  TransportInstruction.swift
//  rootshell
//
//  Mosh TransportInstruction protobuf message (clean-room implementation)
//
//  Based on mosh protocol documentation. This is a data format implementation,
//  not derived from any copyrighted source code.
//

import Foundation

/// Mosh TransportInstruction message
///
/// This is the main message wrapper sent between client and server.
/// Contains state synchronization data with optional compression.
///
/// Wire format (protobuf):
/// - Field 1 (optional): protocol_version (uint32)
/// - Field 2 (optional): old_num (uint64) - sender's known receiver state
/// - Field 3 (optional): new_num (uint64) - current state number being sent
/// - Field 4 (optional): ack_num (uint64) - acknowledgment of receiver's state
/// - Field 5 (optional): throwaway_num (uint64) - earliest state receiver must retain
/// - Field 6 (optional): diff (bytes) - compressed state diff
/// - Field 7 (optional): chaff (bytes) - random padding
struct TransportInstruction: Sendable {

    /// Protocol version (current mosh version is 2)
    var protocolVersion: UInt32 = 2

    /// Sender's known receiver state number (diffing from this state)
    var oldNum: UInt64 = 0

    /// Current state number being sent
    var newNum: UInt64 = 0

    /// Acknowledgment of receiver's state
    var ackNum: UInt64 = 0

    /// Earliest state the receiver must retain
    var throwawayNum: UInt64 = 0

    /// Compressed protobuf diff (UserMessage or HostMessage)
    var diff: Data = Data()

    /// Random padding for length obfuscation
    var chaff: Data = Data()

    // MARK: - Initialization

    nonisolated init() {}

    /// Creates an instruction with the given diff
    nonisolated init(
        diff: Data,
        oldNum: UInt64 = 0,
        newNum: UInt64 = 0,
        ackNum: UInt64 = 0,
        throwawayNum: UInt64 = 0
    ) {
        self.diff = diff
        self.oldNum = oldNum
        self.newNum = newNum
        self.ackNum = ackNum
        self.throwawayNum = throwawayNum
    }

    // MARK: - Serialization

    /// Serializes to protobuf wire format
    /// Note: mosh-server expects all fields to be present, even when 0
    nonisolated func serialize() throws -> Data {
        var data = Data()

        // Field 1: protocol_version (varint) - always include
        appendTag(fieldNumber: 1, wireType: .varint, to: &data)
        appendVarint(Int64(protocolVersion), to: &data)

        // Field 2: old_num (varint) - always include
        // Use bitPattern to handle values > Int64.max (like UInt64.max for shutdown)
        appendTag(fieldNumber: 2, wireType: .varint, to: &data)
        appendVarint(Int64(bitPattern: oldNum), to: &data)

        // Field 3: new_num (varint) - always include
        appendTag(fieldNumber: 3, wireType: .varint, to: &data)
        appendVarint(Int64(bitPattern: newNum), to: &data)

        // Field 4: ack_num (varint) - always include
        appendTag(fieldNumber: 4, wireType: .varint, to: &data)
        appendVarint(Int64(bitPattern: ackNum), to: &data)

        // Field 5: throwaway_num (varint) - always include
        appendTag(fieldNumber: 5, wireType: .varint, to: &data)
        appendVarint(Int64(bitPattern: throwawayNum), to: &data)

        // Field 6: diff (length-delimited) - always include (can be empty)
        appendTag(fieldNumber: 6, wireType: .lengthDelimited, to: &data)
        appendVarint(Int64(diff.count), to: &data)
        if !diff.isEmpty {
            data.append(diff)
        }

        // Field 7: chaff (length-delimited) - optional, for traffic obfuscation
        if !chaff.isEmpty {
            appendTag(fieldNumber: 7, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(chaff.count), to: &data)
            data.append(chaff)
        }

        return data
    }

    /// Deserializes from protobuf wire format
    nonisolated static func deserialize(_ data: Data) throws -> TransportInstruction {
        var instruction = TransportInstruction()
        var offset = 0

        while offset < data.count {
            // Read field tag
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            switch fieldNumber {
            case 1:  // protocol_version
                guard wireType == .varint else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected varint for field 1"
                    )
                }
                let (value, newOffset) = try decodeUInt32(data, from: offset, messageType: "TransportInstruction")
                instruction.protocolVersion = value
                offset = newOffset

            case 2:  // old_num
                guard wireType == .varint else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected varint for field 2"
                    )
                }
                let (value, newOffset) = try decodeVarint(data, from: offset)
                instruction.oldNum = UInt64(bitPattern: Int64(value))
                offset = newOffset

            case 3:  // new_num
                guard wireType == .varint else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected varint for field 3"
                    )
                }
                let (value, newOffset) = try decodeVarint(data, from: offset)
                instruction.newNum = UInt64(bitPattern: Int64(value))
                offset = newOffset

            case 4:  // ack_num
                guard wireType == .varint else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected varint for field 4"
                    )
                }
                let (value, newOffset) = try decodeVarint(data, from: offset)
                instruction.ackNum = UInt64(bitPattern: Int64(value))
                offset = newOffset

            case 5:  // throwaway_num
                guard wireType == .varint else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected varint for field 5"
                    )
                }
                let (value, newOffset) = try decodeVarint(data, from: offset)
                instruction.throwawayNum = UInt64(bitPattern: Int64(value))
                offset = newOffset

            case 6:  // diff
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected length-delimited for field 6"
                    )
                }
                (instruction.diff, offset) = try decodeLengthDelimited(data, from: offset, messageType: "TransportInstruction")

            case 7:  // chaff
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected length-delimited for field 7"
                    )
                }
                (instruction.chaff, offset) = try decodeLengthDelimited(data, from: offset, messageType: "TransportInstruction")

            default:
                // Skip unknown field
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
            }
        }

        return instruction
    }
}
