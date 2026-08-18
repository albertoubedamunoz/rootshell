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
                let (value, newOffset) = try decodeVarint(data, from: offset)
                instruction.protocolVersion = UInt32(value)
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
                let (length, newOffset) = try decodeVarint(data, from: offset)
                offset = newOffset
                guard offset + Int(length) <= data.count else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Diff length exceeds data"
                    )
                }
                instruction.diff = Data(data[offset..<(offset + Int(length))])
                offset += Int(length)

            case 7:  // chaff
                guard wireType == .lengthDelimited else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Expected length-delimited for field 7"
                    )
                }
                let (length, newOffset) = try decodeVarint(data, from: offset)
                offset = newOffset
                guard offset + Int(length) <= data.count else {
                    throw MoshError.protobufDeserializationFailed(
                        messageType: "TransportInstruction",
                        reason: "Chaff length exceeds data"
                    )
                }
                instruction.chaff = Data(data[offset..<(offset + Int(length))])
                offset += Int(length)

            default:
                // Skip unknown field
                offset = try skipField(data, from: offset - (newOffset - offset), wireType: wireType ?? .varint)
            }
        }

        return instruction
    }
}

// MARK: - Compression (using C zlib for proper header/checksum format)

import zlib

extension TransportInstruction {
    /// Compresses the diff field using zlib (with header and checksum, as mosh expects)
    nonisolated mutating func compressDiff() throws {
        guard !diff.isEmpty else { return }

        diff = try zlibCompress(diff)
    }

    /// Decompresses the diff field
    nonisolated mutating func decompressDiff() throws {
        guard !diff.isEmpty else { return }

        diff = try zlibDecompress(diff)
    }

    /// Compresses data using zlib with proper header/checksum
    nonisolated private func zlibCompress(_ data: Data) throws -> Data {
        var stream = z_stream()

        // Initialize deflate with default compression
        let initResult = deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw MoshError.compressionError(reason: "deflateInit failed: \(initResult)")
        }

        defer { deflateEnd(&stream) }

        // Allocate output buffer (worst case: slightly larger than input)
        let maxOutputSize = deflateBound(&stream, UInt(data.count))
        var outputBuffer = [UInt8](repeating: 0, count: Int(maxOutputSize))

        let compressedSize: Int = try data.withUnsafeBytes { inputPtr in
            try outputBuffer.withUnsafeMutableBufferPointer { outputPtr -> Int in
                guard let inputBase = inputPtr.baseAddress,
                      let outputBase = outputPtr.baseAddress else {
                    throw MoshError.compressionError(reason: "Invalid buffer")
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(data.count)
                stream.next_out = outputBase
                stream.avail_out = UInt32(outputPtr.count)

                let deflateResult = deflate(&stream, Z_FINISH)
                guard deflateResult == Z_STREAM_END else {
                    throw MoshError.compressionError(reason: "deflate failed: \(deflateResult)")
                }

                return Int(stream.total_out)
            }
        }

        return Data(outputBuffer.prefix(compressedSize))
    }

    /// Decompresses zlib data with proper header/checksum
    nonisolated private func zlibDecompress(_ data: Data) throws -> Data {
        var stream = z_stream()

        // Initialize inflate
        let initResult = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            throw MoshError.compressionError(reason: "inflateInit failed: \(initResult)")
        }

        defer { inflateEnd(&stream) }

        // Start with a reasonable output buffer size (messages are typically small)
        let maxOutputSize = max(data.count * 10, 4096)
        var outputBuffer = [UInt8](repeating: 0, count: maxOutputSize)

        let decompressedSize: Int = try data.withUnsafeBytes { inputPtr in
            try outputBuffer.withUnsafeMutableBufferPointer { outputPtr -> Int in
                guard let inputBase = inputPtr.baseAddress,
                      let outputBase = outputPtr.baseAddress else {
                    throw MoshError.compressionError(reason: "Invalid buffer")
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputBase.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = UInt32(data.count)
                stream.next_out = outputBase
                stream.avail_out = UInt32(outputPtr.count)

                let inflateResult = inflate(&stream, Z_FINISH)
                guard inflateResult == Z_STREAM_END else {
                    throw MoshError.compressionError(reason: "inflate failed: \(inflateResult)")
                }

                return Int(stream.total_out)
            }
        }

        return Data(outputBuffer.prefix(decompressedSize))
    }
}

// MARK: - Protobuf Encoding Helpers

private enum WireType: Int {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

nonisolated private func encodeTag(fieldNumber: Int, wireType: WireType) -> [UInt8] {
    encodeVarint(Int64((fieldNumber << 3) | wireType.rawValue))
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
