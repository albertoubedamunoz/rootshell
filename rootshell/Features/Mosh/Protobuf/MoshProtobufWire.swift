//
//  MoshProtobufWire.swift
//  rootshell
//
//  Protobuf wire-format primitives shared by the hand-written mosh message
//  codecs (TransportInstruction, UserMessage, HostMessage).
//

import Foundation

enum WireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// Appends a protobuf tag directly to data, avoiding intermediate allocation
nonisolated func appendTag(fieldNumber: Int, wireType: WireType, to data: inout Data) {
    appendVarint(Int64((fieldNumber << 3) | wireType.rawValue), to: &data)
}

/// Encodes a varint directly into the given Data, avoiding intermediate allocation
nonisolated func appendVarint(_ value: Int64, to data: inout Data) {
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

nonisolated func decodeVarint(_ data: Data, from offset: Int) throws -> (value: Int64, newOffset: Int) {
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

nonisolated func skipField(_ data: Data, from offset: Int, wireType: WireType) throws -> Int {
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

/// Decodes a message whose only field is `repeated` field 1 of length-delimited
/// submessages, handing each submessage's bytes to `parse`. Unknown fields are skipped.
nonisolated func parseRepeatedSubmessages<T>(
    data: Data,
    messageType: String,
    parse: (Data) throws -> T
) throws -> [T] {
    var results: [T] = []
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
                messageType: messageType,
                reason: "Instruction length exceeds data"
            )
        }

        results.append(try parse(Data(data[offset..<(offset + Int(length))])))
        offset += Int(length)
    }

    return results
}
