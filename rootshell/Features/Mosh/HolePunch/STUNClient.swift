//
//  STUNClient.swift
//  rootshell
//
//  STUN protocol client (RFC 5389) for NAT discovery
//

import Foundation
import Network
import OSLog

/// STUN protocol client for discovering public IP:port mapping
///
/// Implements RFC 5389 STUN Binding Request/Response to discover
/// the client's public IP address and port as seen through NAT.
///
/// Usage:
/// ```swift
/// let client = STUNClient()
/// let result = try await client.discover(localPort: 60001, addressFamily: .ipv4)
/// print("Public address: \(result.publicIP):\(result.publicPort)")
/// ```
@MainActor
final class STUNClient {

    // MARK: - Types

    /// Result of STUN discovery
    struct DiscoveryResult: Sendable, Equatable {
        /// The client's public IP address
        let publicIP: String

        /// The client's public UDP port
        let publicPort: UInt16

        /// The local port used for discovery
        let localPort: UInt16

        /// Whether symmetric NAT was detected
        /// Symmetric NAT assigns different mappings per destination,
        /// which can cause hole-punching to be less reliable
        let isSymmetricNAT: Bool

        /// The address family of the discovered mapping
        let addressFamily: AddressFamily
    }

    /// STUN-specific errors
    enum STUNError: LocalizedError, Sendable {
        case noServersAvailable
        case allServersFailed
        case invalidResponse(reason: String)
        case timeout
        case connectionFailed(reason: String)
        case bindFailed(port: UInt16, reason: String)
        case addressFamilyMismatch

        var errorDescription: String? {
            switch self {
            case .noServersAvailable:
                return "No STUN servers available"
            case .allServersFailed:
                return "All STUN servers failed"
            case .invalidResponse(let reason):
                return "Invalid STUN response: \(reason)"
            case .timeout:
                return "STUN request timed out"
            case .connectionFailed(let reason):
                return "STUN connection failed: \(reason)"
            case .bindFailed(let port, let reason):
                return "Failed to bind local port \(port): \(reason)"
            case .addressFamilyMismatch:
                return "Address family mismatch between request and response"
            }
        }
    }

