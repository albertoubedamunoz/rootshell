//
//  MCPTCPServer.swift
//  rootshell
//
//  TCP server for MCP connections
//  Binds to localhost and accepts JSON-RPC connections
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
import os.log

/// TCP server for accepting MCP client connections
/// Based on patterns from PortForwardManager.LocalForwardListener
@MainActor
final class MCPTCPServer: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "MCPTCPServer")

    /// Whether the server is currently running
    @Published private(set) var isRunning = false

    /// The port the server is bound to (nil if not running)
    @Published private(set) var boundPort: Int?

    /// Active client connections
    @Published private(set) var clientCount: Int = 0

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var clientChannels: [ObjectIdentifier: Channel] = [:]

    /// Callback when a new client connects (returns handler for the client)
    var onClientConnected: (@MainActor (MCPClientConnection) -> Void)?

    /// Callback when a client disconnects
    var onClientDisconnected: (@MainActor (UUID) -> Void)?

    // MARK: - Server Lifecycle

    /// Start the server on the specified port
    /// Returns the actual bound port (useful when port is 0 for auto-assign)
    func start(port: Int = 0) async throws -> Int {
        guard !isRunning else {
            Self.logger.warning("Server already running on port \(self.boundPort ?? 0)")
            return boundPort ?? 0
        }

        Self.logger.info("Starting MCP TCP server on port \(port)")

        // Create event loop group for network I/O
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        eventLoopGroup = group

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    self?.initializeClientChannel(channel) ?? channel.eventLoop.makeSucceededVoidFuture()
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
                .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

            let channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            serverChannel = channel

            guard let localAddress = channel.localAddress, let actualPort = localAddress.port else {
                throw MCPTransportError.bindFailed("Could not determine bound port")
            }

            boundPort = actualPort
            isRunning = true

            Self.logger.info("MCP TCP server listening on 127.0.0.1:\(actualPort)")

            return actualPort
        } catch {
            Self.logger.error("Failed to start MCP TCP server: \(error.localizedDescription)")
            await cleanupEventLoop()
            throw MCPTransportError.bindFailed(error.localizedDescription)
        }
    }

    /// Stop the server and disconnect all clients
    func stop() async {
        guard isRunning else { return }

        Self.logger.info("Stopping MCP TCP server")

        // Close all client channels
        let channels = clientChannels.values
        clientChannels.removeAll()
        for channel in channels {
            try? await channel.close()
        }

        // Close server channel
        if let channel = serverChannel {
            try? await channel.close()
            serverChannel = nil
        }

        await cleanupEventLoop()

        boundPort = nil
        isRunning = false
        clientCount = 0

        Self.logger.info("MCP TCP server stopped")
    }

    private func cleanupEventLoop() async {
        if let group = eventLoopGroup {
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
        }
    }

    // MARK: - Client Channel Management

    private nonisolated func initializeClientChannel(_ channel: Channel) -> EventLoopFuture<Void> {
        let clientID = UUID()

        // Create the client connection wrapper
        // onMessage will be set up by MCPServer when connection is reported
        let connection = MCPClientConnection(
            id: clientID,
            channel: channel
        )

        // Create handler with callbacks that dispatch to MainActor
        let handler = MCPClientHandler(
            connection: connection,
            onConnect: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleClientConnected(clientID: clientID, channel: channel, connection: connection)
                }
            },
            onDisconnect: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.handleClientDisconnected(clientID: clientID)
                }
            }
        )

        // Add handler to the pipeline (handles both framing and message processing)
        return channel.pipeline.addHandler(handler)
    }

    private func handleClientConnected(clientID: UUID, channel: Channel, connection: MCPClientConnection) {
        Self.logger.info("Client connected: \(clientID.uuidString.prefix(8))")

        clientChannels[ObjectIdentifier(channel)] = channel
        clientCount = clientChannels.count

        onClientConnected?(connection)
    }

    private func handleClientDisconnected(clientID: UUID) {
        Self.logger.info("Client disconnected: \(clientID.uuidString.prefix(8))")

        // Find and remove the channel
        for (id, channel) in clientChannels {
            if !channel.isActive {
                clientChannels.removeValue(forKey: id)
            }
        }
        clientCount = clientChannels.count

        onClientDisconnected?(clientID)
    }
}

