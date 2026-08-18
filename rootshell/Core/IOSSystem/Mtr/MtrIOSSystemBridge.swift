#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import OSLog

// MARK: - ios_system entry points

/// Entry point for `mtr` when invoked via ios_system.
/// ios_system calls this as `int mtr_main(int argc, char* argv[])` on a background thread
/// with `ios_get_thread_stdout()` already redirected to the appropriate pipe.
@_cdecl("mtr_main")
func mtr_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: false, isTraceroute: false)
}

/// Entry point for `mtr6` (IPv6-forced mtr).
@_cdecl("mtr6_main")
func mtr6_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: true, isTraceroute: false)
}

/// Entry point for `traceroute` (always report mode).
/// Rewrites to `mtr -r -c 3 <remaining args>`.
@_cdecl("traceroute_main")
func traceroute_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: false, isTraceroute: true)
}

/// Entry point for `traceroute6` (always report mode, IPv6).
/// Rewrites to `mtr6 -r -c 3 <remaining args>`.
@_cdecl("traceroute6_main")
func traceroute6_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return mtrIOSSystemEntry(argc: argc, argv: argv, forceIPv6: true, isTraceroute: true)
}

// MARK: - Common implementation

private let logger = Logger(subsystem: "com.kk2.rootshell", category: "mtr-bridge")

private func outputStreamForCurrentThread() -> UnsafeMutablePointer<FILE>? {
    if let stream = ios_get_thread_stdout() {
        return stream
    }
    if let stream = ios_get_thread_stderr() {
        return stream
    }
    return Darwin.stdout
}

private func writeToCurrentThreadOutput(_ text: String) {
    guard let stream = outputStreamForCurrentThread() else {
        logger.error("No output stream available for mtr ios_system bridge")
        return
    }
    fputs(text, stream)
    fflush(stream)
}

