#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import Network
import OSLog

/// Framed TCP communication matching Go's `comm.Comm`.
///
/// Wire format: `["croc" (4 bytes)][payload length u32 LE (4 bytes)][payload]`
///
/// Uses Network.framework `NWConnection` for TCP on iOS.
nonisolated final class CrocComm: @unchecked Sendable {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocComm")

    private final class ConnectionAttemptState: @unchecked Sendable {
        var resumed = false
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.rootshell.croc.comm")
    private var isClosed = false

    /// Create a CrocComm wrapping an existing NWConnection.
    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connect to a TCP address and return a CrocComm.
    static func connect(
        to host: String,
        port: UInt16,
        timeout: TimeInterval = CrocConstants.connectionTimeout,
        options: CrocOptions
    ) async throws -> CrocComm {
        let resolvedHost = try await resolvedHost(for: host, options: options)
        let addressString = "\(host):\(port)"

        if !options.socks5Proxy.isEmpty && !CrocFileUtils.isLocalIP(host) && host != "localhost" {
            let connection = try await connectDirect(to: options.socks5Proxy, timeout: timeout, options: options)
            try await performSOCKS5Handshake(on: connection, targetHost: resolvedHost ?? host, targetPort: port)
            return CrocComm(connection: connection)
        }

        if !options.httpProxy.isEmpty && !CrocFileUtils.isLocalIP(host) && host != "localhost" {
            let connection = try await connectDirect(to: options.httpProxy, timeout: timeout, options: options)
            try await performHTTPConnectHandshake(on: connection, targetHost: resolvedHost ?? host, targetPort: port)
            return CrocComm(connection: connection)
        }

        let directAddress = netJoinHostPort(host: resolvedHost ?? host, port: port)
        let connection = try await connectDirect(to: directAddress, timeout: timeout, options: options)
        Self.logger.debug("Connected to \(addressString)")
        return CrocComm(connection: connection)
    }

    private static func resolvedHost(for host: String, options: CrocOptions) async throws -> String? {
        guard options.internalDNS, !CrocFileUtils.isLocalIP(host), host != "localhost", !host.contains(":") else {
            return nil
        }
        return await CrocDNSResolver.resolve(host, preferIPv6: false)
    }

    private static func connectDirect(to address: String, timeout: TimeInterval, options: CrocOptions) async throws -> NWConnection {
        let (host, port) = try parseAddress(address)
        let resolvedHost = try await resolvedHost(for: host, options: options)
        let nwHost = NWEndpoint.Host(resolvedHost ?? host)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let params = NWParameters.tcp
        let connection = NWConnection(host: nwHost, port: nwPort, using: params)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let resumeLock = NSLock()
                let attemptState = ConnectionAttemptState()

                connection.stateUpdateHandler = { (state: NWConnection.State) in
                    let shouldResume = resumeLock.withLock { () -> Bool in
                        switch state {
                        case .ready, .failed, .cancelled:
                            guard !attemptState.resumed else { return false }
                            attemptState.resumed = true
                            return true
                        default:
                            return false
                        }
                    }
                    guard shouldResume else { return }

                    switch state {
                    case .ready:
                        continuation.resume(returning: connection)
                    case .failed(let error):
                        continuation.resume(throwing: CrocError.connectionFailed("\(address) — \(error)"))
                    case .cancelled:
                        continuation.resume(throwing: CrocError.cancelled)
                    default:
                        break
                    }
                }

                let queue = DispatchQueue(label: "com.rootshell.croc.connect")
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    let shouldResume = resumeLock.withLock { () -> Bool in
                        guard !attemptState.resumed else { return false }
                        attemptState.resumed = true
                        return true
                    }
                    guard shouldResume else { return }

                    connection.cancel()
                    continuation.resume(throwing: CrocError.connectionTimeout)
                }
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    private static func performSOCKS5Handshake(on connection: NWConnection, targetHost: String, targetPort: UInt16) async throws {
        try await sendRaw(Data([0x05, 0x01, 0x00]), on: connection)
        let greeting = try await readExact(count: 2, from: connection)
        guard greeting == Data([0x05, 0x00]) else {
            throw CrocError.connectionFailed("SOCKS5 proxy authentication failed")
        }

        var request = Data([0x05, 0x01, 0x00])
        if let ipv4 = ipv4Bytes(for: targetHost) {
            request.append(0x01)
            request.append(ipv4)
        } else if let ipv6 = ipv6Bytes(for: targetHost) {
            request.append(0x04)
            request.append(ipv6)
        } else {
            let hostData = Data(targetHost.utf8)
            request.append(0x03)
            request.append(UInt8(hostData.count))
            request.append(hostData)
        }

        request.append(UInt8((targetPort >> 8) & 0xFF))
        request.append(UInt8(targetPort & 0xFF))
        try await sendRaw(request, on: connection)

        let responseHeader = try await readExact(count: 4, from: connection)
        guard responseHeader[1] == 0x00 else {
            throw CrocError.connectionFailed("SOCKS5 CONNECT failed")
        }

        let atyp = responseHeader[3]
        switch atyp {
        case 0x01:
            _ = try await readExact(count: 4 + 2, from: connection)
        case 0x04:
            _ = try await readExact(count: 16 + 2, from: connection)
        case 0x03:
            let length = Int(try await readExact(count: 1, from: connection)[0])
            _ = try await readExact(count: length + 2, from: connection)
        default:
            throw CrocError.connectionFailed("unsupported SOCKS5 address type")
        }
    }

    private static func performHTTPConnectHandshake(on connection: NWConnection, targetHost: String, targetPort: UInt16) async throws {
        let connectRequest = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\n\r\n"
        try await sendRaw(Data(connectRequest.utf8), on: connection)
        let response = try await readUntilDoubleCRLF(from: connection)
        guard let responseText = String(data: response, encoding: .utf8),
              responseText.contains(" 200 ") || responseText.hasPrefix("HTTP/1.1 200") || responseText.hasPrefix("HTTP/1.0 200") else {
            throw CrocError.connectionFailed("HTTP CONNECT failed")
        }
    }

    private static func sendRaw(_ payload: Data, on connection: NWConnection) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: CrocError.ioError(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    private static func readExact(count: Int, from connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while accumulated.count < count {
            let remaining = count - accumulated.count
            let chunk = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: CrocError.ioError(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        } else {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        }
                    }
                }
            }, onCancel: {
                connection.cancel()
            })
            accumulated.append(chunk)
        }
        return accumulated
    }

    private static func readUntilDoubleCRLF(from connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while !accumulated.contains(Data("\r\n\r\n".utf8)) {
            let chunk = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: CrocError.ioError(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        } else {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        }
                    }
                }
            }, onCancel: {
                connection.cancel()
            })
            accumulated.append(chunk)
        }
        return accumulated
    }

    private static func parseAddress(_ address: String) throws -> (host: String, port: UInt16) {
        if address.hasPrefix("[") {
            guard let closeBracket = address.firstIndex(of: "]") else {
                throw CrocError.connectionFailed("invalid address: \(address)")
            }
            let host = String(address[address.index(after: address.startIndex)..<closeBracket])
            let portString = address[address.index(after: closeBracket)...].dropFirst()
            return (host, UInt16(portString) ?? UInt16(CrocConstants.defaultPortInt))
        }
        let parts = address.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts.first ?? address
        let port = parts.count > 1 ? UInt16(parts[1]) ?? UInt16(CrocConstants.defaultPortInt) : UInt16(CrocConstants.defaultPortInt)
        return (host, port)
    }

    private static func netJoinHostPort(host: String, port: UInt16) -> String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    private static func ipv4Bytes(for host: String) -> Data? {
        let components = host.split(separator: ".")
        guard components.count == 4 else { return nil }
        var bytes = Data()
        for component in components {
            guard let value = UInt8(component) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    private static func ipv6Bytes(for host: String) -> Data? {
        var storage = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &storage) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: storage) { Data($0) }
    }

    // MARK: - Send

    /// Send a framed message: magic + u32 LE length + payload.
    func send(_ payload: Data) async throws {
        var frame = Data()
        frame.append(CrocConstants.magic) // "croc" (4 bytes)
        var length = UInt32(payload.count).littleEndian
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: CrocError.ioError(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    // MARK: - Receive

    /// Receive a framed message: read magic, length, then payload.
    func receive() async throws -> Data {
        // Read magic bytes (4)
        let magic = try await readExact(count: 4)
        guard magic == CrocConstants.magic else {
            throw CrocError.invalidMagic
        }

        // Read length (4 bytes, u32 LE)
        let lengthData = try await readExact(count: 4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let payloadLength = UInt32(littleEndian: length)

        guard payloadLength <= CrocConstants.maxReadMessageSize else {
            throw CrocError.messageTooLarge(Int(payloadLength))
        }

        // Read payload
        return try await readExact(count: Int(payloadLength))
    }

    /// Receive a framed message, skipping relay keepalive probes.
    /// The Go relay sends single-byte `[0x01]` messages as keepalives while
    /// waiting for the second peer to join. These must be silently consumed.
    func receiveSkippingProbes() async throws -> Data {
        while true {
            let data = try await receive()
            // Relay keepalive: exactly 1 byte with value 0x01
            if data.count == 1 && data[0] == 1 {
                continue
            }
            return data
        }
    }

    // MARK: - Raw Read

    /// Read exactly `count` bytes from the connection, accumulating partial reads.
    /// NWConnection.receive may return fewer bytes than requested on TCP;
    /// we must loop until the full count is satisfied.
    private func readExact(count: Int) async throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)

        while accumulated.count < count {
            let remaining = count - accumulated.count
            let chunk: Data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                        if let error {
                            continuation.resume(throwing: CrocError.ioError(error.localizedDescription))
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else if isComplete {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        } else {
                            continuation.resume(throwing: CrocError.peerDisconnected)
                        }
                    }
                }
            }, onCancel: {
                connection.cancel()
            })
            accumulated.append(chunk)
        }

        return accumulated
    }

    // MARK: - Close

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
    }

    /// The underlying NWConnection.
    var rawConnection: NWConnection { connection }
}

#endif
