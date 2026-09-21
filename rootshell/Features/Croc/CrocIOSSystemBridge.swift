#if !targetEnvironment(macCatalyst)

import Darwin
import Foundation

// MARK: - ios_system entry point

/// Entry point for `croc` when invoked via ios_system.
/// CrocClient is async (NWConnection) but not @MainActor, so it runs on a
/// detached task and its output is bridged back through `IOSSystemBridge.pump`.
@_cdecl("croc_main")
func croc_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let commandString = (["croc"] + IOSSystemBridge.arguments(argc: argc, argv: argv))
        .joined(separator: " ")
    let stdinResult = crocStdinPayload()
    if case .failure(let error) = stdinResult {
        IOSSystemBridge.write("croc: \(error.localizedDescription)\n")
        return 1
    }

    var cleanupPaths: [String] = []
    defer {
        for path in cleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    let parseResult = crocPrepareParseResult(
        CrocCommandParser.parse(command: commandString),
        stdinData: try? stdinResult.get(),
        cleanupPaths: &cleanupPaths
    )

    // Handle help/version/error synchronously (no async needed)
    switch parseResult {
    case .help:
        IOSSystemBridge.write(CrocCommandParser.helpText)
        return 0
    case .print(let text, let exitCode):
        IOSSystemBridge.write(text)
        return exitCode
    case .error(let message):
        IOSSystemBridge.write("croc: \(message)\n")
        return 1
    default:
        break
    }

    // Blocking writes: the producer is off MainActor, so let the pipe apply backpressure.
    return IOSSystemBridge.pump(name: "croc", blockingWrites: true) { writer in
        let pipeOutput: @Sendable (String) -> Void = { text in
            writer.write(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
        let pipeOutputData: @Sendable (Data) -> Void = { writer.write($0) }

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

            writer.finish(exitStatus: failed ? 1 : 0)
        }
    }
}

// MARK: - Helpers

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

#endif