// MARK: - Transport Errors

enum MCPTransportError: LocalizedError {
    case bindFailed(String)
    case connectionFailed(String)
    case sendFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .bindFailed(let details):
            return "Failed to bind server: \(details)"
        case .connectionFailed(let details):
            return "Connection failed: \(details)"
        case .sendFailed(let details):
            return "Failed to send message: \(details)"
        case .notConnected:
            return "Not connected"
        }
    }
}

// MARK: - Client Connection

/// Represents a connected MCP client
/// Thread-safe wrapper around NIO channel for cross-actor communication
nonisolated final class MCPClientConnection: @unchecked Sendable {
    let id: UUID
    private let channel: Channel

    /// Callback for received messages - set by MCPServer on MainActor
    /// Access synchronized via channel's event loop
    private var _onMessage: (@Sendable (Data) -> Void)?

    init(id: UUID, channel: Channel) {
        self.id = id
        self.channel = channel
    }

    /// Set the message handler (called from MainActor context)
    func setMessageHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        _onMessage = handler
    }

    /// Send data to the client
    func send(_ data: Data) {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    /// Close the connection
    func close() {
        channel.close(promise: nil)
    }

    /// Whether the connection is active
    var isActive: Bool {
        channel.isActive
    }

    /// Receive data from the handler (called from NIO event loop)
    func receive(_ data: Data) {
        _onMessage?(data)
    }
}

// MARK: - NIO Handlers

/// Combined handler for JSON-RPC message framing and processing
/// Handles line-based framing (newline delimiters) and passes complete messages to connection
/// Note: NIO handlers run on event loop threads, not main actor
nonisolated final class MCPClientHandler: ChannelInboundHandler, ChannelOutboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let newline = UInt8(ascii: "\n")

    private let connection: MCPClientConnection
    private let onConnect: @Sendable () -> Void
    private let onDisconnect: @Sendable () -> Void

    /// Buffer for accumulating partial messages
    private var buffer: ByteBuffer?

    init(connection: MCPClientConnection, onConnect: @escaping @Sendable () -> Void, onDisconnect: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
    }

    func channelActive(context: ChannelHandlerContext) {
        onConnect()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onDisconnect()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inBuffer = unwrapInboundIn(data)

        // Append to existing buffer or use incoming buffer
        if buffer == nil {
            buffer = context.channel.allocator.buffer(capacity: inBuffer.readableBytes)
        }
        buffer?.writeBuffer(&inBuffer)

        // Process complete messages (newline-delimited)
        while let buf = buffer {
            guard let newlineIndex = buf.readableBytesView.firstIndex(of: Self.newline) else {
                break
            }

            let length = newlineIndex - buf.readableBytesView.startIndex

            // Read the message (excluding newline)
            if let messageBuffer = buffer?.readSlice(length: length) {
                // Skip the newline
                buffer?.moveReaderIndex(forwardBy: 1)

                // Convert to Data and pass to connection
                if var msgBuf = Optional(messageBuffer), let bytes = msgBuf.readBytes(length: msgBuf.readableBytes) {
                    let messageData = Data(bytes)
                    connection.receive(messageData)
                }
            }
        }

        // Clear buffer if empty
        if let buf = buffer, buf.readableBytes == 0 {
            buffer = nil
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var outBuffer = unwrapOutboundIn(data)

        // Add newline terminator
        outBuffer.writeInteger(Self.newline)

        context.write(wrapOutboundOut(outBuffer), promise: promise)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Log and close on error
        context.close(promise: nil)
    }
}
