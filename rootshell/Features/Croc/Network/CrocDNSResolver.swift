#if !targetEnvironment(macCatalyst)

import Foundation
import Network
import os

nonisolated enum CrocDNSResolver {
    static func resolve(_ host: String, preferIPv6: Bool) async -> String? {
        let recordTypes: [UInt16] = preferIPv6 ? [28, 1] : [1, 28]

        for server in CrocConstants.publicDNS {
            let dnsServer = server.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            for recordType in recordTypes {
                if let resolved = try? await query(host: host, server: dnsServer, recordType: recordType) {
                    return resolved
                }
            }
        }

        return nil
    }

    private static func query(host: String, server: String, recordType: UInt16) async throws -> String {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let packet = try buildQuery(host: host, recordType: recordType)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // State updates arrive on the connection's own queue, so the
                // resume-once guard needs real mutual exclusion.
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let claim: @Sendable () -> Bool = {
                    resumed.withLock { alreadyResumed in
                        if alreadyResumed { return false }
                        alreadyResumed = true
                        return true
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if claim() { continuation.resume() }
                    case .failed(let error):
                        if claim() { continuation.resume(throwing: error) }
                    case .cancelled:
                        if claim() { continuation.resume(throwing: CrocError.cancelled) }
                    default:
                        break
                    }
                }
                connection.start(queue: DispatchQueue(label: "com.rootshell.croc.dns"))
            }
        }, onCancel: {
            connection.cancel()
        })

        defer { connection.cancel() }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }, onCancel: {
            connection.cancel()
        })

        let response = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receiveMessage { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: CrocError.connectionTimeout)
                    }
                }
            }
        }, onCancel: {
            connection.cancel()
        })

        guard let parsed = parseResponse(response, recordType: recordType) else {
            throw CrocError.connectionFailed("failed to resolve \(host)")
        }
        return parsed
    }

    private static func buildQuery(host: String, recordType: UInt16) throws -> Data {
        var data = Data()
        let identifier = UInt16.random(in: 0...UInt16.max)
        appendUInt16(identifier, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)

        for label in host.split(separator: ".") {
            guard let count = UInt8(exactly: label.count) else {
                throw CrocError.invalidMessage("invalid dns label")
            }
            data.append(count)
            data.append(Data(label.utf8))
        }
        data.append(0)
        appendUInt16(recordType, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    private static func parseResponse(_ data: Data, recordType: UInt16) -> String? {
        guard data.count >= 12 else { return nil }
        let answerCount = Int(readUInt16(from: data, at: 6))
        var offset = 12

        while offset < data.count, data[offset] != 0 {
            offset += Int(data[offset]) + 1
        }
        offset += 5

        for _ in 0..<answerCount {
            guard offset + 12 <= data.count else { return nil }
            offset = skipName(in: data, from: offset)
            let type = readUInt16(from: data, at: offset)
            offset += 2
            _ = readUInt16(from: data, at: offset)
            offset += 2
            offset += 4
            let rdLength = Int(readUInt16(from: data, at: offset))
            offset += 2
            guard offset + rdLength <= data.count else { return nil }

            if type == recordType {
                if recordType == 1, rdLength == 4 {
                    return data[offset..<(offset + 4)].map(String.init).joined(separator: ".")
                }
                if recordType == 28, rdLength == 16 {
                    var parts: [String] = []
                    for index in stride(from: offset, to: offset + 16, by: 2) {
                        let value = readUInt16(from: data, at: index)
                        parts.append(String(value, radix: 16))
                    }
                    return parts.joined(separator: ":")
                }
            }

            offset += rdLength
        }

        return nil
    }

    private static func skipName(in data: Data, from offset: Int) -> Int {
        guard offset < data.count else { return offset }
        if data[offset] & 0xC0 == 0xC0 {
            return offset + 2
        }

        var current = offset
        while current < data.count, data[current] != 0 {
            current += Int(data[current]) + 1
        }
        return current + 1
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var bigEndian = value.bigEndian
        data.append(Data(bytes: &bigEndian, count: 2))
    }

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        let high = UInt16(data[offset]) << 8
        let low = UInt16(data[offset + 1])
        return high | low
    }
}

#endif
