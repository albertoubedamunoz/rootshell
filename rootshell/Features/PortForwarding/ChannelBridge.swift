//
//  ChannelBridge.swift
//  rootshell
//
//  Cross-event-loop channel bridge for port forwarding.
//  Connects two NIO channels that may live on DIFFERENT event loops.
//  Unlike GlueHandler (which is same-event-loop only), all partner
//  methods use lock-protected Channel references or dispatch to the
//  owning event loop.
//

import Foundation
import NIOCore

/// Bridge that connects two NIO channels which may be on different event loops.
/// Partner methods are thread-safe: they use NIO Channel APIs (which dispatch
/// internally) or explicitly hop to the owning event loop for context access.
///
/// Thread safety model:
/// - `lock` protects `channel`, `pendingWrites`, `pendingFlush`, `pendingClose`
/// - `context` and `pendingRead` are only accessed from the owning event loop
/// - Partner methods use `Channel` APIs or `eventLoop.execute` for safety
nonisolated final class ChannelBridge: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: ChannelBridge?
    private var context: ChannelHandlerContext?  // owning event loop only
    private var pendingRead = false              // owning event loop only
    private let onClose: (@Sendable () -> Void)?
    private var didSignalClose = false

    // Lock-protected state for cross-event-loop partner access
    private let lock = NSLock()
    private var channel: Channel?
    private var pendingWrites: [ByteBuffer] = []
    private var pendingFlush = false
    private var pendingClose: PendingClose = .none
    private var didRequestOutputClose = false
    private var didRequestFullClose = false

    private enum PendingClose: Int {
        case none, output, full
    }

    private init(onClose: (@Sendable () -> Void)?) {
        self.onClose = onClose
    }

    /// Creates a matched pair of ChannelBridge handlers that bridge two channels.
    /// Safe for cross-event-loop use.
    static func matchedPair(onClose: (@Sendable () -> Void)? = nil) -> (ChannelBridge, ChannelBridge) {
        let first = ChannelBridge(onClose: onClose)
        let second = ChannelBridge(onClose: onClose)
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // MARK: - Cross-event-loop partner methods

    private func partnerWrite(_ data: ByteBuffer) {
        lock.lock()
        guard let ch = channel else {
            pendingWrites.append(data)
            lock.unlock()
            return
        }
        lock.unlock()
        ch.write(data, promise: nil)
    }

    private func partnerFlush() {
        lock.lock()
        guard let ch = channel else {
            pendingFlush = true
            lock.unlock()
            return
        }
        lock.unlock()
        ch.flush()
    }

    private func partnerBecameWritable() {
        lock.lock()
        guard let ch = channel else {
            lock.unlock()
            return
        }
        lock.unlock()
        // Dispatch to owning event loop for pendingRead check
        ch.eventLoop.execute { [self] in
            guard self.pendingRead else { return }
            self.pendingRead = false
            self.context?.read()
        }
    }

    private var partnerWritable: Bool {
        lock.lock()
        let ch = channel
        lock.unlock()
        return ch?.isWritable ?? false
    }

    private func partnerWriteEOF() {
        lock.lock()
        guard !didRequestOutputClose, !didRequestFullClose else {
            lock.unlock()
            return
        }
        didRequestOutputClose = true
        guard let ch = channel else {
            if pendingClose.rawValue < PendingClose.output.rawValue {
                pendingClose = .output
            }
            lock.unlock()
            return
        }
        lock.unlock()
        ch.eventLoop.execute { [self] in
            guard let ctx = self.context, ctx.channel.isActive else { return }
            ctx.close(mode: .output, promise: nil)
        }
    }

    private func partnerCloseFull() {
        lock.lock()
        guard !didRequestFullClose else {
            lock.unlock()
            return
        }
        didRequestFullClose = true
        guard let ch = channel else {
            pendingClose = .full
            lock.unlock()
            return
        }
        lock.unlock()
        ch.eventLoop.execute { [self] in
            guard let ctx = self.context, ctx.channel.isActive else { return }
            ctx.close(promise: nil)
        }
    }

    // MARK: - Owning event loop helpers

    private func applyPendingCloseIfPossible() {
        guard let context else { return }
        lock.lock()
        let close = pendingClose
        if close != .none { pendingClose = .none }
        lock.unlock()

        switch close {
        case .none: break
        case .output:
            guard context.channel.isActive else { return }
            context.close(mode: .output, promise: nil)
        case .full:
            guard context.channel.isActive else { return }
            context.close(promise: nil)
        }
    }

    private func activateIfNeeded() {
        if context?.channel.isWritable == true {
            partner?.partnerBecameWritable()
        }
    }

    private func signalCloseIfNeeded() {
        guard !didSignalClose else { return }
        didSignalClose = true
        onClose?()
    }

    // MARK: - ChannelHandler lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context

        lock.lock()
        self.channel = context.channel
        let pending = self.pendingWrites
        self.pendingWrites = []
        let shouldFlush = self.pendingFlush
        self.pendingFlush = false
        let close = self.pendingClose
        lock.unlock()

        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [weak self] error in
            self?.context?.fireErrorCaught(error)
        }

        if close != .full, !pending.isEmpty {
            for data in pending {
                context.write(wrapOutboundOut(data), promise: nil)
            }
        }
        if close != .full, shouldFlush {
            context.flush()
        }

        if close != .none {
            lock.lock()
            if close.rawValue > pendingClose.rawValue { pendingClose = close }
            lock.unlock()
            applyPendingCloseIfPossible()
        }

        activateIfNeeded()
    }

    func channelActive(context: ChannelHandlerContext) {
        applyPendingCloseIfPossible()
        activateIfNeeded()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        signalCloseIfNeeded()
        lock.lock()
        channel = nil
        pendingWrites.removeAll(keepingCapacity: false)
        pendingFlush = false
        pendingClose = .none
        lock.unlock()
        self.context = nil
        self.partner = nil
        self.pendingRead = false
    }

    // MARK: - Inbound events (owning event loop)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        partner?.partnerWrite(buf)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        signalCloseIfNeeded()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        signalCloseIfNeeded()
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}
