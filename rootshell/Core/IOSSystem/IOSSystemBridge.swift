#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import OSLog

/// Shared plumbing for `@_cdecl` ios_system entry points. ios_system calls them on
/// its own background thread with `thread_stdout`/`thread_stderr` already redirected.
nonisolated enum IOSSystemBridge {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "ios-system-bridge")

    /// The calling thread's stdout, falling back to its stderr, then the process stdout.
    static func outputStream() -> UnsafeMutablePointer<FILE>? {
        ios_get_thread_stdout() ?? ios_get_thread_stderr() ?? Darwin.stdout
    }

    /// The calling thread's stderr, falling back to its stdout, then the process stderr.
    static func errorStream() -> UnsafeMutablePointer<FILE>? {
        ios_get_thread_stderr() ?? ios_get_thread_stdout() ?? Darwin.stderr
    }

    static func write(_ text: String) {
        write(text, to: outputStream())
    }

    static func writeError(_ text: String) {
        write(text, to: errorStream())
    }

    private static func write(_ text: String, to stream: UnsafeMutablePointer<FILE>?) {
        guard let stream else {
            logger.error("No output stream available for ios_system bridge")
            return
        }
        fputs(text, stream)
        fflush(stream)
    }

    /// `argv[1...]` decoded as UTF-8, preserving argument boundaries. Undecodable entries are skipped.
    static func arguments(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
        let count = max(0, Int(argc))
        guard count > 1, let argv else { return [] }

        var args: [String] = []
        args.reserveCapacity(count - 1)
        for i in 1..<count {
            guard let arg = argv[i] else { continue }
            if let decoded = String(validatingCString: arg) {
                args.append(decoded)
            } else {
                logger.error("Skipping non-UTF8 argument at index \(i)")
            }
        }
        return args
    }

    /// Runs an async command whose output must land on the calling ios_system thread.
    ///
    /// `start` runs first and must not block: it launches the command and hands it the
    /// writer. This thread then forwards pipe bytes to thread stdout until
    /// `PipeWriter.finish` closes the write-end, and returns the exit status set there.
    /// Producers on MainActor use the default queued writes; `blockingWrites` makes each
    /// write wait for the pipe, which gives detached producers backpressure.
    static func pump(name: String, blockingWrites: Bool = false, start: (PipeWriter) -> Void) -> Int32 {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            write("\(name): failed to create pipe\n")
            return 1
        }
        let readFd = fds[0]
        let writeFd = fds[1]

        guard let threadStdout = outputStream() else {
            Darwin.close(readFd)
            Darwin.close(writeFd)
            logger.error("No output stream available for \(name) bridge")
            return 1
        }

        // The read-end closing early must not SIGPIPE the process.
        _ = fcntl(writeFd, F_SETNOSIGPIPE, 1)

        let writer = PipeWriter(fd: writeFd, name: name, blocking: blockingWrites)
        start(writer)

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
            Darwin.close(readFd)
        }

        while true {
            let count = read(readFd, buffer, bufferSize)
            if count > 0 {
                fwrite(buffer, 1, count, threadStdout)
                fflush(threadStdout)
            } else if count == 0 || errno != EINTR {
                break
            }
        }

        return writer.exitStatus
    }

    /// Write-end of a `pump` pipe. Writes are serialized on a private queue so producers
    /// on any actor keep ordering, and `finish` closes only after they have drained.
    nonisolated final class PipeWriter: @unchecked Sendable {
        private let fd: Int32
        private let blocking: Bool
        private let queue: DispatchQueue

        // Touched only on `queue`. The pump reads `exitStatus` after pipe EOF, which the
        // close() on `queue` sequences before it.
        private var closed = false
        private(set) var exitStatus: Int32 = 0

        fileprivate init(fd: Int32, name: String, blocking: Bool) {
            self.fd = fd
            self.blocking = blocking
            queue = DispatchQueue(label: "com.rootshell.\(name)-bridge.write")
        }

        func write(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            write(data)
        }

        func write(_ data: Data) {
            perform { self.writeOnQueue(data) }
        }

        /// Closes the write-end after pending writes drain, which ends the pump with `exitStatus`.
        func finish(exitStatus: Int32) {
            perform {
                self.exitStatus = exitStatus
                self.closeOnQueue()
            }
        }

        private func perform(_ work: @escaping @Sendable () -> Void) {
            if blocking {
                queue.sync(execute: work)
            } else {
                queue.async(execute: work)
            }
        }

        private func writeOnQueue(_ data: Data) {
            guard !closed else { return }
            data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return }
                var offset = 0
                while offset < buf.count {
                    let written = Darwin.write(fd, base + offset, buf.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        // EPIPE/EBADF: the command was killed or the reader is gone.
                        closeOnQueue()
                        return
                    }
                    if written == 0 { return }
                    offset += written
                }
            }
        }

        private func closeOnQueue() {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
