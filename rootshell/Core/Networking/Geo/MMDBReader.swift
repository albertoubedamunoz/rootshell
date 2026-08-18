//
//  MMDBReader.swift
//  rootshell
//
//  Read-only MaxMind DB reader used for local GeoIP lookups.
//

import Darwin
import Foundation

enum MMDBReaderError: LocalizedError {
    case invalidDatabase(String)
    case unsupportedRecordSize(Int)
    case unsupportedDataType(Int)
    case corruptedPointer

    var errorDescription: String? {
        switch self {
        case .invalidDatabase(let reason):
            return "Invalid MMDB file: \(reason)"
        case .unsupportedRecordSize(let size):
            return "Unsupported MMDB record size: \(size)"
        case .unsupportedDataType(let type):
            return "Unsupported MMDB data type: \(type)"
        case .corruptedPointer:
            return "Invalid MMDB pointer"
        }
    }
}

enum MMDBValue: Sendable {
    case string(String)
    case unsignedInteger(UInt64)
    case signedInteger(Int64)
    case double(Double)
    case float(Float)
    case bool(Bool)
    case bytes(Data)
    case array([MMDBValue])
    case map([String: MMDBValue])

    nonisolated var stringValue: String? {
        switch self {
        case .string(let value):
            value
        case .unsignedInteger(let value):
            String(value)
        case .signedInteger(let value):
            String(value)
        default:
            nil
        }
    }

    nonisolated var unsignedIntegerValue: UInt64? {
        switch self {
        case .unsignedInteger(let value):
            value
        case .signedInteger(let value) where value >= 0:
            UInt64(value)
        case .string(let value):
            UInt64(value)
        default:
            nil
        }
    }

    nonisolated var mapValue: [String: MMDBValue]? {
        if case .map(let value) = self {
            return value
        }
        return nil
    }
}

struct MMDBLookupResult: Sendable {
    let value: MMDBValue
    let prefixLength: Int
    let network: String
}

struct MMDBMetadata: Sendable {
    let nodeCount: UInt32
    let recordSize: Int
    let ipVersion: Int
    let databaseType: String
    let buildEpoch: UInt64?
}

struct MMDBReader: Sendable {
    private nonisolated static let metadataMarker = Data([0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8))

    private nonisolated struct DecodeState {
        var depth: Int = 0
        var pointerHops: Int = 0
        static let maxDepth = 512
        static let maxPointerHops = 64
    }

    let metadata: MMDBMetadata

    private let data: Data
    private let searchTreeSize: Int
    private let dataSectionStart: Int
    private let ipv4StartNode: UInt32?

    nonisolated init(url: URL) throws {
        let mappedData = try Data(contentsOf: url, options: [.mappedIfSafe])
        let parsedMetadata = try Self.parseMetadata(from: mappedData)

        switch parsedMetadata.recordSize {
        case 24, 28, 32:
            break
        default:
            throw MMDBReaderError.unsupportedRecordSize(parsedMetadata.recordSize)
        }

        let (treeSize, treeOverflow) = Int(parsedMetadata.nodeCount).multipliedReportingOverflow(by: parsedMetadata.recordSize / 4)
        guard !treeOverflow, treeSize >= 0, treeSize + 16 <= mappedData.count else {
            throw MMDBReaderError.invalidDatabase("truncated search tree")
        }

        self.data = mappedData
        self.metadata = parsedMetadata
        self.searchTreeSize = treeSize
        self.dataSectionStart = treeSize + 16

        if parsedMetadata.ipVersion == 6 {
            self.ipv4StartNode = Self.findIPv4StartNode(in: mappedData, metadata: parsedMetadata)
        } else {
            self.ipv4StartNode = nil
        }
    }