    // MARK: - Properties

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "STUNClient"
    )

    /// Network dispatch queue
    private let networkQueue = DispatchQueue(
        label: "com.rootshell.stun.client",
        qos: .userInitiated
    )

    // MARK: - Public API

    /// Discovers the public IP:port mapping
    ///
    /// - Parameters:
    ///   - localPort: Specific local port to bind (nil = system assigned)
    ///   - addressFamily: Address family to discover (.auto will try IPv4 first)
    ///   - servers: STUN servers to query (nil = use defaults)
    ///   - timeout: Timeout per server in seconds
    /// - Returns: Discovery result with public address information
    /// - Throws: STUNError if discovery fails
    func discover(
        localPort: UInt16? = nil,
        addressFamily: AddressFamily = .auto,
        servers: [STUNServer]? = nil,
        timeout: TimeInterval = 3.0
    ) async throws -> DiscoveryResult {
        // Determine which servers to use
        let targetFamily = addressFamily == .auto ? AddressFamily.ipv4 : addressFamily
        let stunServers = servers ?? defaultServers(for: targetFamily)

        guard !stunServers.isEmpty else {
            throw STUNError.noServersAvailable
        }

        var lastError: Error = STUNError.allServersFailed

        // Try each server in order until one succeeds
        for server in stunServers {
            do {
                let result = try await queryServer(
                    server,
                    localPort: localPort,
                    addressFamily: targetFamily,
                    timeout: timeout
                )
                Self.logger.info("STUN discovery succeeded via \(server.host): \(result.publicIP):\(result.publicPort)")
                return result
            } catch {
                Self.logger.warning("STUN server \(server.host) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError
    }

    /// Detects symmetric NAT by querying two different STUN servers
    ///
    /// Symmetric NAT assigns different port mappings per destination.
    /// This is problematic for hole-punching because the mapping created
    /// by STUN discovery won't match what the server sees.
    ///
    /// - Parameters:
    ///   - localPort: The local port to test
    ///   - addressFamily: Address family to test
    /// - Returns: true if symmetric NAT is detected
    func detectSymmetricNAT(localPort: UInt16, addressFamily: AddressFamily) async -> Bool {
        let servers = defaultServers(for: addressFamily)
        guard servers.count >= 2 else { return false }

        do {
            // Query two different STUN servers from the same local port
            let result1 = try await queryServer(
                servers[0],
                localPort: localPort,
                addressFamily: addressFamily,
                timeout: 2.0
            )

            let result2 = try await queryServer(
                servers[1],
                localPort: localPort,
                addressFamily: addressFamily,
                timeout: 2.0
            )

            // If the public ports differ, it's symmetric NAT
            let isSymmetric = result1.publicPort != result2.publicPort
            if isSymmetric {
                Self.logger.warning("Symmetric NAT detected: port \(result1.publicPort) vs \(result2.publicPort)")
            }
            return isSymmetric

        } catch {
            Self.logger.warning("Symmetric NAT detection failed: \(error.localizedDescription)")
            return false  // Assume not symmetric if detection fails
        }
    }

    // MARK: - Private Methods

    /// Returns default STUN servers for the given address family
    private func defaultServers(for family: AddressFamily) -> [STUNServer] {
        switch family {
        case .auto, .ipv4:
            return STUNServer.defaultIPv4Servers
        case .ipv6:
            return STUNServer.defaultIPv6Servers
        }
    }

    /// Queries a single STUN server
    private func queryServer(
        _ server: STUNServer,
        localPort: UInt16?,
        addressFamily: AddressFamily,
        timeout: TimeInterval
    ) async throws -> DiscoveryResult {
        Self.logger.debug("Querying STUN server \(server.host):\(server.port)")

        // Create UDP endpoint
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(server.host),
            port: NWEndpoint.Port(rawValue: UInt16(server.port))!
        )

        // Configure UDP parameters with IP version constraint
        // This forces Network.framework to use IPv4 or IPv6 exclusively
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        // Force the IP version at the protocol level
        // This prevents dual-stack issues where hostname resolves to both but system chooses IPv6
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            switch addressFamily {
            case .ipv4, .auto:
                ipOptions.version = .v4
                Self.logger.info("STUN: Forcing IPv4 at protocol level")
            case .ipv6:
                ipOptions.version = .v6
                Self.logger.info("STUN: Forcing IPv6 at protocol level")
            }
        }

        // Also bind to the correct local address family for consistency
        let localHost: NWEndpoint.Host = switch addressFamily {
        case .ipv4, .auto: .ipv4(.any)
        case .ipv6: .ipv6(.any)
        }
        let localPortValue = localPort ?? 0
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: localHost,
            port: NWEndpoint.Port(rawValue: localPortValue)!
        )

        Self.logger.info("STUN query: addressFamily=\(addressFamily.rawValue), localPort=\(localPortValue)")

        // Create connection
        let connection = NWConnection(to: endpoint, using: parameters)

        // Generate transaction ID (12 random bytes)
        var transactionID = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 {
            transactionID[i] = UInt8.random(in: 0...255)
        }

        // Build STUN Binding Request
        let request = buildBindingRequest(transactionID: transactionID)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let resumeLock = NSLock()

            func safeResume(with result: Result<DiscoveryResult, Error>) {
                resumeLock.lock()
                defer { resumeLock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                connection.cancel()
                continuation.resume(with: result)
            }

            // Set up timeout
            let timeoutTask = Task { @MainActor in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                safeResume(with: .failure(STUNError.timeout))
            }

            // Handle state changes
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send the request
                    connection.send(content: request, completion: .contentProcessed { error in
                        if let error = error {
                            timeoutTask.cancel()
                            safeResume(with: .failure(STUNError.connectionFailed(reason: error.localizedDescription)))
                        }
                    })

                    // Receive the response
                    connection.receiveMessage { content, _, _, error in
                        timeoutTask.cancel()

                        if let error = error {
                            safeResume(with: .failure(STUNError.connectionFailed(reason: error.localizedDescription)))
                            return
                        }

                        guard let data = content else {
                            safeResume(with: .failure(STUNError.invalidResponse(reason: "No data received")))
                            return
                        }

                        // Parse response
                        do {
                            let (ip, port, family) = try self.parseBindingResponse(
                                data,
                                expectedTransactionID: transactionID
                            )

                            // Get actual local port used
                            var actualLocalPort: UInt16 = localPort ?? 0
                            if let localEndpoint = connection.currentPath?.localEndpoint,
                               case .hostPort(_, let connPort) = localEndpoint {
                                actualLocalPort = connPort.rawValue
                            }

                            let result = DiscoveryResult(
                                publicIP: ip,
                                publicPort: port,
                                localPort: actualLocalPort,
                                isSymmetricNAT: false,  // Detected separately
                                addressFamily: family
                            )
                            safeResume(with: .success(result))
                        } catch {
                            safeResume(with: .failure(error))
                        }
                    }

                case .failed(let error):
                    timeoutTask.cancel()
                    safeResume(with: .failure(STUNError.connectionFailed(reason: error.localizedDescription)))

                case .cancelled:
                    timeoutTask.cancel()

                default:
                    break
                }
            }

            // Start connection
            connection.start(queue: self.networkQueue)
        }
    }

    /// Builds a STUN Binding Request message
    /// Uses inline constants to avoid MainActor isolation issues with file-scope enums
    private nonisolated func buildBindingRequest(transactionID: [UInt8]) -> Data {
        // STUN constants (inline to avoid MainActor inference on file-scope enum)
        let headerSize = 20
        let bindingRequest: UInt16 = 0x0001
        let magicCookie: UInt32 = 0x2112A442

        var data = Data(capacity: headerSize)

        // Message Type: Binding Request (0x0001)
        data.append(contentsOf: bigEndianBytes(bindingRequest))

        // Message Length: 0 (no attributes)
        data.append(contentsOf: bigEndianBytes(UInt16(0)))

        // Magic Cookie
        data.append(contentsOf: bigEndianBytes(magicCookie))

        // Transaction ID (12 bytes)
        data.append(contentsOf: transactionID)

        return data
    }

    /// Parses a STUN Binding Response message
    /// Returns: (publicIP, publicPort, addressFamily)
    /// Uses inline constants to avoid MainActor isolation issues with file-scope enums
    private nonisolated func parseBindingResponse(
        _ data: Data,
        expectedTransactionID: [UInt8]
    ) throws -> (String, UInt16, AddressFamily) {
        // STUN constants (inline to avoid MainActor inference on file-scope enum)
        let headerSize = 20
        let magicCookieValue: UInt32 = 0x2112A442
        let bindingResponseType: UInt16 = 0x0101
        let attrXorMappedAddress: UInt16 = 0x0020
        let attrMappedAddress: UInt16 = 0x0001

        guard data.count >= headerSize else {
            throw STUNError.invalidResponse(reason: "Message too short: \(data.count) bytes")
        }

        let bytes = [UInt8](data)

        // Check message type
        let messageType = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard messageType == bindingResponseType else {
            throw STUNError.invalidResponse(reason: "Unexpected message type: 0x\(String(messageType, radix: 16))")
        }

        // Check magic cookie
        let cookie = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        guard cookie == magicCookieValue else {
            throw STUNError.invalidResponse(reason: "Invalid magic cookie")
        }

        // Check transaction ID
        let receivedID = Array(bytes[8..<20])
        guard receivedID == expectedTransactionID else {
            throw STUNError.invalidResponse(reason: "Transaction ID mismatch")
        }

        // Get message length
        let messageLength = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        guard data.count >= headerSize + messageLength else {
            throw STUNError.invalidResponse(reason: "Truncated message")
        }

        // Parse attributes looking for XOR-MAPPED-ADDRESS (preferred) or MAPPED-ADDRESS
        var offset = headerSize
        var mappedAddress: (String, UInt16, AddressFamily)?

        while offset + 4 <= headerSize + messageLength {
            let attrType = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let attrLength = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            offset += 4

            guard offset + attrLength <= data.count else {
                break
            }

            switch attrType {
            case attrXorMappedAddress:
                // Prefer XOR-MAPPED-ADDRESS
                let result = try parseXorMappedAddress(
                    bytes: bytes,
                    offset: offset,
                    length: attrLength
                )
                return result

            case attrMappedAddress:
                // Fall back to MAPPED-ADDRESS if no XOR version
                if mappedAddress == nil {
                    mappedAddress = try parseMappedAddress(
                        bytes: bytes,
                        offset: offset,
                        length: attrLength
                    )
                }

            default:
                break
            }

            // Move to next attribute (padded to 4-byte boundary)
            offset += (attrLength + 3) & ~3
        }

        // Return MAPPED-ADDRESS if found
        if let result = mappedAddress {
            return result
        }

        throw STUNError.invalidResponse(reason: "No address attribute found")
    }

    /// Parses XOR-MAPPED-ADDRESS attribute
    /// Uses inline constants to avoid MainActor isolation issues with file-scope enums
    private nonisolated func parseXorMappedAddress(
        bytes: [UInt8],
        offset: Int,
        length: Int
    ) throws -> (String, UInt16, AddressFamily) {
        // STUN constants (inline to avoid MainActor inference on file-scope enum)
        let magicCookie: UInt32 = 0x2112A442
        let familyIPv4: UInt8 = 0x01
        let familyIPv6: UInt8 = 0x02

        guard length >= 8 else {
            throw STUNError.invalidResponse(reason: "XOR-MAPPED-ADDRESS too short")
        }

        // Skip first byte (reserved)
        let family = bytes[offset + 1]

        // XOR port with top 16 bits of magic cookie
        let xorPort = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        let port = xorPort ^ UInt16(magicCookie >> 16)

        switch family {
        case familyIPv4:
            guard length >= 8 else {
                throw STUNError.invalidResponse(reason: "IPv4 XOR-MAPPED-ADDRESS too short")
            }
            // XOR address with magic cookie
            let xorAddr = UInt32(bytes[offset + 4]) << 24 |
                          UInt32(bytes[offset + 5]) << 16 |
                          UInt32(bytes[offset + 6]) << 8 |
                          UInt32(bytes[offset + 7])
            let addr = xorAddr ^ magicCookie
            let ip = "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
            return (ip, port, .ipv4)

        case familyIPv6:
            guard length >= 20 else {
                throw STUNError.invalidResponse(reason: "IPv6 XOR-MAPPED-ADDRESS too short")
            }
            // XOR address with magic cookie + transaction ID
            // Magic cookie (4 bytes) + transaction ID (12 bytes) = 16 bytes
            var xorKey = [UInt8](repeating: 0, count: 16)
            xorKey[0] = UInt8((magicCookie >> 24) & 0xFF)
            xorKey[1] = UInt8((magicCookie >> 16) & 0xFF)
            xorKey[2] = UInt8((magicCookie >> 8) & 0xFF)
            xorKey[3] = UInt8(magicCookie & 0xFF)
            for i in 0..<12 {
                xorKey[4 + i] = bytes[8 + i]  // Transaction ID from header
            }

            var ipv6Parts = [UInt16](repeating: 0, count: 8)
            for i in 0..<8 {
                let xorByte1 = bytes[offset + 4 + i * 2] ^ xorKey[i * 2]
                let xorByte2 = bytes[offset + 5 + i * 2] ^ xorKey[i * 2 + 1]
                ipv6Parts[i] = UInt16(xorByte1) << 8 | UInt16(xorByte2)
            }

            let ip = ipv6Parts.map { String($0, radix: 16) }.joined(separator: ":")
            return (ip, port, .ipv6)

        default:
            throw STUNError.invalidResponse(reason: "Unknown address family: \(family)")
        }
    }

    /// Parses MAPPED-ADDRESS attribute (non-XOR version)
    /// Uses inline constants to avoid MainActor isolation issues with file-scope enums
    private nonisolated func parseMappedAddress(
        bytes: [UInt8],
        offset: Int,
        length: Int
    ) throws -> (String, UInt16, AddressFamily) {
        // STUN constants (inline to avoid MainActor inference on file-scope enum)
        let familyIPv4: UInt8 = 0x01
        let familyIPv6: UInt8 = 0x02

        guard length >= 8 else {
            throw STUNError.invalidResponse(reason: "MAPPED-ADDRESS too short")
        }

        // Skip first byte (reserved)
        let family = bytes[offset + 1]
        let port = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])

        switch family {
        case familyIPv4:
            let ip = "\(bytes[offset + 4]).\(bytes[offset + 5]).\(bytes[offset + 6]).\(bytes[offset + 7])"
            return (ip, port, .ipv4)

        case familyIPv6:
            guard length >= 20 else {
                throw STUNError.invalidResponse(reason: "IPv6 MAPPED-ADDRESS too short")
            }
            var ipv6Parts = [UInt16](repeating: 0, count: 8)
            for i in 0..<8 {
                ipv6Parts[i] = UInt16(bytes[offset + 4 + i * 2]) << 8 | UInt16(bytes[offset + 5 + i * 2])
            }
            let ip = ipv6Parts.map { String($0, radix: 16) }.joined(separator: ":")
            return (ip, port, .ipv6)

        default:
            throw STUNError.invalidResponse(reason: "Unknown address family: \(family)")
        }
    }
}

// MARK: - Helpers

/// Helper to convert UInt16 to big-endian bytes
/// Nonisolated to allow use from nonisolated contexts
private nonisolated func bigEndianBytes(_ value: UInt16) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

/// Helper to convert UInt32 to big-endian bytes
/// Nonisolated to allow use from nonisolated contexts
private nonisolated func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}
