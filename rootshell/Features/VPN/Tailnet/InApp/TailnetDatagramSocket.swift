//
//  TailnetDatagramSocket.swift
//  rootshell
//
//  A UDP flow over the in-app tailnet: one end of the datagram socketpair Go
//  bridges to netstack. Sends never block; a full socket drops the packet,
//  like a congested network.
//

#if !CHINA_BUILD

import Darwin
import Foundation

nonisolated final class TailnetDatagramSocket: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.rootshell.tailnet.datagram")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var closed = false

    /// Dials host:port over the tailnet.
    static func open(host: String, port: Int) async throws -> TailnetDatagramSocket {
        TailnetDatagramSocket(fd: try await TailnetGo.dialUDP(host: host, remotePort: port))
    }

    private init(fd: Int32) {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var size: Int32 = 2 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }

    struct Datagram: Sendable {
        let data: Data
        /// Uptime milliseconds at arrival.
        let receivedAtMs: UInt64
    }

    /// A full inbox pauses reads, so the backlog waits in the socket buffer
    /// and Go drops once that fills, like a congested UDP path. Sized so
    /// ordinary traffic never pauses: paused packets get late arrival times.
    private static let inboxPacketLimit = 4096
    private static let inboxByteLimit = 4 << 20
    private var inbox: [Datagram] = []
    private var inboxBytes = 0
    private var paused = false

    /// Calls `onReadable` on a private queue when datagrams arrive in an empty
    /// inbox; drain it with `takeReceived()`.
    func startReceiving(_ onReadable: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = fd
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { break }
                let receivedAtMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
                let result = self.enqueue(Datagram(data: Data(buffer[0..<n]), receivedAtMs: receivedAtMs))
                if result.notify { onReadable() }
                if result.paused { break }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        lock.lock()
        self.source = source
        lock.unlock()
        source.resume()
    }

    /// Removes and returns everything received since the last call.
    func takeReceived() -> [Datagram] {
        lock.lock()
        defer { lock.unlock() }
        let received = inbox
        inbox.removeAll()
        inboxBytes = 0
        if paused {
            paused = false
            source?.resume()
        }
        return received
    }

    /// `notify` when the inbox went from empty to non-empty.
    private func enqueue(_ datagram: Datagram) -> (notify: Bool, paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return (false, true) }
        inbox.append(datagram)
        inboxBytes += datagram.data.count
        if inbox.count >= Self.inboxPacketLimit || inboxBytes >= Self.inboxByteLimit {
            paused = true
            source?.suspend()
        }
        return (inbox.count == 1, paused)
    }

    /// False when the datagram was dropped or the socket is closed.
    @discardableResult
    func send(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        return data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) } == data.count
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        inbox.removeAll()
        inboxBytes = 0
        if let source {
            source.cancel()
            // A suspended source never runs its cancel handler, and releasing one traps.
            if paused {
                paused = false
                source.resume()
            }
        } else {
            Darwin.close(fd)
        }
    }

    deinit {
        close()
    }
}

#endif