    nonisolated func lookup(ipString: String) throws -> MMDBLookupResult? {
        let address = try ParsedIPAddress.parse(ipString)

        switch address {
        case .ipv4(let bytes):
            switch metadata.ipVersion {
            case 4:
                return try lookup(bits: bytes, startNode: 0, familyBits: 32, addressFamily: .ipv4)
            case 6:
                guard let ipv4StartNode else { return nil }
                return try lookup(bits: bytes, startNode: ipv4StartNode, familyBits: 32, addressFamily: .ipv4)
            default:
                return nil
            }

        case .ipv6(let bytes):
            guard metadata.ipVersion == 6 else { return nil }
            return try lookup(bits: bytes, startNode: 0, familyBits: 128, addressFamily: .ipv6)
        }
    }

    private nonisolated func lookup(bits: [UInt8], startNode: UInt32, familyBits: Int, addressFamily: ParsedIPAddress.Family) throws -> MMDBLookupResult? {
        if startNode == metadata.nodeCount {
            return nil
        }

        if startNode > metadata.nodeCount {
            return try decodeResult(node: startNode, prefixLength: 0, addressBytes: bits, addressFamily: addressFamily)
        }

        var node = startNode
        var traversedBits = 0

        for bitIndex in 0..<familyBits {
            guard node < metadata.nodeCount else { break }
            let byte = bits[bitIndex / 8]
            let bit = Int((byte >> (7 - (bitIndex % 8))) & 1)
            node = readNode(nodeNumber: node, branch: bit)
            traversedBits += 1
        }

        guard node != metadata.nodeCount else { return nil }
        return try decodeResult(node: node, prefixLength: traversedBits, addressBytes: bits, addressFamily: addressFamily)
    }

    private nonisolated func decodeResult(node: UInt32, prefixLength: Int, addressBytes: [UInt8], addressFamily: ParsedIPAddress.Family) throws -> MMDBLookupResult? {
        guard node > metadata.nodeCount else { return nil }
        let relativeOffset = Int(node - metadata.nodeCount)
        guard relativeOffset >= 16 else {
            throw MMDBReaderError.corruptedPointer
        }
        let offset = searchTreeSize + relativeOffset
        guard offset < data.count else {
            throw MMDBReaderError.corruptedPointer
        }

        var cursor = offset
        var state = DecodeState()
        let value = try decodeValue(at: &cursor, state: &state)
        let network = Self.renderNetwork(addressBytes: addressBytes, prefixLength: prefixLength, family: addressFamily)
        return MMDBLookupResult(value: value, prefixLength: prefixLength, network: network)
    }

    private nonisolated func readNode(nodeNumber: UInt32, branch: Int) -> UInt32 {
        let nodeByteSize = metadata.recordSize / 4
        let offset = Int(nodeNumber) * nodeByteSize
        guard offset + nodeByteSize <= data.count else {
            return metadata.nodeCount
        }

        switch metadata.recordSize {
        case 24:
            let branchOffset = offset + (branch * 3)
            return (UInt32(data[branchOffset]) << 16)
                | (UInt32(data[branchOffset + 1]) << 8)
                | UInt32(data[branchOffset + 2])

        case 28:
            if branch == 0 {
                return (UInt32(data[offset + 3] & 0xF0) << 20)
                    | (UInt32(data[offset]) << 16)
                    | (UInt32(data[offset + 1]) << 8)
                    | UInt32(data[offset + 2])
            }
            return (UInt32(data[offset + 3] & 0x0F) << 24)
                | (UInt32(data[offset + 4]) << 16)
                | (UInt32(data[offset + 5]) << 8)
                | UInt32(data[offset + 6])

        case 32:
            let branchOffset = offset + (branch * 4)
            return (UInt32(data[branchOffset]) << 24)
                | (UInt32(data[branchOffset + 1]) << 16)
                | (UInt32(data[branchOffset + 2]) << 8)
                | UInt32(data[branchOffset + 3])

        default:
            return metadata.nodeCount
        }
    }

