//
//  BoundedDataBuffer.swift
//  rootshell
//
//  Small thread-safe Data accumulator with a hard byte cap. Used to hold
//  output that arrives while the app is backgrounded without growing into
//  jetsam territory if the remote is chatty (e.g. `tail -f` of a busy log).
//  When the cap is reached, the OLDEST bytes are dropped — the user's
//  scrollback after resume will pick up from a recent point in the stream
//  rather than replaying minutes of stale output.
//

import Foundation
import os

final class BoundedDataBuffer: @unchecked Sendable {
    /// Max bytes to retain. Default 256 KiB — about a screen of dense output
    /// per second × ~30 s of background buffering. Tunable per instance.
    nonisolated let capacity: Int

    private let storage: OSAllocatedUnfairLock<Data>
    private let droppedBytes: OSAllocatedUnfairLock<Int>

    nonisolated init(capacity: Int = 256 * 1024) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = OSAllocatedUnfairLock(initialState: Data())
        self.droppedBytes = OSAllocatedUnfairLock(initialState: 0)
    }

    /// Append `data`, dropping oldest bytes if the cap would be exceeded.
    /// Returns the number of bytes dropped by this call (0 if none).
    @discardableResult
    nonisolated func append(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return storage.withLock { buffer -> Int in
            buffer.append(data)
            let overflow = buffer.count - capacity
            guard overflow > 0 else { return 0 }
            buffer.removeFirst(overflow)
            droppedBytes.withLock { $0 += overflow }
            return overflow
        }
    }

    /// Atomically take and clear the buffered data and the dropped-byte count.
    /// Returns nil if the buffer is empty (so callers can skip a no-op flush).
    nonisolated func drain() -> (data: Data, droppedDuringBackground: Int)? {
        let captured = storage.withLock { buffer -> Data in
            let captured = buffer
            buffer = Data()
            return captured
        }
        let dropped = droppedBytes.withLock { count -> Int in
            let captured = count
            count = 0
            return captured
        }
        if captured.isEmpty && dropped == 0 { return nil }
        return (captured, dropped)
    }

    /// Atomically take up to `maxBytes`, preserving any remaining bytes for a
    /// later drain. Returns `hasMore` so callers can budget foreground replay
    /// across runloop turns without losing byte order.
    nonisolated func drain(maxBytes: Int) -> (data: Data, droppedDuringBackground: Int, hasMore: Bool)? {
        precondition(maxBytes > 0, "maxBytes must be positive")

        let result = storage.withLock { buffer -> (data: Data, hasMore: Bool) in
            guard !buffer.isEmpty else { return (Data(), false) }
            let byteCount = min(maxBytes, buffer.count)
            let captured = Data(buffer.prefix(byteCount))
            buffer.removeFirst(byteCount)
            return (captured, !buffer.isEmpty)
        }
        let dropped = droppedBytes.withLock { count -> Int in
            let captured = count
            count = 0
            return captured
        }
        if result.data.isEmpty && dropped == 0 { return nil }
        return (result.data, dropped, result.hasMore)
    }
}
