#if !targetEnvironment(macCatalyst)

import CryptoKit
import Foundation
import OSLog

/// Relay client: connects to a croc relay server, authenticates, and joins a room.
/// Port of Go's `tcp.ConnectToTCPServer()`.
///
/// Protocol:
/// 1. TCP connect
/// 2. PAKE exchange with weak key [1,2,3] and "siec" curve → strong key
/// 3. Derive encryption key via PBKDF2 from strong key
/// 4. Send salt, then encrypted password
/// 5. Receive encrypted banner + "|||" + remote IP
/// 6. Send encrypted room name
/// 7. Receive "ok" confirmation
nonisolated enum CrocRelayClient {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocRelayClient")

    /// Result of connecting to a relay.
    struct RelayConnection: Sendable {
        let comm: CrocComm
        let banner: String
        let remoteIP: String
    }

    /// Connect to a croc relay server, authenticate, and join a room.
    /// - Parameters:
    ///   - address: Relay address in "host:port" format.
    ///   - password: Relay password (default: "pass123").
    ///   - room: Room name (SHA256 hash of code prefix).
    /// - Returns: An authenticated relay connection.
    static func connect(
        to address: String,
        password: String,
        room: String,
        options: CrocOptions,
        timeout: TimeInterval = CrocConstants.connectionTimeout
    ) async throws -> RelayConnection {
        try await withTaskCancellationHandler(operation: {
            // Parse host:port
            let (host, port) = try parseAddress(address)

            logger.debug("Connecting to relay \(host):\(port)")
            let comm = try await CrocComm.connect(to: host, port: port, timeout: timeout, options: options)

            func checkCancelled() throws {
                try Task.checkCancellation()
            }

            try checkCancelled()

            // PAKE exchange with relay using weak key
            let weakKey = Data(CrocConstants.relayWeakKey)
            let pake = try CrocPAKE(pw: weakKey, role: 0, curve: CrocConstants.relayCurve)

            // Send A's PAKE bytes
            try await comm.send(pake.bytes())
            try checkCancelled()

            // Receive B's PAKE bytes
            let bBytes = try await comm.receive()
            try checkCancelled()
            try pake.update(bBytes)

            guard let strongKey = pake.sessionKey else {
                throw CrocError.channelNotSecured
            }

            // Derive encryption key from PAKE session key
            let (encryptionKey, salt) = try CrocKeyDerivation.deriveKey(passphrase: strongKey)

            // Send salt
            try await comm.send(salt)
            try checkCancelled()

            // Send encrypted password
            let encryptedPassword = try CrocEncryption.encrypt(Data(password.utf8), key: encryptionKey)
            try await comm.send(encryptedPassword)
            try checkCancelled()

            // Receive encrypted response (banner|||ip)
            let encResponse = try await comm.receive()
            try checkCancelled()
            let responseData = try CrocEncryption.decrypt(encResponse, key: encryptionKey)
            guard let responseString = String(data: responseData, encoding: .utf8),
                  responseString.contains("|||") else {
                throw CrocError.relayAuthFailed
            }

            let parts = responseString.components(separatedBy: "|||")
            let banner = parts[0]
            let remoteIP = parts.count > 1 ? parts[1] : ""

            logger.debug("Relay authenticated. Banner: \(banner)")

            // Send encrypted room name
            let encryptedRoom = try CrocEncryption.encrypt(Data(room.utf8), key: encryptionKey)
            try await comm.send(encryptedRoom)
            try checkCancelled()

            // Receive room confirmation
            let encConfirmation = try await comm.receive()
            try checkCancelled()
            let confirmationData = try CrocEncryption.decrypt(encConfirmation, key: encryptionKey)
            guard confirmationData == Data("ok".utf8) else {
                let msg = String(data: confirmationData, encoding: .utf8) ?? "unknown"
                if msg.contains("room full") {
                    throw CrocError.relayFull
                }
                throw CrocError.protocolError("bad relay response: \(msg)")
            }

            logger.debug("Joined room successfully")

            return RelayConnection(comm: comm, banner: banner, remoteIP: remoteIP)
        }, onCancel: {
            // Underlying CrocComm operations already cancel their NWConnection on task cancellation.
        })
    }

    /// TCP-ping a relay: framed "ping" -> expect "pong".
    /// Port of Go's `tcp.PingServer`, used to verify a discovered LAN peer
    /// before committing to its local relay.
    static func ping(
        address: String,
        options: CrocOptions,
        timeout: TimeInterval = CrocConstants.localRelayConnectTimeout
    ) async -> Bool {
        do {
            let (host, port) = try parseAddress(address)
            let comm = try await CrocComm.connect(to: host, port: port, timeout: timeout, options: options)
            defer { comm.close() }
            try await comm.send(Data("ping".utf8))
            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await comm.receive() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw CrocError.connectionTimeout
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return response == Data("pong".utf8)
        } catch {
            return false
        }
    }

    /// Generate a room name from a shared secret.
    /// Matches Go's hashing: SHA256(code[:4] + "croc") as hex string.
    static func roomName(from sharedSecret: String) -> String {
        let prefix = String(sharedSecret.prefix(min(4, sharedSecret.count)))
        let input = prefix + "croc"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Parse "host:port" or "[host]:port" address string.
    private static func parseAddress(_ address: String) throws -> (host: String, port: UInt16) {
        // Handle IPv6 addresses like [::1]:9009
        if address.hasPrefix("[") {
            guard let closeBracket = address.firstIndex(of: "]") else {
                throw CrocError.connectionFailed("invalid address: \(address)")
            }
            let host = String(address[address.index(after: address.startIndex)..<closeBracket])
            let afterBracket = address[address.index(after: closeBracket)...]
            if afterBracket.hasPrefix(":"), let port = UInt16(afterBracket.dropFirst()) {
                return (host, port)
            }
            return (host, UInt16(CrocConstants.defaultPortInt))
        }

        // Handle host:port
        let parts = address.components(separatedBy: ":")
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (parts[0], port)
        }
        // Host only, use default port
        return (address, UInt16(CrocConstants.defaultPortInt))
    }
}

#endif