    private nonisolated func decodeValue(at offset: inout Int, state: inout DecodeState) throws -> MMDBValue {
        state.depth += 1
        defer { state.depth -= 1 }
        guard state.depth <= DecodeState.maxDepth else {
            throw MMDBReaderError.invalidDatabase("decode depth exceeded")
        }

        guard offset < data.count else {
            throw MMDBReaderError.invalidDatabase("unexpected end of file")
        }

        let control = data[offset]
        offset += 1

        var type = Int(control >> 5)
        if type == 0 {
            guard offset < data.count else {
                throw MMDBReaderError.invalidDatabase("missing extended type")
            }
            type = Int(data[offset]) + 7
            offset += 1
        }

        if type == 1 {
            state.pointerHops += 1
            guard state.pointerHops <= DecodeState.maxPointerHops else {
                throw MMDBReaderError.corruptedPointer
            }
            let pointer = try decodePointer(control: control, offset: &offset)
            var pointedOffset = dataSectionStart + pointer
            guard pointedOffset >= dataSectionStart, pointedOffset < data.count else {
                throw MMDBReaderError.corruptedPointer
            }
            return try decodeValue(at: &pointedOffset, state: &state)
        }

        let size = try decodeSize(control: control, offset: &offset)

        switch type {
        case 2:
            let value = try readString(length: size, offset: &offset)
            return .string(value)

        case 3:
            guard size == 8 else {
                throw MMDBReaderError.invalidDatabase("double must be 8 bytes")
            }
            let raw = try readUnsignedInteger(length: 8, offset: &offset)
            return .double(Double(bitPattern: raw))

        case 4:
            let bytes = try readData(length: size, offset: &offset)
            return .bytes(bytes)

        case 5, 6, 9:
            let value = try readUnsignedInteger(length: size, offset: &offset)
            return .unsignedInteger(value)

        case 10:
            let bytes = try readData(length: size, offset: &offset)
            return .bytes(bytes)

        case 7:
            try validateContainerSize(size, minimumBytesPerEntry: 2, offset: offset)
            var map: [String: MMDBValue] = [:]
            map.reserveCapacity(min(size, 4096))
            for _ in 0..<size {
                let keyValue = try decodeValue(at: &offset, state: &state)
                guard case .string(let key) = keyValue else {
                    throw MMDBReaderError.invalidDatabase("map key is not a string")
                }
                map[key] = try decodeValue(at: &offset, state: &state)
            }
            return .map(map)

        case 8:
            let value = try readUnsignedInteger(length: size, offset: &offset)
            let leftShift = max(0, 8 - size) * 8
            let signed = Int64(bitPattern: value << leftShift) >> leftShift
            return .signedInteger(signed)

        case 11:
            try validateContainerSize(size, minimumBytesPerEntry: 1, offset: offset)
            var array: [MMDBValue] = []
            array.reserveCapacity(min(size, 4096))
            for _ in 0..<size {
                array.append(try decodeValue(at: &offset, state: &state))
            }
            return .array(array)

        case 14:
            return .bool(size != 0)

        case 15:
            guard size == 4 else {
                throw MMDBReaderError.invalidDatabase("float must be 4 bytes")
            }
            let raw = UInt32(try readUnsignedInteger(length: 4, offset: &offset))
            return .float(Float(bitPattern: raw))

        default:
            throw MMDBReaderError.unsupportedDataType(type)
        }
    }

    private nonisolated func validateContainerSize(_ size: Int, minimumBytesPerEntry: Int, offset: Int) throws {
        let remaining = data.count - offset
        guard size >= 0, remaining >= 0, size <= remaining / minimumBytesPerEntry else {
            throw MMDBReaderError.invalidDatabase("container size exceeds file")
        }
    }

