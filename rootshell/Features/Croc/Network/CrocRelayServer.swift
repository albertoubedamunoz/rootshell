#if !targetEnvironment(macCatalyst)

import Foundation
import Network
import OSLog

/// Local relay server for LAN file transfers.
/// Port of Go's `tcp.Run()` / `server` struct.
///
/// The relay pairs two clients in a "room" and pipes data between them.
/// It authenticates clients using PAKE with weak key [1,2,3].
actor CrocRelayServer {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocRelayServer")

    private final class ListenerStartState: @unchecked Sendable {
        var resumed = false
    }

    private let host: String
    private let port: UInt16
    private let password: String
    /// Banner sent to clients after auth — comma-separated transfer port list.
    private let banner: String
    private var rooms: [String: RoomInfo] = [:]
    private var listener: NWListener?
    private var isCancelled = false

    struct RoomInfo {
        var first: CrocComm?
        var second: CrocComm?
        var opened: Date
        var full: Bool
    }

    init(host: String = "0.0.0.0", port: UInt16, password: String = CrocConstants.defaultPassphrase, banner: String = "") {
        self.host = host
        self.port = port
        self.password = password
        self.banner = banner
    }

    /// Start the relay server. Runs until cancelled.
    func start() async throws {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CrocError.connectionFailed("invalid port: \(port)")
        }
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        Self.logger.info("Starting local relay on \(self.host):\(self.port)")

        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleConnection(connection)
            }
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let stateLock = NSLock()
                let startState = ListenerStartState()

                listener.stateUpdateHandler = { state in
                    let shouldResume = stateLock.withLock { () -> Bool in
                        switch state {
                        case .ready, .failed, .cancelled:
                            guard !startState.resumed else { return false }
                            startState.resumed = true
                            return true
                        default:
                            return false
                        }
                    }
                    guard shouldResume else { return }

                    switch state {
                    case .ready:
                        continuation.resume()
                    case .failed(let error):
                        continuation.resume(throwing: CrocError.connectionFailed("local relay failed on \(self.port): \(error.localizedDescription)"))
                    case .cancelled:
                        continuation.resume(throwing: CrocError.cancelled)
                    default:
                        break
                    }
                }

                let queue = DispatchQueue(label: "com.rootshell.croc.relay")
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + CrocConstants.localRelayReadyTimeout) {
                    let shouldResume = stateLock.withLock { () -> Bool in
                        guard !startState.resumed else { return false }
                        startState.resumed = true
                        return true
                    }
                    guard shouldResume else { return }

                    continuation.resume(throwing: CrocError.connectionTimeout)
                }
            }
        }, onCancel: {
            listener.cancel()
        })

        // Room cleanup task
        Task {
            while !isCancelled {
                try? await Task.sleep(for: .seconds(CrocConstants.roomCleanupInterval))
                guard !isCancelled else { break }
                cleanupOldRooms()
            }
        }
    }

    /// Stop the relay server.
    func cancel() {
        isCancelled = true
        listener?.cancel()
        listener = nil
        for (_, room) in rooms {
            room.first?.close()
            room.second?.close()
        }
        rooms.removeAll()
    }

    // MARK: - Client Communication

    private func handleConnection(_ nwConnection: NWConnection) {
        let connection = CrocComm(connection: nwConnection)
        nwConnection.start(queue: DispatchQueue(label: "com.rootshell.croc.relay.conn"))

        Task {
            do {
                let room = try await clientCommunication(connection)
                if room == "ping" {
                    connection.close()
                    return
                }
                await waitForRoomPair(room: room, comm: connection)
            } catch {
                Self.logger.debug("Relay client error: \(error.localizedDescription)")
                connection.close()
            }
        }
    }

    /// Authenticate a client and assign them to a room.
    /// Port of Go's `server.clientCommunication()`.
    private func clientCommunication(_ c: CrocComm) async throws -> String {
        // PAKE as role 1 (server/B)
        let pake = try CrocPAKE(pw: Data(CrocConstants.relayWeakKey), role: 1, curve: CrocConstants.relayCurve)

        // Receive A's bytes
        let aBytes = try await c.receive()

        // Handle ping
        if aBytes == Data("ping".utf8) {
            try await c.send(Data("pong".utf8))
            return "ping"
        }

        try pake.update(aBytes)

        // Send B's bytes
        try await c.send(pake.bytes())

        guard let strongKey = pake.sessionKey else {
            throw CrocError.channelNotSecured
        }

        // Receive salt from client
        let salt = try await c.receive()

        // Derive encryption key
        let (encryptionKey, _) = try CrocKeyDerivation.deriveKey(passphrase: strongKey, salt: salt)

        // Receive encrypted password
        let encPassword = try await c.receive()
        let passwordData = try CrocEncryption.decrypt(encPassword, key: encryptionKey)
        guard String(data: passwordData, encoding: .utf8) == password else {
            throw CrocError.badPassword
        }

        // Send encrypted banner|||remoteIP
        // Banner is the comma-separated transfer port list (matches Go relay)
        let response = "\(banner)|||\(remoteAddress(for: c))"
        let encResponse = try CrocEncryption.encrypt(Data(response.utf8), key: encryptionKey)
        try await c.send(encResponse)

        // Receive encrypted room name
        let encRoom = try await c.receive()
        let roomData = try CrocEncryption.decrypt(encRoom, key: encryptionKey)
        guard let room = String(data: roomData, encoding: .utf8) else {
            throw CrocError.protocolError("invalid room name")
        }

        // Assign to room
        if rooms[room] == nil {
            rooms[room] = RoomInfo(first: c, second: nil, opened: Date(), full: false)
            let encOk = try CrocEncryption.encrypt(Data("ok".utf8), key: encryptionKey)
            try await c.send(encOk)
        } else if rooms[room]?.second == nil {
            rooms[room]?.second = c
            rooms[room]?.full = true
            let encOk = try CrocEncryption.encrypt(Data("ok".utf8), key: encryptionKey)
            try await c.send(encOk)

            if let roomInfo = rooms[room], let first = roomInfo.first, let second = roomInfo.second {
                Task { await self.startPiping(room: room, first: first, second: second) }
            }
        } else {
            let encFull = try CrocEncryption.encrypt(Data("room full".utf8), key: encryptionKey)
            try await c.send(encFull)
            throw CrocError.relayFull
        }

        return room
    }

    /// Wait for the room to fill, periodically probing the first connection.
    private func waitForRoomPair(room: String, comm: CrocComm) async {
        while !isCancelled {
            guard let roomInfo = rooms[room] else {
                return
            }
            if roomInfo.full {
                break
            }

            if let first = roomInfo.first {
                do {
                    try await first.send(Data([1]))
                } catch {
                    rooms.removeValue(forKey: room)
                    first.close()
                    roomInfo.second?.close()
                    return
                }
            }

            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func startPiping(room: String, first: CrocComm, second: CrocComm) async {
        guard rooms[room]?.full == true else {
            return
        }

        Self.logger.debug("Piping room: \(room)")

        async let pipe1: () = pipeData(from: first, to: second)
        async let pipe2: () = pipeData(from: second, to: first)
        _ = await (pipe1, pipe2)

        first.close()
        second.close()
        rooms.removeValue(forKey: room)
    }

    private func remoteAddress(for comm: CrocComm) -> String {
        switch comm.rawConnection.endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        default:
            return "127.0.0.1"
        }
    }

    /// Pipe data from one connection to another.
    private func pipeData(from source: CrocComm, to dest: CrocComm) async {
        while !isCancelled {
            do {
                let data = try await source.receive()
                try await dest.send(data)
            } catch {
                break
            }
        }
    }

    // MARK: - Room Cleanup

    private func cleanupOldRooms() {
        let now = Date()
        let ttl = CrocConstants.roomTTL
        for (name, info) in rooms {
            if now.timeIntervalSince(info.opened) > ttl {
                info.first?.close()
                info.second?.close()
                rooms.removeValue(forKey: name)
                Self.logger.debug("Cleaned up expired room: \(name)")
            }
        }
    }
}

#endif
