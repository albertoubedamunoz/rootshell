//
//  HostMessage.swift
//  rootshell
//
//  Mosh HostMessage protobuf (server → client messages)
//
//  Clean-room implementation based on mosh protocol documentation.
//

import Foundation

/// Server → Client message containing terminal output
///
/// Wire format (protobuf) from hostinput.proto:
/// - Field 1 (repeated): Instruction submessage
///
/// Instruction submessage (extensions):
/// - Field 2 (optional): hostbytes (HostBytes message)
/// - Field 3 (optional): resize (ResizeMessage)
/// - Field 7 (optional): echoack (EchoAck message)
///
/// HostBytes message:
/// - Field 4: hoststring (bytes)
///
/// ResizeMessage:
/// - Field 5: width (int32)
/// - Field 6: height (int32)
///
/// EchoAck message:
/// - Field 8: echo_ack_num (uint64)
struct HostMessage: Sendable {

    /// Instructions in this message
    var instructions: [Instruction] = []

    // MARK: - Instruction Types

    /// A single host instruction
    enum Instruction: Sendable {
        /// Terminal output bytes
        case hostBytes(HostBytes)

        /// Terminal resize notification
        case resize(width: UInt32, height: UInt32)

        /// Echo acknowledgment for prediction
        case echoAck(EchoAck)
    }

    /// Terminal output data
    struct HostBytes: Sendable {
        /// The terminal output data
        var data: Data

        nonisolated init(data: Data) {
            self.data = data
        }
    }

    /// Echo acknowledgment message
    struct EchoAck: Sendable {
        /// Sequence number being acknowledged
        var echoNum: UInt64

        nonisolated init(echoNum: UInt64) {
            self.echoNum = echoNum
        }
    }

    // MARK: - Initialization

    nonisolated init() {}

    /// Creates a message with terminal output
    nonisolated init(output: Data) {
        self.instructions = [.hostBytes(HostBytes(data: output))]
    }

    // MARK: - Serialization

    /// Serializes to protobuf wire format
    nonisolated func serialize() throws -> Data {
        var data = Data()

        for instruction in instructions {
            let instructionData = try serializeInstruction(instruction)
            appendTag(fieldNumber: 1, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(instructionData.count), to: &data)
            data.append(instructionData)
        }

        return data
    }

    nonisolated private func serializeInstruction(_ instruction: Instruction) throws -> Data {
        var data = Data()

        switch instruction {
        case .hostBytes(let hostBytes):
            // Field 2: hostbytes (nested message with field 4: hoststring)
            var hostData = Data()
            appendTag(fieldNumber: 4, wireType: .lengthDelimited, to: &hostData)
            appendVarint(Int64(hostBytes.data.count), to: &hostData)
            hostData.append(hostBytes.data)

            appendTag(fieldNumber: 2, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(hostData.count), to: &data)
            data.append(hostData)

        case .resize(let width, let height):
            // Field 3: resize (with field 5: width, field 6: height)
            var resizeData = Data()
            appendTag(fieldNumber: 5, wireType: .varint, to: &resizeData)
            appendVarint(Int64(width), to: &resizeData)
            appendTag(fieldNumber: 6, wireType: .varint, to: &resizeData)
            appendVarint(Int64(height), to: &resizeData)

            appendTag(fieldNumber: 3, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(resizeData.count), to: &data)
            data.append(resizeData)

        case .echoAck(let ack):
            // Field 7: echoack (nested message with field 8: echo_ack_num)
            var ackData = Data()
            appendTag(fieldNumber: 8, wireType: .varint, to: &ackData)
            appendVarint(Int64(ack.echoNum), to: &ackData)

            appendTag(fieldNumber: 7, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(ackData.count), to: &data)
            data.append(ackData)
        }

        return data
    }

    /// Deserializes from protobuf wire format
    nonisolated static func deserialize(_ data: Data) throws -> HostMessage {
        var message = HostMessage()
        message.instructions = try parseRepeatedSubmessages(
            data: data,
            messageType: "HostMessage",
            parse: parseInstruction
        )
        return message
    }

    nonisolated private static func parseInstruction(_ data: Data) throws -> Instruction {
        var offset = 0

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            switch fieldNumber {
            case 2:  // hostbytes
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "Instruction",
                        reason: "Expected message for hostbytes"
                    )
                }
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                let hostData = Data(data[offset..<(offset + Int(length))])
                let bytes = try parseHostBytes(hostData)
                return .hostBytes(bytes)

            case 3:  // resize
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "Instruction",
                        reason: "Expected message for resize"
                    )
                }
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                let resizeData = Data(data[offset..<(offset + Int(length))])
                let (width, height) = try parseResize(resizeData)
                return .resize(width: width, height: height)

            case 7:  // echoack
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "Instruction",
                        reason: "Expected message for echoack"
                    )
                }
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                let ackData = Data(data[offset..<(offset + Int(length))])
                let ack = try parseEchoAck(ackData)
                return .echoAck(ack)

            default:
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
            }
        }

        throw MoshError.protobufDeserializationFailed(
            messageType: "Instruction",
            reason: "No valid instruction found"
        )
    }

    nonisolated private static func parseHostBytes(_ data: Data) throws -> HostBytes {
        var offset = 0
        var outputData: Data?

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            // Field 4: hoststring (bytes)
            if fieldNumber == 4, wireType == .lengthDelimited {
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                outputData = Data(data[offset..<(offset + Int(length))])
                offset += Int(length)
            } else {
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
            }
        }

        guard let bytes = outputData else {
            throw MoshError.protobufDeserializationFailed(
                messageType: "HostBytes",
                reason: "Missing data field"
            )
        }

        return HostBytes(data: bytes)
    }

    nonisolated private static func parseResize(_ data: Data) throws -> (width: UInt32, height: UInt32) {
        var offset = 0
        var width: UInt32 = 0
        var height: UInt32 = 0

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)

            // Field 5: width, Field 6: height
            if fieldNumber == 5 {
                let (w, wOffset) = try decodeVarint(data, from: offset)
                width = UInt32(w)
                offset = wOffset
            } else if fieldNumber == 6 {
                let (h, hOffset) = try decodeVarint(data, from: offset)
                height = UInt32(h)
                offset = hOffset
            } else {
                offset = try skipField(data, from: offset, wireType: .varint)
            }
        }

        return (width, height)
    }

    nonisolated private static func parseEchoAck(_ data: Data) throws -> EchoAck {
        var offset = 0
        var echoNum: UInt64 = 0

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)

            // Field 8: echo_ack_num
            if fieldNumber == 8 {
                let (n, nOffset) = try decodeVarint(data, from: offset)
                echoNum = UInt64(bitPattern: Int64(n))
                offset = nOffset
            } else {
                offset = try skipField(data, from: offset, wireType: .varint)
            }
        }

        return EchoAck(echoNum: echoNum)
    }
}

// MARK: - Convenience Methods

extension HostMessage {
    /// Extracts all terminal output from the message
    var allOutput: Data {
        var result = Data()
        for instruction in instructions {
            if case .hostBytes(let bytes) = instruction {
                result.append(bytes.data)
            }
        }
        return result
    }

    /// Returns true if this message contains any terminal output
    var hasOutput: Bool {
        instructions.contains { instruction in
            if case .hostBytes = instruction { return true }
            return false
        }
    }

    /// Returns any resize instruction in the message
    var resizeInfo: (width: UInt32, height: UInt32)? {
        for instruction in instructions {
            if case .resize(let w, let h) = instruction {
                return (w, h)
            }
        }
        return nil
    }
}