    private nonisolated func decodePointer(control: UInt8, offset: inout Int) throws -> Int {
        let size = Int((control >> 3) & 0x03) + 1
        let valueBits = Int(control & 0x07)

        guard offset + size <= data.count else {
            throw MMDBReaderError.corruptedPointer
        }

        switch size {
        case 1:
            let pointer = (valueBits << 8) | Int(data[offset])
            offset += 1
            return pointer

        case 2:
            let pointer = (valueBits << 16)
                | (Int(data[offset]) << 8)
                | Int(data[offset + 1])
            offset += 2
            return pointer + 2048

        case 3:
            let pointer = (valueBits << 24)
                | (Int(data[offset]) << 16)
                | (Int(data[offset + 1]) << 8)
                | Int(data[offset + 2])
            offset += 3
            return pointer + 526_336

        case 4:
            let pointer = (Int(data[offset]) << 24)
                | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8)
                | Int(data[offset + 3])
            offset += 4
            return pointer

        default:
            throw MMDBReaderError.corruptedPointer
        }
    }

    private nonisolated func decodeSize(control: UInt8, offset: inout Int) throws -> Int {
        let size = Int(control & 0x1F)
        switch size {
        case 0..<29:
            return size
        case 29:
            guard offset < data.count else {
                throw MMDBReaderError.invalidDatabase("missing size byte")
            }
            let value = 29 + Int(data[offset])
            offset += 1
            return value
        case 30:
            guard offset + 1 < data.count else {
                throw MMDBReaderError.invalidDatabase("missing size bytes")
            }
            let value = 285 + (Int(data[offset]) << 8) + Int(data[offset + 1])
            offset += 2
            return value
        case 31:
            guard offset + 2 < data.count else {
                throw MMDBReaderError.invalidDatabase("missing size bytes")
            }
            let value = 65_821 + (Int(data[offset]) << 16) + (Int(data[offset + 1]) << 8) + Int(data[offset + 2])
            offset += 3
            return value
        default:
            return size
        }
    }

    private nonisolated func readString(length: Int, offset: inout Int) throws -> String {
        let chunk = try readData(length: length, offset: &offset)
        guard let string = String(data: chunk, encoding: .utf8) else {
            throw MMDBReaderError.invalidDatabase("invalid UTF-8 string")
        }
        return string
    }

    private nonisolated func readUnsignedInteger(length: Int, offset: inout Int) throws -> UInt64 {
        guard offset + length <= data.count else {
            throw MMDBReaderError.invalidDatabase("unexpected end of integer")
        }

        var value: UInt64 = 0
        for index in 0..<length {
            value = (value << 8) | UInt64(data[offset + index])
        }
        offset += length
        return value
    }

    private nonisolated func readData(length: Int, offset: inout Int) throws -> Data {
        guard offset + length <= data.count else {
            throw MMDBReaderError.invalidDatabase("unexpected end of data section")
        }
        let chunk = data.subdata(in: offset..<(offset + length))
        offset += length
        return chunk
    }

    private nonisolated static func parseMetadata(from data: Data) throws -> MMDBMetadata {
        guard let markerRange = data.range(of: metadataMarker, options: .backwards) else {
            throw MMDBReaderError.invalidDatabase("missing metadata marker")
        }

        var cursor = markerRange.upperBound
        let reader = MMDBReader.makeMetadataReader(data: data)
        var state = DecodeState()
        let metadataValue = try reader.decodeValue(at: &cursor, state: &state)
        guard case .map(let map) = metadataValue else {
            throw MMDBReaderError.invalidDatabase("metadata is not a map")
        }

        guard let nodeCount = map["node_count"]?.unsignedIntegerValue,
              let recordSize = map["record_size"]?.unsignedIntegerValue,
              let ipVersion = map["ip_version"]?.unsignedIntegerValue,
              let databaseType = map["database_type"]?.stringValue else {
            throw MMDBReaderError.invalidDatabase("missing metadata fields")
        }

        return MMDBMetadata(
            nodeCount: UInt32(nodeCount),
            recordSize: Int(recordSize),
            ipVersion: Int(ipVersion),
            databaseType: databaseType,
            buildEpoch: map["build_epoch"]?.unsignedIntegerValue
        )
    }

    private nonisolated static func makeMetadataReader(data: Data) -> MMDBReader {
        let placeholder = MMDBMetadata(nodeCount: 0, recordSize: 24, ipVersion: 6, databaseType: "metadata", buildEpoch: nil)
        return MMDBReader(data: data, metadata: placeholder, searchTreeSize: 0, dataSectionStart: 0, ipv4StartNode: nil)
    }

    private nonisolated init(data: Data, metadata: MMDBMetadata, searchTreeSize: Int, dataSectionStart: Int, ipv4StartNode: UInt32?) {
        self.data = data
        self.metadata = metadata
        self.searchTreeSize = searchTreeSize
        self.dataSectionStart = dataSectionStart
        self.ipv4StartNode = ipv4StartNode
    }

    private nonisolated static func findIPv4StartNode(in data: Data, metadata: MMDBMetadata) -> UInt32 {
        let reader = MMDBReader(data: data, metadata: metadata, searchTreeSize: Int(metadata.nodeCount) * (metadata.recordSize / 4), dataSectionStart: 0, ipv4StartNode: nil)
        let prefixes: [[UInt8]] = [
            Array(repeating: 0, count: 10) + [0xFF, 0xFF],
            Array(repeating: 0, count: 12),
        ]

        for prefix in prefixes {
            var node: UInt32 = 0
            for bitIndex in 0..<96 {
                guard node < metadata.nodeCount else { break }
                let byte = prefix[bitIndex / 8]
                let bit = Int((byte >> (7 - (bitIndex % 8))) & 1)
                node = reader.readNode(nodeNumber: node, branch: bit)
            }

            if node != metadata.nodeCount {
                return node
            }
        }

        return metadata.nodeCount
    }

    private nonisolated static func renderNetwork(addressBytes: [UInt8], prefixLength: Int, family: ParsedIPAddress.Family) -> String {
        let masked = maskedAddress(addressBytes, prefixLength: prefixLength)
        let addressString = renderAddress(masked, family: family)
        return "\(addressString)/\(prefixLength)"
    }

    private nonisolated static func maskedAddress(_ addressBytes: [UInt8], prefixLength: Int) -> [UInt8] {
        var result = addressBytes
        let totalBits = result.count * 8
        guard prefixLength < totalBits else { return result }

        let wholeBytes = prefixLength / 8
        let remainder = prefixLength % 8

        if remainder == 0 {
            for index in wholeBytes..<result.count {
                result[index] = 0
            }
            return result
        }

        let mask = UInt8(0xFF) << UInt8(8 - remainder)
        result[wholeBytes] &= mask
        if wholeBytes + 1 < result.count {
            for index in (wholeBytes + 1)..<result.count {
                result[index] = 0
            }
        }
        return result
    }

    private nonisolated static func renderAddress(_ bytes: [UInt8], family: ParsedIPAddress.Family) -> String {
        switch family {
        case .ipv4:
            var address = in_addr()
            withUnsafeMutableBytes(of: &address.s_addr) { rawBuffer in
                rawBuffer.copyBytes(from: bytes)
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let success = withUnsafePointer(to: &address) { pointer in
                inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count))
            }
            return success.flatMap { _ in String(validatingUTF8: buffer) } ?? "0.0.0.0"

        case .ipv6:
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { rawBuffer in
                rawBuffer.copyBytes(from: bytes)
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let success = withUnsafePointer(to: &address) { pointer in
                inet_ntop(AF_INET6, pointer, &buffer, socklen_t(buffer.count))
            }
            return success.flatMap { _ in String(validatingUTF8: buffer) } ?? "::"
        }
    }
}

private enum ParsedIPAddress {
    enum Family {
        case ipv4
        case ipv6
    }

    case ipv4([UInt8])
    case ipv6([UInt8])

    nonisolated static func parse(_ string: String) throws -> ParsedIPAddress {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, string, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            return .ipv4(bytes)
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, string, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return .ipv6(bytes)
        }

        throw MMDBReaderError.invalidDatabase("invalid IP address")
    }
}
