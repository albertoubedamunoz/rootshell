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
        var offset = 0

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            guard fieldNumber == 1, wireType == .lengthDelimited else {
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
                continue
            }

            let (length, lengthOffset) = try decodeVarint(data, from: offset)
            offset = lengthOffset

            guard offset + Int(length) <= data.count else {
                throw MoshError.protobufDeserializationFailed(
                    messageType: "HostMessage",
                    reason: "Instruction length exceeds data"
                )
            }

            let instructionData = Data(data[offset..<(offset + Int(length))])
            let instruction = try parseInstruction(instructionData)
            message.instructions.append(instruction)
            offset += Int(length)
        }

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

// MARK: - Protobuf Helpers

private enum WireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// Appends a protobuf tag directly to data, avoiding intermediate allocation
nonisolated private func appendTag(fieldNumber: Int, wireType: WireType, to data: inout Data) {
    appendVarint(Int64((fieldNumber << 3) | wireType.rawValue), to: &data)
}

/// Encodes a varint directly into the given Data, avoiding intermediate allocation
nonisolated private func appendVarint(_ value: Int64, to data: inout Data) {
    var v = UInt64(bitPattern: value)

    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 {
            byte |= 0x80
        }
        data.append(byte)
    } while v != 0
}

/// Legacy wrapper for compatibility - prefer appendVarint for new code
nonisolated private func encodeTag(fieldNumber: Int, wireType: WireType) -> [UInt8] {
    encodeVarint(Int64((fieldNumber << 3) | wireType.rawValue))
}

/// Legacy wrapper for compatibility - prefer appendVarint for new code
nonisolated private func encodeVarint(_ value: Int64) -> [UInt8] {
    var result: [UInt8] = []
    var v = UInt64(bitPattern: value)

    repeat {
        var byte = UInt8(v & 0x7F)
        v >>= 7
        if v != 0 {
            byte |= 0x80
        }
        result.append(byte)
    } while v != 0

    return result
}

nonisolated private func decodeVarint(_ data: Data, from offset: Int) throws -> (value: Int64, newOffset: Int) {
    var result: Int64 = 0
    var shift = 0
    var currentOffset = offset

    while currentOffset < data.count {
        let byte = data[currentOffset]
        currentOffset += 1

        result |= Int64(byte & 0x7F) << shift
        shift += 7

        if byte & 0x80 == 0 {
            return (result, currentOffset)
        }

        if shift > 63 {
            throw MoshError.protobufDeserializationFailed(
                messageType: "varint",
                reason: "Varint too long"
            )
        }
    }

    throw MoshError.protobufDeserializationFailed(
        messageType: "varint",
        reason: "Unexpected end of data"
    )
}

nonisolated private func skipField(_ data: Data, from offset: Int, wireType: WireType) throws -> Int {
    switch wireType {
    case .varint:
        let (_, newOffset) = try decodeVarint(data, from: offset)
        return newOffset
    case .fixed64:
        return offset + 8
    case .lengthDelimited:
        let (length, newOffset) = try decodeVarint(data, from: offset)
        return newOffset + Int(length)
    case .fixed32:
        return offset + 4
    case .startGroup, .endGroup:
        throw MoshError.protobufDeserializationFailed(
            messageType: "field",
            reason: "Groups not supported"
        )
    }
}
