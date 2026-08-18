//
//  UserMessage.swift
//  rootshell
//
//  Mosh UserMessage protobuf (client → server messages)
//
//  Clean-room implementation based on mosh protocol documentation.
//

import Foundation

/// Client → Server message containing user input
///
/// Wire format (protobuf) from userinput.proto:
/// - Field 1 (repeated): Instruction submessage
///
/// Instruction submessage (extensions):
/// - Field 2 (optional): keystroke (Keystroke message)
/// - Field 3 (optional): resize (ResizeMessage)
///
/// Keystroke message:
/// - Field 4: keys (bytes)
///
/// ResizeMessage:
/// - Field 5: width (int32)
/// - Field 6: height (int32)
struct UserMessage: Sendable {

    /// Instructions in this message
    var instructions: [Instruction] = []

    // MARK: - Instruction Types

    /// A single user instruction (keystroke or resize)
    enum Instruction: Sendable {
        /// Keystroke with raw key bytes
        case keystroke(Data)

        /// Terminal resize
        case resize(width: UInt32, height: UInt32)
    }

    // MARK: - Initialization

    nonisolated init() {}

    /// Creates a message with a single keystroke
    nonisolated init(keystroke: Data) {
        self.instructions = [.keystroke(keystroke)]
    }

    /// Creates a message with a resize instruction
    nonisolated init(width: UInt32, height: UInt32) {
        self.instructions = [.resize(width: width, height: height)]
    }

    /// Appends a keystroke
    nonisolated mutating func addKeystroke(_ data: Data) {
        instructions.append(.keystroke(data))
    }

    /// Appends a resize
    nonisolated mutating func addResize(width: UInt32, height: UInt32) {
        instructions.append(.resize(width: width, height: height))
    }

    // MARK: - Serialization

    /// Serializes to protobuf wire format
    nonisolated func serialize() throws -> Data {
        var data = Data()

        for instruction in instructions {
            // Each instruction is a nested message in field 1
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
        case .keystroke(let keyData):
            // Field 2: keystroke (Keystroke message)
            var keystrokeData = Data()
            // Keystroke field 4: keys (bytes)
            appendTag(fieldNumber: 4, wireType: .lengthDelimited, to: &keystrokeData)
            appendVarint(Int64(keyData.count), to: &keystrokeData)
            keystrokeData.append(keyData)

            appendTag(fieldNumber: 2, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(keystrokeData.count), to: &data)
            data.append(keystrokeData)

        case .resize(let width, let height):
            // Field 3: resize (ResizeMessage)
            var resizeData = Data()
            // ResizeMessage field 5: width
            appendTag(fieldNumber: 5, wireType: .varint, to: &resizeData)
            appendVarint(Int64(width), to: &resizeData)
            // ResizeMessage field 6: height
            appendTag(fieldNumber: 6, wireType: .varint, to: &resizeData)
            appendVarint(Int64(height), to: &resizeData)

            appendTag(fieldNumber: 3, wireType: .lengthDelimited, to: &data)
            appendVarint(Int64(resizeData.count), to: &data)
            data.append(resizeData)
        }

        return data
    }

    /// Deserializes from protobuf wire format
    nonisolated static func deserialize(_ data: Data) throws -> UserMessage {
        var message = UserMessage()
        var offset = 0

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            guard fieldNumber == 1, wireType == .lengthDelimited else {
                // Skip unknown field
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
                continue
            }

            // Parse instruction length
            let (length, lengthOffset) = try decodeVarint(data, from: offset)
            offset = lengthOffset

            guard offset + Int(length) <= data.count else {
                throw MoshError.protobufDeserializationFailed(
                    messageType: "UserMessage",
                    reason: "Instruction length exceeds data"
                )
            }

            // Parse instruction submessage
            let instructionData = Data(data[offset..<(offset + Int(length))])
            let instruction = try parseInstruction(instructionData)
            message.instructions.append(instruction)
            offset += Int(length)
        }

        return message
    }

    nonisolated private static func parseInstruction(_ data: Data) throws -> Instruction {
        var offset = 0
        var keystroke: Data?
        var resizeWidth: UInt32?
        var resizeHeight: UInt32?

        while offset < data.count {
            let (tag, newOffset) = try decodeVarint(data, from: offset)
            offset = newOffset

            let fieldNumber = Int(tag >> 3)
            let wireType = WireType(rawValue: Int(tag & 0x7))

            switch fieldNumber {
            case 2:  // keystroke (Keystroke message)
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "Instruction",
                        reason: "Expected message for keystroke"
                    )
                }
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                let keystrokeData = Data(data[offset..<(offset + Int(length))])

                // Parse Keystroke submessage to get field 4 (keys)
                var keystrokeOffset = 0
                while keystrokeOffset < keystrokeData.count {
                    let (keystrokeTag, keystrokeNewOffset) = try decodeVarint(keystrokeData, from: keystrokeOffset)
                    keystrokeOffset = keystrokeNewOffset
                    let keystrokeField = Int(keystrokeTag >> 3)

                    if keystrokeField == 4 {  // keys field
                        let (keysLength, keysLengthOffset) = try decodeVarint(keystrokeData, from: keystrokeOffset)
                        keystrokeOffset = keysLengthOffset
                        keystroke = Data(keystrokeData[keystrokeOffset..<(keystrokeOffset + Int(keysLength))])
                        keystrokeOffset += Int(keysLength)
                    } else {
                        keystrokeOffset = try skipField(keystrokeData, from: keystrokeOffset, wireType: .lengthDelimited)
                    }
                }
                offset += Int(length)

            case 3:  // resize (ResizeMessage)
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "Instruction",
                        reason: "Expected message for resize"
                    )
                }
                let (length, lengthOffset) = try decodeVarint(data, from: offset)
                offset = lengthOffset
                let resizeData = Data(data[offset..<(offset + Int(length))])

                // Parse ResizeMessage submessage
                var resizeOffset = 0
                while resizeOffset < resizeData.count {
                    let (resizeTag, resizeNewOffset) = try decodeVarint(resizeData, from: resizeOffset)
                    resizeOffset = resizeNewOffset
                    let resizeField = Int(resizeTag >> 3)

                    if resizeField == 5 {  // width
                        let (w, wOffset) = try decodeVarint(resizeData, from: resizeOffset)
                        resizeWidth = UInt32(w)
                        resizeOffset = wOffset
                    } else if resizeField == 6 {  // height
                        let (h, hOffset) = try decodeVarint(resizeData, from: resizeOffset)
                        resizeHeight = UInt32(h)
                        resizeOffset = hOffset
                    } else {
                        resizeOffset = try skipField(resizeData, from: resizeOffset, wireType: .varint)
                    }
                }
                offset += Int(length)

            default:
                offset = try skipField(data, from: offset, wireType: wireType ?? .varint)
            }
        }

        // Return appropriate instruction type
        if let key = keystroke {
            return .keystroke(key)
        } else if let w = resizeWidth, let h = resizeHeight {
            return .resize(width: w, height: h)
        }

        throw MoshError.protobufDeserializationFailed(
            messageType: "Instruction",
            reason: "No valid instruction found"
        )
    }
}

// MARK: - Protobuf Helpers (same as TransportInstruction)

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
