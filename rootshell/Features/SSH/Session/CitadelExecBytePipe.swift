//
//  CitadelExecBytePipe.swift
//  rootshell
//
//  AsyncBytePipe over a Citadel bidirectional exec channel. Citadel's output
//  stream has no backpressure, so inbound chunks are buffered up to a cap;
//  past it the channel is closed and the consumer sees EOF, which the
//  owner treats as a dropped channel and reconnects.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
#if canImport(Citadel)
import Citadel
import NIOCore
import NIOFoundationCompat
import NIOSSH

actor CitadelExecBytePipe: AsyncBytePipe {

    /// Inbound bytes a slow consumer may leave queued before the channel is
    /// dropped instead of buffering without bound.
    static let maxBufferedBytes = 8 * 1024 * 1024

    private nonisolated let channel: Channel
    private var inbound: [Data] = []
    private var bufferedBytes = 0
    private var pendingTail = Data()
    private var pendingReader: CheckedContinuation<Data?, Never>?
    private var closed = false
    private var pumpTask: Task<Void, Never>?
    private nonisolated let stderrSink: AsyncStream<Data>.Continuation?
    private(set) var exitStatus: Int?

    static func open(client: SSHClient, command: String) async throws -> CitadelExecBytePipe {
        let (channel, output) = try await client.executeCommandBidirectional(command)
        let pipe = CitadelExecBytePipe(channel: channel, stderrSink: nil)
        await pipe.startPump(output)
        return pipe
    }

    /// Like `open`, but stderr arrives on the returned stream (newest chunks
    /// kept) instead of being dropped. The stream ends with the channel.
    static func openWithStderr(client: SSHClient, command: String) async throws -> (CitadelExecBytePipe, AsyncStream<Data>) {
        let (channel, output) = try await client.executeCommandBidirectional(command)
        let (stderr, sink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let pipe = CitadelExecBytePipe(channel: channel, stderrSink: sink)
        await pipe.startPump(output)
        return (pipe, stderr)
    }

    private init(channel: Channel, stderrSink: AsyncStream<Data>.Continuation?) {
        self.channel = channel
        self.stderrSink = stderrSink
    }

    private func startPump(_ output: AsyncThrowingStream<ExecCommandOutput, Error>) {
        pumpTask = Task { [weak self] in
            do {
                for try await chunk in output {
                    guard let self else { return }
                    switch chunk {
                    case .stdout(let buffer):
                        let data = Data(buffer.readableBytesView)
                        if await !self.enqueue(data) { return }
                    case .stderr(let buffer):
                        // Diagnostics only unless a caller asked for stderr.
                        self.stderrSink?.yield(Data(buffer.readableBytesView))
                    case .exitStatus(let status):
                        await self.noteExit(status)
                    }
                }
            } catch let failure as SSHClient.CommandFailed {
                await self?.noteExit(failure.exitCode)
            } catch {
                // Stream errors end the pipe like a close.
            }
            await self?.finish()
        }
    }

    /// Returns false when the buffer cap was breached and the channel closed.
    private func enqueue(_ data: Data) -> Bool {
        if closed { return false }
        if let reader = pendingReader {
            pendingReader = nil
            reader.resume(returning: data)
            return true
        }
        bufferedBytes += data.count
        if bufferedBytes > Self.maxBufferedBytes {
            finish()
            return false
        }
        inbound.append(data)
        return true
    }

    private func noteExit(_ status: Int) {
        exitStatus = status
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        stderrSink?.finish()
        channel.close(promise: nil)
        if let reader = pendingReader {
            pendingReader = nil
            reader.resume(returning: nil)
        }
    }

    func read(maxBytes: Int) async throws -> Data? {
        if !pendingTail.isEmpty {
            return takeFromTail(maxBytes)
        }
        if let next = inbound.first {
            inbound.removeFirst()
            bufferedBytes -= next.count
            pendingTail = next
            return takeFromTail(maxBytes)
        }
        if closed { return nil }
        precondition(pendingReader == nil, "CitadelExecBytePipe supports one reader")
        let chunk = await withCheckedContinuation { continuation in
            pendingReader = continuation
        }
        guard let chunk else { return nil }
        pendingTail = chunk
        return takeFromTail(maxBytes)
    }

    private func takeFromTail(_ maxBytes: Int) -> Data {
        if pendingTail.count <= maxBytes {
            let all = pendingTail
            pendingTail = Data()
            return all
        }
        let head = pendingTail.prefix(maxBytes)
        pendingTail = pendingTail.subdata(in: maxBytes..<pendingTail.count)
        return Data(head)
    }

    func write(_ data: Data) async throws {
        if closed {
            throw NSError(
                domain: "CitadelExecBytePipe",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "exec channel is closed"]
            )
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    func close() async {
        finish()
        pumpTask?.cancel()
    }
}
#endif
