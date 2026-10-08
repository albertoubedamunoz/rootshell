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

    /// Delivers each datagram on a private queue until closed.
    func startReceiving(_ handler: @escaping @Sendable (Data) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let fd = fd
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                guard n > 0 else { break }
                handler(Data(buffer[0..<n]))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        lock.lock()
        self.source = source
        lock.unlock()
        source.resume()
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
        if let source {
            source.cancel()
        } else {
            Darwin.close(fd)
        }
    }

    deinit {
        close()
    }
}

#endif
