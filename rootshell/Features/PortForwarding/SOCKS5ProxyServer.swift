//
//  SOCKS5ProxyServer.swift
//  rootshell
//
//  SOCKS5 proxy server for SSH session dynamic port forwarding (-D).
//  Binds to localhost, routes connections through Citadel DirectTCPIP channels.
//

import Foundation
@preconcurrency import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import os.log

/// Thread-safe limiter for active SOCKS5 forwarding connections.
nonisolated final class SOCKS5ConnectionLimiter: @unchecked Sendable {
    private let maxConnections: Int
    private let lock = NSLock()
    private var activeConnections = 0

    init(maxConnections: Int = 128) {
        self.maxConnections = maxConnections
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < maxConnections else { return false }
        activeConnections += 1
        return true
    }

    func release() {
        lock.lock()
        if activeConnections > 0 {
            activeConnections -= 1
        }
        lock.unlock()
    }
}

/// Thread-safe one-shot action — ensures a closure runs exactly once.
private nonisolated final class OneShotRelease: @unchecked Sendable {
    private var action: (@Sendable () -> Void)?
    private let lock = NSLock()

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func run() {
        lock.lock()
        let a = action
        action = nil
        lock.unlock()
        a?()
    }
}

/// Thread-safe one-shot flag for racing channel creation against a timeout.
private nonisolated final class ChannelCreationRace: @unchecked Sendable {
    private var completed = false
    private let lock = NSLock()

    func tryComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}

/// SOCKS5 proxy server for SSH session port forwarding.
/// Binds to localhost, routes SOCKS5 CONNECT requests through Citadel DirectTCPIP channels.
nonisolated final class SOCKS5ProxyServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "SOCKS5ProxyServer")
    private static let channelCreationTimeoutSeconds = 10.0

    private let sshClient: SSHClient
    private let connectionLimiter = SOCKS5ConnectionLimiter()
    private var serverChannel: Channel?
    private var boundHost: String = "127.0.0.1"
    private var boundPort: Int = 0

    init(sshClient: SSHClient) {
        self.sshClient = sshClient
    }

    /// Start SOCKS5 proxy on the specified host and port. Returns the actual bound port.
    func start(host bindHost: String = "127.0.0.1", port: Int) async throws -> Int {
        let client = sshClient
        let limiter = connectionLimiter
        let effectiveHost = bindHost.isEmpty ? "127.0.0.1" : bindHost

        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { childChannel in
                let handler = SOCKS5Handler(
                    onConnect: { host, port, ctx, handler in
                        Self.handleConnect(
                            host: host, port: port,
                            context: ctx, handler: handler,
                            client: client, limiter: limiter
                        )
                    }
                )
                return childChannel.pipeline.addHandler(handler)
            }
            .bind(host: effectiveHost, port: port)
            .get()

        self.serverChannel = channel

        guard let localAddress = channel.localAddress, let actualPort = localAddress.port else {
            throw PortForwardError.bindFailed(
                port: port,
                underlying: PortForwardError.invalidConfiguration("Could not determine bound port")
            )
        }

        self.boundHost = effectiveHost
        self.boundPort = actualPort
        Self.logger.info("SOCKS5 proxy started on \(effectiveHost):\(actualPort)")
        return actualPort
    }

    /// Stop the proxy and close all connections.
    func stop() async {
        if let channel = serverChannel {
            try? await channel.close()
            serverChannel = nil
        }
        Self.logger.info("SOCKS5 proxy stopped")
    }

    var address: String { "\(boundHost):\(boundPort)" }

    // MARK: - Connection Handling

    /// Handle a SOCKS5 CONNECT request by creating a DirectTCPIP channel through SSH.
    private static func handleConnect(
        host: String,
        port: Int,
        context: ChannelHandlerContext,
        handler: SOCKS5Handler,
        client: SSHClient,
        limiter: SOCKS5ConnectionLimiter
    ) {
        guard limiter.tryAcquire() else {
            logger.warning("SOCKS5 connection limit reached, refusing \(host):\(port)")
            handler.sendReply(context: context, status: 0x05) // connection refused
            return
        }

        let timeout = channelCreationTimeoutSeconds
        // context is only accessed on its event loop; safe across Task boundaries.
        nonisolated(unsafe) let ctx = context
        let socks5Handler = handler

        Task {
            let releaseOnce = OneShotRelease { limiter.release() }
            do {
                let originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                // Use ChannelBridge (not GlueHandler) because the SOCKS client channel
                // (SelectableEventLoop) and SSH channel (NIOTSEventLoop) may be on
                // different event loops. ChannelBridge handles cross-EL bridging safely.
                let (localGlue, sshGlue) = ChannelBridge.matchedPair(onClose: {
                    releaseOnce.run()
                })

                // Race channel creation against a timeout
                let sshChannel: Channel = try await withCheckedThrowingContinuation { continuation in
                    let race = ChannelCreationRace()

                    Task {
                        do {
                            let ch = try await client.createDirectTCPIPChannel(
                                using: .init(
                                    targetHost: host,
                                    targetPort: port,
                                    originatorAddress: originatorAddress
                                )
                            ) { channel in
                                return channel.pipeline.addHandler(sshGlue)
                            }
                            if race.tryComplete() {
                                continuation.resume(returning: ch)
                            } else {
                                ch.close(promise: nil)
                            }
                        } catch {
                            if race.tryComplete() {
                                continuation.resume(throwing: error)
                            }
                        }
                    }

                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        if race.tryComplete() {
                            continuation.resume(throwing: PortForwardError.connectionFailed(
                                target: "\(host):\(port)",
                                underlying: NSError(
                                    domain: "SOCKS5",
                                    code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Channel creation timed out"]
                                )
                            ))
                        }
                    }
                }

                // Install bridge handler, send success reply, remove SOCKS5 handler.
                // ChannelBridge.onClose will release the limiter when the connection ends.
                _ = try await ctx.eventLoop.submit {
                    let ready = ctx.eventLoop.makePromise(of: Void.self)
                    ctx.pipeline.addHandler(localGlue).flatMap {
                        socks5Handler.transitionToForwarding()
                        socks5Handler.sendReply(context: ctx, status: 0x00)
                        return ctx.pipeline.removeHandler(socks5Handler)
                    }.whenComplete { result in
                        switch result {
                        case .success:
                            ready.succeed(())
                        case .failure(let error):
                            logger.error("Failed to activate SOCKS5 forwarding: \(error)")
                            // Release limiter via one-shot — safe even if ChannelBridge
                            // onClose also fires (won't double-release).
                            releaseOnce.run()
                            if sshChannel.isActive {
                                sshChannel.close(promise: nil)
                            }
                            ctx.close(promise: nil)
                            ready.fail(error)
                        }
                    }
                    return ready.futureResult
                }.get()

            } catch {
                logger.error("DirectTCPIP to \(host):\(port) failed: \(error)")
                releaseOnce.run()
                _ = try? await ctx.eventLoop.submit {
                    socks5Handler.sendReply(context: ctx, status: 0x05) // connection refused
                }.get()
            }
        }
    }
}
