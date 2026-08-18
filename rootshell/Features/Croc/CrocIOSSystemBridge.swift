#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation
import OSLog

// MARK: - ios_system entry point

/// Entry point for `croc` when invoked via ios_system.
/// ios_system calls this on a background thread with `ios_get_thread_stdout()`
/// already redirected.
///
/// CrocClient is async (NWConnection), so we bridge sync→async with a pipe:
///   1. Create a pipe pair.
///   2. Launch a detached Task that runs CrocClient with output writing to
///      the pipe's write-end.
///   3. This thread blocks on `read(pipeReadFd)` and forwards bytes to
///      `ios_get_thread_stdout()`.
///   4. When CrocClient finishes it closes the write-end → EOF → return.
///
/// CrocClient is NOT @MainActor, so no MainActor hop is required.
@_cdecl("croc_main")
func croc_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let commandString = crocReconstructCommand(argc: argc, argv: argv)
    let stdinResult = crocStdinPayload()
    if case .failure(let error) = stdinResult {
        crocWriteOutput("croc: \(error.localizedDescription)\n")
        return 1
    }

    var cleanupPaths: [String] = []
    let parseResult = crocPrepareParseResult(
        CrocCommandParser.parse(command: commandString),
        stdinData: try? stdinResult.get(),
        cleanupPaths: &cleanupPaths
    )

    // Handle help/version/error synchronously (no async needed)
    switch parseResult {
    case .help:
        crocWriteOutput(CrocCommandParser.helpText)
        return 0
    case .print(let text, let exitCode):
        crocWriteOutput(text)
        return exitCode
    case .error(let message):
        crocWriteOutput("croc: \(message)\n")
        return 1
    default:
        break
    }

    // Create a pipe for bridging async output → this thread's stdout
    var pipeFds: [Int32] = [0, 0]
    guard pipe(&pipeFds) == 0 else {
        crocWriteOutput("croc: failed to create pipe\n")
        return 1
    }
    let pipeReadFd = pipeFds[0]
    let pipeWriteFd = pipeFds[1]

    let threadStdout = crocOutputStreamForCurrentThread()

    // Avoid SIGPIPE if the read-end gets closed unexpectedly.
    _ = fcntl(pipeWriteFd, F_SETNOSIGPIPE, 1)

    // Serial queue for pipe writes — thread-safe and preserves ordering.
    let writeQueue = DispatchQueue(label: "com.rootshell.croc-bridge.write")
    let writeFd = pipeWriteFd

    nonisolated(unsafe) var exitStatus: Int32 = 0
    nonisolated(unsafe) var writeClosed = false

    // Thread-safe output closure that writes to the pipe.
    let pipeOutput: @Sendable (String) -> Void = { text in
        let unix = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = unix.data(using: .utf8) else { return }
        writeQueue.sync {
            guard !writeClosed else { return }
            data.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress else { return }
                var remaining = buf.count
                var offset = 0
                while remaining > 0 {
                    let written = write(writeFd, ptr + offset, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        writeClosed = true
                        break
                    }
                    if written == 0 { break }
                    offset += written
                    remaining -= written
                }
            }
        }
    }

    let pipeOutputData: @Sendable (Data) -> Void = { data in
        writeQueue.sync {
            guard !writeClosed else { return }
            data.withUnsafeBytes { buf in
                guard let ptr = buf.baseAddress else { return }
                var remaining = buf.count
                var offset = 0
                while remaining > 0 {
                    let written = write(writeFd, ptr + offset, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        writeClosed = true
                        break
                    }
                    if written == 0 { break }
                    offset += written
                    remaining -= written
                }
            }
        }
    }

    // Launch CrocClient on a detached task (no MainActor).
    Task.detached {
        var failed = false
        do {
            switch parseResult {
            case .send(let options, let paths):
                let client = CrocClient(options: options, output: pipeOutput, outputData: pipeOutputData)
                // No interactive prompts in ios_system path.
                if options.sendingText {
                    let tempPath = NSTemporaryDirectory() + "croc-stdin-\(UUID().uuidString)"
                    try options.text.write(toFile: tempPath, atomically: true, encoding: .utf8)
                    defer { try? FileManager.default.removeItem(atPath: tempPath) }
                    try await client.send(paths: [tempPath])
                } else {
                    try await client.send(paths: paths)
                }

            case .receive(let options):
                var opts = options
                opts.noPrompt = true  // Auto-accept in non-interactive ios_system path
                let client = CrocClient(options: opts, output: pipeOutput, outputData: pipeOutputData)
                try await client.receive(code: opts.sharedSecret)

            case .relay(let options):
                let client = CrocClient(options: options, output: pipeOutput, outputData: pipeOutputData)
                try await client.startRelay()

            default:
                break
            }
        } catch let error as CrocError where error.isCancellation {
            // Cancelled — not a failure.
        } catch is CancellationError {
            // Cooperative task cancellation.
        } catch {
            pipeOutput("croc: \(error.localizedDescription)\n")
            failed = true
        }

        exitStatus = failed ? 1 : 0
        writeQueue.sync {
            guard !writeClosed else { return }
            writeClosed = true
            close(writeFd)
        }
    }

    // Read loop: pipe read-end → ios_get_thread_stdout()
    // Blocks on this (ios_system) thread until the task closes the write-end.
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
        close(pipeReadFd)
        for path in cleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    while true {
        let bytesRead = read(pipeReadFd, buffer, bufferSize)
        if bytesRead > 0 {
            fwrite(buffer, 1, bytesRead, threadStdout)
            fflush(threadStdout)
        } else if bytesRead == 0 {
            break // EOF — command completed
        } else {
            if errno == EINTR { continue }
            break
        }
    }

    return exitStatus
}

