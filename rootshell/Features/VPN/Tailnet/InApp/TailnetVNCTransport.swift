//
//  TailnetVNCTransport.swift
//  rootshell
//
//  VNC over in-app Tailscale: the RFB byte stream on a tailnet socket, plus
//  datagram sockets for High Performance media. Created once per connection
//  attempt by the package's transportProvider.
//

#if !CHINA_BUILD

import Foundation
import NIOCore
import NIOPosix
import RFBProtocol
import RFBTransport
import os
import rootshellVNC

actor TailnetVNCTransport: RFBConnection {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TailnetVNCTransport")

    private let host: String
    private let port: UInt16
    private var channel: Channel?
    private var pipe: NIOChannelBytePipe?
    private var closed = false
    private var disconnectHandler: (@Sendable (VNCProtocolError) -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Opens the UDP media sockets High Performance mode asks for.
    static let datagramProvider: VNCDatagramProvider = { host, remotePort, localPort in
        try await TailnetGo.dialUDP(host: host, remotePort: Int(remotePort), localPort: Int(localPort))
    }

    func connect() async throws {
        guard !closed else { throw VNCProtocolError.connectionClosed }
        guard channel == nil else { throw VNCProtocolError.ioError("Tailscale transport already connected") }
        let fd: Int32
        do {
            fd = try await TailnetGo.dialTCP(host: host, port: Int(port), timeout: .seconds(20))
        } catch {
            throw VNCProtocolError.ioError("Tailscale connect failed: \(error.localizedDescription)")
        }
        let pipeBox = OSAllocatedUnfairLock<NIOChannelBytePipe?>(initialState: nil)
        let channel: Channel
        do {
            channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    do {
                        let pipe = try NIOChannelBytePipe.install(on: channel)
                        pipeBox.withLock { $0 = pipe }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .takingOwnershipOfDescriptor(inputOutput: fd)
                .get()
        } catch {
            Darwin.close(fd)
            throw VNCProtocolError.ioError("Tailscale channel failed: \(error.localizedDescription)")
        }
        guard let pipe = pipeBox.withLock({ $0 }) else {
            try? await channel.close()
            throw VNCProtocolError.ioError("Tailscale pipe was not installed")
        }
        if closed {
            try? await channel.close()
            throw VNCProtocolError.connectionClosed
        }
        self.channel = channel
        self.pipe = pipe
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            Task { await self.handleChannelClosed() }
        }
        Self.logger.info("VNC over Tailscale connected to \(self.host):\(self.port)")
    }

    func read(exactly count: Int) async throws -> Data {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        do {
            return try await pipe.readExactly(count)
        } catch is NIOChannelBytePipeError {
            throw VNCProtocolError.connectionClosed
        } catch {
            throw closed ? VNCProtocolError.connectionClosed : VNCProtocolError.ioError("Tailscale read failed: \(error.localizedDescription)")
        }
    }

    func read(upTo maxCount: Int) async throws -> Data {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        let data: Data?
        do {
            data = try await pipe.read(maxBytes: maxCount)
        } catch {
            throw closed ? VNCProtocolError.connectionClosed : VNCProtocolError.ioError("Tailscale read failed: \(error.localizedDescription)")
        }
        guard let data, !data.isEmpty else { throw VNCProtocolError.connectionClosed }
        return data
    }

    func send(_ data: Data) async throws {
        guard !closed, let pipe else { throw VNCProtocolError.connectionClosed }
        do {
            try await pipe.write(data)
        } catch {
            throw closed ? VNCProtocolError.connectionClosed : VNCProtocolError.ioError("Tailscale write failed: \(error.localizedDescription)")
        }
    }

    func close() async {
        if closed { return }
        closed = true
        let channel = self.channel
        self.channel = nil
        self.pipe = nil
        disconnectHandler = nil
        if let channel {
            try? await withTimeout(seconds: 2) { try? await channel.close() }
        }
    }

    func setDisconnectHandler(_ handler: (@Sendable (VNCProtocolError) -> Void)?) async {
        disconnectHandler = handler
    }

    /// The tailnet address, so UDP media targets the same peer as the stream.
    func remoteEndpointHost() async -> String? { host }

    private func handleChannelClosed() {
        guard !closed else { return }
        Self.logger.info("VNC over Tailscale closed by remote")
        disconnectHandler?(.connectionClosed)
    }
}

#endif