/// Common entry point for all mtr/traceroute commands invoked via ios_system.
///
/// Bridge pattern: MtrCommand is @MainActor + async. ios_system calls us on a background thread.
/// We create a pipe pair, dispatch MtrCommand to MainActor with an output closure that writes to
/// the pipe's write-end, then read from the pipe's read-end and write to `ios_get_thread_stdout()`.
/// When MtrCommand completes, it closes the write-end → EOF → we return.
private func mtrIOSSystemEntry(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    forceIPv6: Bool,
    isTraceroute: Bool
) -> Int32 {
    // Reconstruct command string from argc/argv
    let commandString = reconstructCommand(
        argc: argc, argv: argv, forceIPv6: forceIPv6, isTraceroute: isTraceroute
    )

    // Parse the command
    let parseResult = MtrCommandParser.parse(command: commandString)

    switch parseResult {
    case .error(let message):
        let msg = "mtr: \(message)\n"
        writeToCurrentThreadOutput(msg)
        return 1

    case .help:
        writeToCurrentThreadOutput("mtr: use --help for usage information\n")
        return 1

    case .success(let config):
        // Reject interactive mode — should never reach here via ios_system routing,
        // but guard against it.
        if config.reportMode == nil {
            writeToCurrentThreadOutput("mtr: interactive mode not supported via ios_system\n")
            return 1
        }

        // Create a pipe for bridging MainActor output → this thread's stdout
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else {
            writeToCurrentThreadOutput("mtr: failed to create pipe\n")
            return 1
        }
        let pipeReadFd = pipeFds[0]
        let pipeWriteFd = pipeFds[1]

        // Capture ios_get_thread_stdout() for this thread before dispatching
        guard let threadStdout = outputStreamForCurrentThread() else {
            close(pipeReadFd)
            close(pipeWriteFd)
            logger.error("No output stream available after pipe setup")
            return 1
        }

        // Avoid SIGPIPE termination if the read-end gets closed unexpectedly.
        _ = fcntl(pipeWriteFd, F_SETNOSIGPIPE, 1)

        // Serial queue for pipe writes — keeps writes off MainActor and preserves ordering.
        // onComplete dispatches close() here too, so all writes flush before EOF.
        let writeQueue = DispatchQueue(label: "com.rootshell.mtr-bridge.write")
        let writeFd = pipeWriteFd

        // Exit status: set by onComplete on writeQueue, read after EOF on this thread.
        // Sequenced through pipe EOF (close on writeQueue → read returns 0 on this thread).
        nonisolated(unsafe) var exitStatus: Int32 = 0
        nonisolated(unsafe) var writeClosed = false

        // Retain the MtrCommand outside the Task closure so it isn't deallocated
        // when the Task body exits (start() uses [weak self] internally).
        nonisolated(unsafe) var retainedCommand: MtrCommand?

        // Dispatch MtrCommand to MainActor.
        // Output closure enqueues writes to writeQueue (non-blocking on MainActor).
        // When MtrCommand completes, onComplete enqueues close(writeFd) → EOF on read-end.
        Task { @MainActor in
            let mtrCommand = MtrCommand(
                config: config,
                cols: 80,
                rows: 24,
                output: { text in
                    // Convert terminal line endings to Unix for pipe transport.
                    // monitorPipe's LF normalization will add \r back when displaying
                    // in the terminal. When redirected to file, \n is correct.
                    let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
                    guard let data = unix.data(using: .utf8) else { return }
                    // Dispatch write to background queue — never block MainActor.
                    writeQueue.async {
                        guard !writeClosed else { return }
                        data.withUnsafeBytes { buf in
                            guard let ptr = buf.baseAddress else { return }
                            var remaining = buf.count
                            var offset = 0
                            while remaining > 0 {
                                let written = write(writeFd, ptr + offset, remaining)
                                if written < 0 {
                                    if errno == EINTR {
                                        continue
                                    }
                                    // Stop attempting writes once the pipe is closed.
                                    writeClosed = true
                                    break  // EPIPE/EBADF/etc — command was killed or pipe closed
                                }
                                if written == 0 { break }
                                offset += written
                                remaining -= written
                            }
                        }
                    }
                }
            )

            // Keep MtrCommand alive until it completes
            retainedCommand = mtrCommand

            mtrCommand.onComplete = { [weak mtrCommand] in
                let failed = mtrCommand?.didFail ?? false
                // Release on MainActor where it was set. Reading first keeps the
                // retention box from being flagged write-only.
                if retainedCommand != nil { retainedCommand = nil }
                // Enqueue close after all pending writes drain (serial queue ordering).
                writeQueue.async {
                    exitStatus = failed ? 1 : 0
                    guard !writeClosed else { return }
                    writeClosed = true
                    close(writeFd)
                }
            }

            mtrCommand.start()
        }

        // Read loop: pipe read-end → ios_get_thread_stdout()
        // Blocks on this (ios_system) thread until onComplete closes the write-end.
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
            close(pipeReadFd)
        }

        while true {
            let bytesRead = read(pipeReadFd, buffer, bufferSize)
            if bytesRead > 0 {
                fwrite(buffer, 1, bytesRead, threadStdout)
                fflush(threadStdout)
            } else if bytesRead == 0 {
                break
            } else {
                if errno == EINTR {
                    continue
                }
                break
            }
        }

        return exitStatus
    }
}

// MARK: - Helpers

/// Reconstruct a command string from argc/argv, rewriting traceroute → mtr if needed.
private func reconstructCommand(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    forceIPv6: Bool,
    isTraceroute: Bool
) -> String {
    var parts: [String] = []
    let safeArgc = max(0, Int(argc))

    // Command name
    parts.append(forceIPv6 ? "mtr6" : "mtr")

    // For traceroute, prepend report flags
    if isTraceroute {
        parts.append("-r")
        parts.append("-c")
        parts.append("3")
    }

    // Append remaining args (skip argv[0] which is the command name)
    if safeArgc > 1, let argv {
        for i in 1..<safeArgc {
            if let arg = argv[i] {
                if let decoded = String(validatingUTF8: arg) {
                    parts.append(decoded)
                } else {
                    logger.error("Skipping non-UTF8 mtr argument at index \(i)")
                }
            }
        }
    }

    return parts.joined(separator: " ")
}

#endif // !targetEnvironment(macCatalyst)