// MARK: - Helpers

private let crocBridgeLogger = Logger(subsystem: "com.rootshell.croc", category: "croc-bridge")

private func crocOutputStreamForCurrentThread() -> UnsafeMutablePointer<FILE> {
    return ios_get_thread_stdout()
}

private func crocWriteOutput(_ text: String) {
    let stream = crocOutputStreamForCurrentThread()
    fputs(text, stream)
    fflush(stream)
}

private func crocStdinPayload() -> Result<Data?, Error> {
    guard let stdinFile = ios_get_thread_stdin() else {
        return .success(nil)
    }

    let fd = fileno(stdinFile)
    guard fd >= 0, isatty(fd) == 0 else {
        return .success(nil)
    }

    var fileStatus = stat()
    if fstat(fd, &fileStatus) != 0 {
        return .success(nil)
    }

    let fileType = fileStatus.st_mode & S_IFMT
    if fileType != S_IFREG {
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollDescriptor, 1, 25)
        guard pollResult > 0, (pollDescriptor.revents & Int16(POLLIN)) != 0 else {
            return .success(nil)
        }
    }

    var data = Data()
    let chunkSize = 4096
    let chunkBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { chunkBuffer.deallocate() }

    while true {
        let readCount = fread(chunkBuffer, 1, chunkSize, stdinFile)
        if readCount > 0 {
            data.append(chunkBuffer, count: readCount)
        }
        if readCount < chunkSize {
            if feof(stdinFile) != 0 {
                break
            }
            if ferror(stdinFile) != 0 {
                return .failure(CrocError.ioError("failed reading stdin"))
            }
        }
    }

    return .success(data.isEmpty ? nil : data)
}

private func crocPrepareParseResult(
    _ parseResult: CrocCommandParser.ParseResult,
    stdinData: Data?,
    cleanupPaths: inout [String]
) -> CrocCommandParser.ParseResult {
    guard case .send(let options, let paths) = parseResult,
          !options.sendingText,
          paths.isEmpty,
          !options.ignoreStdin,
          let stdinData,
          !stdinData.isEmpty else {
        return parseResult
    }

    let tempPath = NSTemporaryDirectory() + "croc-stdin-\(UUID().uuidString)"
    do {
        try stdinData.write(to: URL(fileURLWithPath: tempPath))
        cleanupPaths.append(tempPath)
        return .send(options, paths: [tempPath])
    } catch {
        return .error("failed to capture stdin: \(error.localizedDescription)")
    }
}

/// Reconstruct the full command string from argc/argv.
private func crocReconstructCommand(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> String {
    var parts: [String] = ["croc"]
    let safeArgc = max(0, Int(argc))

    if safeArgc > 1, let argv {
        for i in 1..<safeArgc {
            if let arg = argv[i], let decoded = String(validatingUTF8: arg) {
                parts.append(decoded)
            }
        }
    }

    return parts.joined(separator: " ")
}

#endif
