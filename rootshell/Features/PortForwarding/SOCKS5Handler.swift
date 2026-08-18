//
//  SOCKS5Handler.swift
//  rootshell
//
//  Reusable SOCKS5 protocol handler.
//  Handles method negotiation and CONNECT request parsing.
//  Delegates actual connection creation to an onConnect closure.
//
//  Shared between the main app (SOCKS5ProxyServer) and VPN extension (VPNSOCKS5Proxy).
//

import Foundation
import NIOCore

/// Reusable SOCKS5 protocol handler.
/// Handles SOCKS5 method negotiation and CONNECT request parsing.
/// Delegates actual connection creation to the `onConnect` closure.
nonisolated final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Called when a CONNECT request is parsed. The handler should:
    /// 1. Create the remote connection
    /// 2. Call `sendReply(context:status:)` with 0x00 on success or error code on failure
    /// 3. Install bridge handlers on the channel
    /// 4. Call `transitionToForwarding()` on success
    typealias ConnectHandler = @Sendable (
        _ host: String, _ port: Int, _ context: ChannelHandlerContext, _ handler: SOCKS5Handler
    ) -> Void

    /// Optional delegate for metrics/logging.
    /// VPN extension provides one wrapping VPNSOCKS5DebugMetrics; main app passes nil.
    protocol Delegate: Sendable {
        func didReadChannel()
        func didNegotiateMethod(success: Bool)
        func didReceiveConnect(host: String, port: Int)
        func didActivateForwarding(host: String, port: Int)
        func didError(_ message: String)
    }

    private let onConnect: ConnectHandler
    private let delegate: (any Delegate)?
    private var state: State = .waitingMethodNegotiation

    private enum State {
        case waitingMethodNegotiation
        case waitingConnectRequest
        case forwarding
        case failed
    }

    init(onConnect: @escaping ConnectHandler, delegate: (any Delegate)? = nil) {
        self.onConnect = onConnect
        self.delegate = delegate
    }

    // MARK: - ChannelInboundHandler

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        delegate?.didReadChannel()
        switch state {
        case .waitingMethodNegotiation:
            var buffer = unwrapInboundIn(data)
            handleMethodNegotiation(context: context, buffer: &buffer)
        case .waitingConnectRequest:
            var buffer = unwrapInboundIn(data)
            handleConnectRequest(context: context, buffer: &buffer)
        case .forwarding:
            // Bridge may already be in the pipeline while this handler is being removed.
            // Forward rather than drop bytes during that transition window.
            context.fireChannelRead(data)
        case .failed:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        delegate?.didError(error.localizedDescription)
        context.close(promise: nil)
    }

    // MARK: - Public API for ConnectHandler

    /// Send a SOCKS5 reply. Status 0x00 = success, non-zero = error (closes channel).
    func sendReply(context: ChannelHandlerContext, status: UInt8) {
        var reply = context.channel.allocator.buffer(capacity: 10)
        reply.writeInteger(UInt8(0x05))     // VER
        reply.writeInteger(status)           // REP
        reply.writeInteger(UInt8(0x00))     // RSV
        reply.writeInteger(UInt8(0x01))     // ATYP = IPv4
        reply.writeBytes([0, 0, 0, 0])     // BND.ADDR
        reply.writeInteger(UInt16(0))       // BND.PORT
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        if status != 0x00 {
            state = .failed
            context.close(promise: nil)
        }
    }

    /// Transition to forwarding state. Call after successful connection + bridge installation.
    func transitionToForwarding() {
        state = .forwarding
    }

    // MARK: - SOCKS5 Handshake

    private func handleMethodNegotiation(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard buffer.readableBytes >= 3,
              let ver = buffer.readInteger(as: UInt8.self), ver == 0x05,
              let nmethods = buffer.readInteger(as: UInt8.self),
              buffer.readableBytes >= Int(nmethods) else {
            delegate?.didNegotiateMethod(success: false)
            state = .failed
            context.close(promise: nil)
            return
        }
        buffer.moveReaderIndex(forwardBy: Int(nmethods))

        var reply = context.channel.allocator.buffer(capacity: 2)
        reply.writeInteger(UInt8(0x05))  // VER
        reply.writeInteger(UInt8(0x00))  // METHOD: no auth
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        delegate?.didNegotiateMethod(success: true)
        state = .waitingConnectRequest
    }

    private func handleConnectRequest(context: ChannelHandlerContext, buffer: inout ByteBuffer) {
        guard buffer.readableBytes >= 7,
              let ver = buffer.readInteger(as: UInt8.self), ver == 0x05,
              let cmd = buffer.readInteger(as: UInt8.self), cmd == 0x01,
              let _ = buffer.readInteger(as: UInt8.self), // reserved
              let atyp = buffer.readInteger(as: UInt8.self) else {
            sendReply(context: context, status: 0x01)
            return
        }

        let host: String
        switch atyp {
        case 0x01: // IPv4
            guard buffer.readableBytes >= 6,
                  let ip = buffer.readBytes(length: 4) else {
                sendReply(context: context, status: 0x01)
                return
            }
            host = ip.map { String($0) }.joined(separator: ".")

        case 0x03: // Domain
            guard let len = buffer.readInteger(as: UInt8.self),
                  buffer.readableBytes >= Int(len) + 2,
                  let domain = buffer.readBytes(length: Int(len)) else {
                sendReply(context: context, status: 0x01)
                return
            }
            host = String(bytes: domain, encoding: .utf8) ?? ""

        case 0x04: // IPv6
            guard buffer.readableBytes >= 18,
                  let ip = buffer.readBytes(length: 16) else {
                sendReply(context: context, status: 0x01)
                return
            }
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(UInt16(ip[i]) << 8 | UInt16(ip[i + 1]), radix: 16))
            }
            host = parts.joined(separator: ":")

        default:
            sendReply(context: context, status: 0x08) // address type not supported
            return
        }

        guard let portHi = buffer.readInteger(as: UInt8.self),
              let portLo = buffer.readInteger(as: UInt8.self) else {
            sendReply(context: context, status: 0x01)
            return
        }
        let port = Int(portHi) << 8 | Int(portLo)

        delegate?.didReceiveConnect(host: host, port: port)
        onConnect(host, port, context, self)
    }
}
