//
//  TSSHTransferStreamFraming.swift
//  rootshell
//
//  Length-prefixed framing over an NSInputStream / NSOutputStream pair
//  produced by `NSUserActivity.getContinuationStreams`. Each frame is
//  4 bytes big-endian length, then `length` bytes of payload.
//
//  Critical design rule: every `input.read` / `output.write` runs on the
//  dedicated runloop thread that the streams are scheduled on. Calling
//  CFReadStreamRead from a thread that is NOT the stream's scheduling
//  runloop pushes CFNetwork into a sync path that pumps the calling
//  thread's runloop, waiting for events that never arrive on it. We've
//  watched that wedge the main thread in production (0x8BADF00D in
//  beta build 87), so the façade methods (`receiveFrame`, `sendFrame`,
//  `drainUntilRemoteClose`) enqueue requests for the runloop thread to
//  execute and block on a semaphore until results come back. Every call
//  carries a deadline so a stuck peer can never hold a caller longer
//  than the protocol says it should wait.
//

import Foundation
import os.log

/// Bidirectional framed channel over a pair of Continuity streams. The
/// public façade is synchronous and runs on a dedicated background
/// thread internally — callers should still drive the channel from a
/// `Task { ... }` so the main actor never blocks on stream I/O even if
/// the channel's deadlines work as intended.
nonisolated final class TrzszTransferChannel: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszTransferChannel"
    )

    /// 4-byte length prefix limit — reject obviously bogus frames so a
    /// corrupted stream can't allocate gigabytes.
    static let maxFrameBytes: Int = 8 * 1024 * 1024

    // MARK: - State owned by callers (any thread)

    private let stateLock = NSLock()
    private var didOpen = false
    private var isClosed = false

    // MARK: - Runloop-thread plumbing

    /// I/O request executed on the runloop thread. The runloop thread
    /// owns the only `input.read` / `output.write` invocations in the
    /// process; callers enqueue requests via `submitRead` / `submitWrite`
    /// and block on a semaphore until the runloop thread completes them.
    ///
    /// Storage is **request-owned** on purpose. A caller that times out
    /// or is cancelled may have already unwound the `withUnsafeBytes`
    /// closure that produced its source/destination pointer; if the
    /// runloop thread had captured a raw pointer it would dereference
    /// freed stack memory. Each request instead carries its own `Data`
    /// (for writes, a copy of the bytes; for reads, a buffer the
    /// runloop fills and the caller drains after waking).
    private final class IORequest {
        enum Kind {
            /// Caller requests up to `maxLength` bytes. Runloop fills
            /// `readBuffer` and stores the count in `readCount`.
            case read(maxLength: Int)
            /// Caller hands over (an owned copy of) the bytes to write.
            /// Runloop reports the byte count it managed to write back
            /// in `result`.
            case write(data: Data)
        }
        let kind: Kind
        let completion: DispatchSemaphore = DispatchSemaphore(value: 0)
        /// Filled by the runloop for `read` requests. Sized to
        /// `maxLength` once on construction; the runloop bounds its
        /// read to this buffer's size.
        var readBuffer: [UInt8] = []
        var readCount: Int = 0
        /// Filled by the runloop for `write` requests.
        var result: Int = 0
        var resultStatus: Stream.Status = .notOpen
        var resultError: Error?
        /// Set by `close()` / `cancelPendingRequests()`. The runloop
        /// re-checks this immediately before invoking the syscall.
        var cancelled: Bool = false

        init(kind: Kind) {
            self.kind = kind
            if case let .read(maxLength) = kind {
                self.readBuffer = [UInt8](repeating: 0, count: maxLength)
            }
        }
    }

    private let queueLock = NSLock()
    private var pendingRead: IORequest?
    private var pendingWrite: IORequest?
    private var runLoopRef: CFRunLoop?
    private let runLoopReadyLatch = DispatchSemaphore(value: 0)

    private let input: InputStream
    private let output: OutputStream
    private let runLoopThread: Thread

    // MARK: - Lifecycle

    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output

        // Two-step: build a placeholder Thread that calls a free-function
        // dispatch back into self. Captures self weakly so the thread
        // doesn't keep the channel alive past its public references.
        let body = ThreadBody()
        let thread = Thread(target: body, selector: #selector(ThreadBody.run), object: nil)
        thread.name = "trzsz-transfer-stream"
        thread.qualityOfService = .userInitiated
        self.runLoopThread = thread
        body.owner = self  // weak — see ThreadBody
    }

    /// Tiny ObjC-shaped wrapper so we can install the thread target
    /// before `self` is fully initialized. Holds `owner` weakly so the
    /// channel can deinit normally; the runloop body checks for nil
    /// and exits if the channel has already gone.
    @objc private final class ThreadBody: NSObject {
        weak var owner: TrzszTransferChannel?
        @objc func run() {
            owner?.runLoopBody()
        }
    }

    /// Start the runloop thread and wait briefly for the streams to
    /// reach `.open`. Safe to call from any thread; idempotent.
    func open() {
        stateLock.lock()
        if didOpen { stateLock.unlock(); return }
        didOpen = true
        stateLock.unlock()

        runLoopThread.start()

        // Wait for the runloop thread to register its CFRunLoop and
        // open the streams. Without this, an immediate submitRead
        // could land before scheduling is complete.
        _ = runLoopReadyLatch.wait(timeout: .now() + .seconds(5))

        // Spin briefly until both streams report a usable status.
        // Continuity streams typically reach `.open` within tens of
        // milliseconds; bail after 5s with whatever they're at.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            stateLock.lock()
            let closed = isClosed
            stateLock.unlock()
            if closed { return }
            let inStatus = input.streamStatus
            let outStatus = output.streamStatus
            if inStatus == .open && outStatus == .open { return }
            if inStatus == .error || outStatus == .error { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Tear down the channel. Cancels any in-flight read/write so
    /// callers unblock with `streamClosed`. Safe from any thread.
    func close() {
        stateLock.lock()
        let wasOpen = didOpen
        let alreadyClosed = isClosed
        isClosed = true
        stateLock.unlock()
        guard !alreadyClosed else { return }

        // Wake any callers parked on a pending request. The runloop
        // thread does the actual `input.close` / `output.close` so
        // the streams are torn down on the thread that scheduled them.
        cancelPendingRequests()

        if wasOpen {
            // Nudge the runloop in case it's mid-`run(mode:before:)`
            // with no source to wake it. The runloop body re-checks
            // isClosed every iteration.
            if let rl = currentRunLoopRef() {
                CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
                    self?.serviceCloseOnRunLoop()
                }
                CFRunLoopWakeUp(rl)
            }
            runLoopThread.cancel()
        } else {
            // Streams were never opened (open() never called). Close
            // synchronously here — there's no other thread that has
            // touched them.
            input.close()
            output.close()
        }
    }

    private func currentRunLoopRef() -> CFRunLoop? {
        queueLock.lock()
        let rl = runLoopRef
        queueLock.unlock()
        return rl
    }

    private func cancelPendingRequests() {
        queueLock.lock()
        let read = pendingRead
        let write = pendingWrite
        pendingRead = nil
        pendingWrite = nil
        queueLock.unlock()
        if let read {
            read.cancelled = true
            read.completion.signal()
        }
        if let write {
            write.cancelled = true
            write.completion.signal()
        }
    }

    // MARK: - Runloop thread

    private func runLoopBody() {
        let rl = RunLoop.current
        let cfRL = CFRunLoopGetCurrent()

        // Publish our runloop pointer so close() can wake us. Schedule
        // the streams here too — the streams are now bound to this
        // thread's runloop and only this thread will call read/write.
        queueLock.lock()
        runLoopRef = cfRL
        queueLock.unlock()

        input.schedule(in: rl, forMode: .default)
        output.schedule(in: rl, forMode: .default)
        input.open()
        output.open()

        // Add a no-op runloop source so `rl.run` always has something
        // to keep it from returning immediately. Without this, an idle
        // runloop with no scheduled sources can return instantly and we
        // spin a hot loop.
        var sourceContext = CFRunLoopSourceContext()
        sourceContext.version = 0
        let source = CFRunLoopSourceCreate(nil, 0, &sourceContext)
        CFRunLoopAddSource(cfRL, source, .defaultMode)

        runLoopReadyLatch.signal()

        while !Thread.current.isCancelled {
            stateLock.lock()
            let closed = isClosed
            stateLock.unlock()
            if closed { break }

            servicePending()

            // Short tick so we re-check pending requests promptly even
            // when no stream events fire.
            rl.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        // Final teardown on the scheduling thread.
        input.close()
        output.close()
        CFRunLoopRemoveSource(cfRL, source, .defaultMode)

        // Drain any straggler requests so callers don't deadlock.
        cancelPendingRequests()
    }

    /// Called both from the runloop tick and from the wake-up perform
    /// block. Drives any pending request as far as it can without
    /// blocking — if the stream isn't ready, returns and we'll retry
    /// on the next tick when the runloop has had a chance to deliver
    /// has-bytes / has-space events.
    private func servicePending() {
        // Read side.
        queueLock.lock()
        let readReq = pendingRead
        queueLock.unlock()
        if let readReq, !readReq.cancelled {
            serviceRead(readReq)
        }

        // Write side.
        queueLock.lock()
        let writeReq = pendingWrite
        queueLock.unlock()
        if let writeReq, !writeReq.cancelled {
            serviceWrite(writeReq)
        }
    }

    private func serviceRead(_ req: IORequest) {
        guard case .read = req.kind else { return }
        // Re-check cancellation under the queue lock to make sure the
        // caller can't disappear out from under us. Even though we
        // dereference only request-owned storage now, an aborted
        // request shouldn't churn the stream.
        queueLock.lock()
        let stillPending = (pendingRead === req) && !req.cancelled
        queueLock.unlock()
        guard stillPending else { return }

        let status = input.streamStatus
        if status == .error {
            req.result = -1
            req.resultStatus = status
            req.resultError = input.streamError
            completeRead(req)
            return
        }
        if status == .atEnd || status == .closed {
            req.result = 0
            req.resultStatus = status
            completeRead(req)
            return
        }
        guard input.hasBytesAvailable else {
            // Will retry on next tick when stream signals readiness.
            return
        }
        let n = req.readBuffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return input.read(base, maxLength: buf.count)
        }
        req.readCount = max(0, n)
        req.result = n
        req.resultStatus = input.streamStatus
        if n < 0 {
            req.resultError = input.streamError
        }
        completeRead(req)
    }

    private func serviceWrite(_ req: IORequest) {
        guard case let .write(data) = req.kind else { return }
        queueLock.lock()
        let stillPending = (pendingWrite === req) && !req.cancelled
        queueLock.unlock()
        guard stillPending else { return }

        let status = output.streamStatus
        if status == .error {
            req.result = -1
            req.resultStatus = status
            req.resultError = output.streamError
            completeWrite(req)
            return
        }
        if status == .closed || status == .atEnd {
            req.result = 0
            req.resultStatus = status
            completeWrite(req)
            return
        }
        guard output.hasSpaceAvailable else {
            return
        }
        let n = data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> Int in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return output.write(base, maxLength: rawBuf.count)
        }
        req.result = n
        req.resultStatus = output.streamStatus
        if n < 0 {
            req.resultError = output.streamError
        }
        completeWrite(req)
    }

    private func completeRead(_ req: IORequest) {
        queueLock.lock()
        if pendingRead === req {
            pendingRead = nil
        }
        queueLock.unlock()
        req.completion.signal()
    }

    private func completeWrite(_ req: IORequest) {
        queueLock.lock()
        if pendingWrite === req {
            pendingWrite = nil
        }
        queueLock.unlock()
        req.completion.signal()
    }

    private func serviceCloseOnRunLoop() {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        guard closed else { return }
        cancelPendingRequests()
    }

    // MARK: - Caller-side façade

    /// Submits a read request to the runloop thread and waits for it
    /// to complete or the deadline to elapse. Returns up to `maxLength`
    /// bytes read into a fresh `Data`, or throws on error / closure /
    /// timeout.
    ///
    /// The bytes are copied via request-owned storage so the runloop
    /// thread never holds a pointer into caller memory. That eliminates
    /// the use-after-scope window where a timed-out / cancelled caller
    /// might invalidate its destination buffer before the runloop has
    /// finished servicing the request.
    private func submitRead(maxLength: Int, deadline: Date) throws -> Data {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        if closed { throw TrzszTransferError.streamClosed }

        let req = IORequest(kind: .read(maxLength: maxLength))
        queueLock.lock()
        precondition(pendingRead == nil, "Concurrent reads on TrzszTransferChannel")
        pendingRead = req
        queueLock.unlock()

        if let rl = currentRunLoopRef() {
            CFRunLoopWakeUp(rl)
        }

        let waitInterval = max(0, deadline.timeIntervalSinceNow)
        let waitResult = req.completion.wait(timeout: .now() + .milliseconds(Int(waitInterval * 1000)))

        if waitResult == .timedOut {
            // Mark cancelled BEFORE we drop our reference under the
            // queue lock, so any concurrent servicePending() that
            // already grabbed `req` will skip the syscall.
            queueLock.lock()
            req.cancelled = true
            if pendingRead === req {
                pendingRead = nil
            }
            queueLock.unlock()
            throw TrzszTransferError.timeout
        }
        if req.cancelled {
            throw TrzszTransferError.streamClosed
        }
        if let err = req.resultError {
            throw TrzszTransferError.streamError(err.localizedDescription)
        }
        if req.result < 0 {
            throw TrzszTransferError.streamError("read failed")
        }
        if req.result == 0 {
            if req.resultStatus == .atEnd || req.resultStatus == .closed {
                throw TrzszTransferError.streamClosed
            }
            return Data()
        }
        return Data(req.readBuffer.prefix(req.readCount))
    }

    /// Submits a write request. The runloop thread writes from a copy
    /// stored inside the request, so the caller can release its source
    /// `Data` immediately on return. Returns the number of bytes the
    /// runloop managed to push into the stream this round.
    private func submitWrite(_ data: Data, deadline: Date) throws -> Int {
        stateLock.lock()
        let closed = isClosed
        stateLock.unlock()
        if closed { throw TrzszTransferError.streamClosed }

        let req = IORequest(kind: .write(data: data))
        queueLock.lock()
        precondition(pendingWrite == nil, "Concurrent writes on TrzszTransferChannel")
        pendingWrite = req
        queueLock.unlock()

        if let rl = currentRunLoopRef() {
            CFRunLoopWakeUp(rl)
        }

        let waitInterval = max(0, deadline.timeIntervalSinceNow)
        let waitResult = req.completion.wait(timeout: .now() + .milliseconds(Int(waitInterval * 1000)))

        if waitResult == .timedOut {
            queueLock.lock()
            req.cancelled = true
            if pendingWrite === req {
                pendingWrite = nil
            }
            queueLock.unlock()
            throw TrzszTransferError.timeout
        }
        if req.cancelled {
            throw TrzszTransferError.streamClosed
        }
        if let err = req.resultError {
            throw TrzszTransferError.streamError(err.localizedDescription)
        }
        if req.result < 0 {
            throw TrzszTransferError.streamError("write failed")
        }
        if req.result == 0 {
            if req.resultStatus == .closed || req.resultStatus == .atEnd {
                throw TrzszTransferError.streamClosed
            }
        }
        return req.result
    }

    // MARK: - Public framing API

    /// Writes a single length-prefixed frame.
    /// - Parameter deadline: hard wall-clock cutoff for the whole frame.
    func sendFrame(_ data: Data, deadline: Date) throws {
        guard data.count <= Self.maxFrameBytes else {
            throw TrzszTransferError.malformedFrame("Outgoing frame too large: \(data.count)")
        }
        var header = [UInt8](repeating: 0, count: 4)
        let length = UInt32(data.count)
        header[0] = UInt8((length >> 24) & 0xff)
        header[1] = UInt8((length >> 16) & 0xff)
        header[2] = UInt8((length >> 8) & 0xff)
        header[3] = UInt8(length & 0xff)
        try writeAll(Data(header), deadline: deadline)
        if !data.isEmpty {
            try writeAll(data, deadline: deadline)
        }
    }

    /// Reads a single length-prefixed frame.
    /// - Parameter deadline: hard wall-clock cutoff for the whole frame.
    func receiveFrame(deadline: Date) throws -> Data {
        let header = try readAll(count: 4, deadline: deadline)
        // Read byte-by-byte to avoid the unaligned UInt32 load on
        // Data-backed memory that bit us in f8c9d7fd.
        let length = header.withUnsafeBytes { ptr -> UInt32 in
            let bytes = ptr.bindMemory(to: UInt8.self)
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
        guard length <= UInt32(Self.maxFrameBytes) else {
            throw TrzszTransferError.malformedFrame("Incoming frame too large: \(length)")
        }
        if length == 0 {
            return Data()
        }
        return try readAll(count: Int(length), deadline: deadline)
    }

    /// Drains the input stream until it reports `.atEnd` / `.error` /
    /// `.closed`, or until `timeout` elapses. Used by the receiver
    /// after sending the final ack so the peer's close-after-read is
    /// what tears the channel down — without this, closing immediately
    /// after a small write to a Continuity stream can drop the
    /// buffered bytes and leave the originator's `receiveFrame()`
    /// blocked until Apple's stream layer surfaces an "Operation timed
    /// out" ~60s later.
    func drainUntilRemoteClose(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            stateLock.lock()
            let closed = isClosed
            stateLock.unlock()
            if closed { return }

            let status = input.streamStatus
            if status == .atEnd || status == .error || status == .closed {
                return
            }
            do {
                let chunkDeadline = min(deadline, Date().addingTimeInterval(0.25))
                _ = try submitRead(maxLength: 1024, deadline: chunkDeadline)
                // Any bytes received post-ack are garbage; discard.
            } catch TrzszTransferError.timeout {
                continue
            } catch {
                return
            }
        }
    }

    // MARK: - Private byte-level I/O

    private func writeAll(_ data: Data, deadline: Date) throws {
        var offset = 0
        let total = data.count
        while offset < total {
            if Date() >= deadline {
                throw TrzszTransferError.timeout
            }
            // Chunk so a single submitWrite can't park on the semaphore
            // longer than the deadline allows — even though submitWrite
            // honors the deadline itself, splitting bounds the worst-
            // case copy size we hand to the runloop thread per round.
            let chunkSize = min(total - offset, 64 * 1024)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))
            let written = try submitWrite(chunk, deadline: deadline)
            if written <= 0 {
                throw TrzszTransferError.streamClosed
            }
            offset += written
            // If the runloop only consumed a prefix of the chunk, we'll
            // re-submit the remainder on the next iteration.
        }
    }

    private func readAll(count: Int, deadline: Date) throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)
        while accumulated.count < count {
            if Date() >= deadline {
                throw TrzszTransferError.timeout
            }
            let remaining = count - accumulated.count
            let chunk = try submitRead(maxLength: remaining, deadline: deadline)
            if chunk.isEmpty {
                // submitRead only returns empty on a non-terminal 0-byte
                // read; loop to retry. (Terminal cases throw.)
                continue
            }
            accumulated.append(chunk)
        }
        return accumulated
    }
}

// MARK: - Wire messages

/// Receiver → Originator. Sent first after streams open so the originator
/// can derive the shared key and seal the bootstrap.
nonisolated struct TrzszTransferHello: Codable, Sendable {
    let version: Int
    let receiverPubKey: Data
    let receiverDeviceName: String
    let requestedCols: UInt16
    let requestedRows: UInt16
}

/// Originator → Receiver. Carries the encrypted `TrzszTransferPayload`.
nonisolated struct TrzszTransferBootstrap: Codable, Sendable {
    let ciphertext: Data  // ChaChaPoly SealedBox.combined
}

/// Receiver → Originator. Final ack indicating whether the receiver was
/// able to attach to the server-side session.
nonisolated struct TrzszTransferAck: Codable, Sendable {
    let success: Bool
    let errorMessage: String?
    /// Client id the receiver used, or intended to use, for Attach().
    /// On failure the sender advances its exported credentials past this
    /// value so a later transfer from the same tab does not reuse a serial
    /// the server may already have recorded.
    let attemptedClientId: UInt64?

    init(success: Bool, errorMessage: String?, attemptedClientId: UInt64? = nil) {
        self.success = success
        self.errorMessage = errorMessage
        self.attemptedClientId = attemptedClientId
    }
}
