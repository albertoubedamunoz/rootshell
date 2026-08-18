#if !CHINA_BUILD
//
//  IOSLocalExecutor.swift
//  rootshell
//
//  Executes commands locally via ios_system for the AI Agent
//  iOS and visionOS only
//

#if !targetEnvironment(macCatalyst)

import Foundation
import os.log

/// Errors during iOS local command execution
enum IOSLocalExecutorError: LocalizedError, Sendable {
    case notConnected
    case commandFailed(exitCode: Int32)
    case timeout
    case cancelled
    case pipeCreationFailed
    case streamCreationFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "iOS local executor is not connected"
        case .commandFailed(let code):
            return "Command exited with code \(code)"
        case .timeout:
            return "Command execution timed out"
        case .cancelled:
            return "Command execution cancelled"
        case .pipeCreationFailed:
            return "Failed to create pipes for command I/O"
        case .streamCreationFailed:
            return "Failed to create FILE streams for command I/O"
        }
    }
}

/// Executes commands locally via ios_system for the AI Agent
/// Matches the interface of CatalystLocalExecutor for drop-in replacement
@MainActor
final class IOSLocalExecutor {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "IOSLocalExecutor")

    /// Default command timeout in seconds
    private nonisolated static let defaultTimeout: TimeInterval = 30

    /// Maximum output length to prevent memory issues (sent to AI)
    private nonisolated static let maxOutputLength = 100_000

    /// Maximum display length for UI (prevents SwiftUI slowdowns)
    private nonisolated static let maxDisplayLength = 10_000

    /// Minimum interval between UI updates during streaming (500ms)
    private nonisolated static let uiUpdateInterval: CFAbsoluteTime = 0.5

    /// Regex pattern for stripping ANSI escape sequences
    private nonisolated static let ansiPattern = try! NSRegularExpression(
        pattern: "\\x1b\\[[0-9;]*[a-zA-Z]|\\x1b\\][^\u{07}]*\u{07}|\\x1b\\[[0-9;]*[ -/]*[@-~]",
        options: []
    )

    /// Current execution task (for cancellation)
    private var currentTask: Task<CommandExecutionResult, Error>?

    /// Live ios_command handle, protected by handleLock. disconnect() kills
    /// it so the blocking ios_command_wait actually returns — Swift task
    /// cancellation alone never interrupts it.
    private nonisolated(unsafe) var currentCommandHandle: OpaquePointer?
    private nonisolated let handleLock = UnfairLock()

    /// Session identifier for ios_system session isolation
    private let sessionID = UUID()

    /// Session pointer derived from sessionID
    private var sessionPtr: UnsafeRawPointer? {
        IOSSystemSessionKey.key(for: sessionID)
    }

    /// User's login shell (for interface compatibility — always nil on iOS)
    var sessionShell: String?

    /// Whether the executor is "connected" (session is configured)
    private var isConnected = false

    /// Serial dispatch queue for blocking ios_system calls
    private let commandQueue = DispatchQueue(label: "com.rootshell.aiagent.ios-executor", qos: .userInitiated)

    init() {}

    deinit {
        // Cleanup happens via disconnect()
    }

    // MARK: - Connection Management

    /// Configure ios_system session for this executor
    /// - Parameter workingDirectory: Initial working directory (from terminal CWD), defaults to Documents
    func connect(workingDirectory: String? = nil) async throws {
        guard !isConnected else { return }

        Self.logger.info("Connecting IOSLocalExecutor")

        let ptr = sessionPtr
        ios_switchSession(ptr)

        // Set environment variables
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Deliberately pinned rather than reading TerminalTypeSettings.local:
        // this is a non-interactive harness whose output the agent parses, and
        // it already fixes COLUMNS/LINES for the same reason.
        ios_setenv("TERM", "xterm-256color", 1)
        ios_setenv("HOME", documentsPath, 1)
        ios_setenv("COLUMNS", "200", 1)
        ios_setenv("LINES", "50", 1)

        // Set SSL certificate file path for curl HTTPS support
        if let cacertPath = CurlResourceManager.shared.cacertPath {
            ios_setenv("SSL_CERT_FILE", cacertPath, 1)
        }

        // Configure PATH
        let paths = [
            documentsPath,
            "\(documentsPath)/bin",
            "/usr/bin",
            "/bin",
            "/usr/local/bin"
        ]
        ios_setenv("PATH", paths.joined(separator: ":"), 1)

        // Set ios_system's mini root FIRST (resets CWD to miniroot)
        ios_setMiniRoot(documentsPath)

        // Set working directory — use provided CWD if valid, otherwise Documents
        let cwdPath: String
        if let wd = workingDirectory, FileManager.default.fileExists(atPath: wd) {
            cwdPath = wd
            ios_setDirectoryURL(URL(fileURLWithPath: wd))
        } else {
            cwdPath = documentsPath
            ios_setDirectoryURL(documentsURL)
        }
        ios_setenv("PWD", cwdPath, 1)

        // Configure bookmarked external locations
        BookmarkedLocationsManager.shared.configureIOSSystem()

        // Set window size for the session
        ios_setWindowSize(200, 50, ptr)

        isConnected = true
        Self.logger.info("IOSLocalExecutor connected")
    }

    /// Disconnect and clean up the ios_system session
    func disconnect() async {
        Self.logger.debug("Disconnecting IOSLocalExecutor")
        currentTask?.cancel()
        currentTask = nil

        // Kill the running command — task cancellation never interrupts the
        // blocking ios_command_wait, so without this a long/wedged command
        // keeps the queue (and the deferred teardown below) hostage.
        handleLock.withLock {
            if let handle = currentCommandHandle {
                ios_command_kill(handle)
            }
        }

        // Drain commandQueue before closing: a blocking command closure may
        // still be running and holds the session pointer (task cancellation
        // doesn't interrupt it). Close and release only once the queue is
        // confirmed idle. On timeout, defer BOTH — closing a session a live
        // command is using is as unsafe as freeing its key — and let the
        // drained queue finish the teardown when the command eventually ends.
        let queueIdle = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let done = DispatchSemaphore(value: 0)
            commandQueue.async { done.signal() }
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: done.wait(timeout: .now() + 3.0) == .success)
            }
        }

        if queueIdle {
            ios_closeSession(sessionPtr)
            IOSSystemSessionKey.release(sessionID)
        } else {
            Self.logger.warning("disconnect: commandQueue busy after 3s — deferring session teardown")
            let sessionID = self.sessionID
            commandQueue.async {
                ios_closeSession(IOSSystemSessionKey.key(for: sessionID))
                IOSSystemSessionKey.release(sessionID)
            }
        }

        isConnected = false
    }

    // MARK: - Command Execution

    /// Execute a command and return the output
    func execute(command: String, timeout: TimeInterval = defaultTimeout) async throws -> CommandExecutionResult {
        return try await executeStreaming(command: command, timeout: timeout) { _ in }
    }

    /// Execute a command with streaming output
    func executeStreaming(
        command: String,
        timeout: TimeInterval = defaultTimeout,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws -> CommandExecutionResult {
        guard isConnected else {
            throw IOSLocalExecutorError.notConnected
        }

        let startTime = Date()
        // Opaque ios_system session handle; it carries no Sendable conformance
        // but is stable for the lifetime of this executor.
        nonisolated(unsafe) let capturedSessionPtr = sessionPtr

        Self.logger.info("Executing command: \(command.prefix(100))...")

        let task = Task<CommandExecutionResult, Error> {
            var accumulatedOutput = ""

            // Run ios_system on the serial command queue to avoid blocking main actor
            let (rawOutput, commandExitCode) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, Int32), Error>) in
                self.commandQueue.async {
                    // Create pipes
                    var stdoutPipe: [Int32] = [-1, -1]
                    var stderrPipe: [Int32] = [-1, -1]

                    guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
                        continuation.resume(throwing: IOSLocalExecutorError.pipeCreationFailed)
                        return
                    }

                    let stdoutReadFd = stdoutPipe[0]
                    let stderrReadFd = stderrPipe[0]

                    // Create FILE* for ios_system
                    guard let stdoutFile = fdopen(stdoutPipe[1], "w"),
                          let stderrFile = fdopen(stderrPipe[1], "w") else {
                        close(stdoutPipe[0]); close(stdoutPipe[1])
                        close(stderrPipe[0]); close(stderrPipe[1])
                        continuation.resume(throwing: IOSLocalExecutorError.streamCreationFailed)
                        return
                    }

                    // Set unbuffered
                    setvbuf(stdoutFile, nil, _IONBF, 0)
                    setvbuf(stderrFile, nil, _IONBF, 0)

                    // Drain the pipes concurrently while the command runs —
                    // reading only after ios_command_wait deadlocks the child
                    // once output exceeds the 64KB pipe buffer. The reader
                    // also streams throttled progress to the UI.
                    let outputLock = UnfairLock()
                    var streamedOutput = ""
                    let readerDone = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let bufferSize = 16384
                        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                        defer { buffer.deallocate() }
                        var lastUIUpdate: CFAbsoluteTime = 0
                        // Carries multibyte sequences split across read() chunks
                        let decoder = StreamingUTF8Decoder()
                        for fd in [stdoutReadFd, stderrReadFd] {
                            while true {
                                let bytesRead = read(fd, buffer, bufferSize)
                                guard bytesRead > 0 else { break }
                                let str = decoder.decode(Data(bytes: buffer, count: bytesRead))
                                guard !str.isEmpty else { continue }
                                let snapshot = outputLock.withLock { () -> String? in
                                    streamedOutput += str
                                    let now = CFAbsoluteTimeGetCurrent()
                                    guard now - lastUIUpdate >= 0.3 else { return nil }
                                    lastUIUpdate = now
                                    return streamedOutput
                                }
                                if let snapshot {
                                    let display = Self.truncateForDisplay(Self.stripANSI(snapshot))
                                    Task { @MainActor in onOutput(display) }
                                }
                            }
                            close(fd)
                        }
                        let tail = decoder.flush()
                        if !tail.isEmpty {
                            outputLock.withLock { streamedOutput += tail }
                        }
                        readerDone.signal()
                    }

                    // Switch to our session
                    ios_switchSession(capturedSessionPtr)

                    // Set streams — use same file for stdout and stderr
                    ios_setStreams(stdin, stdoutFile, stdoutFile)

                    // Configure async execution. The caller's timeout bounds
                    // the C-side wait too, so a wedged command can't park
                    // this queue (and block disconnect) forever.
                    var options = ios_async_default_options()
                    options.output = stdoutFile
                    options.error = stdoutFile
                    options.session = UnsafeMutableRawPointer(mutating: capturedSessionPtr)
                    options.timeout_ms = timeout > 0 ? Int32(timeout * 1000) : -1

                    // Execute command
                    let cmdHandle = ios_system_async(command, &options)

                    // Wait for completion, exposing the handle so disconnect()
                    // can kill it (clear under lock before release)
                    var exitCode: Int32 = -1
                    if let handle = cmdHandle {
                        self.handleLock.withLock { self.currentCommandHandle = handle }
                        exitCode = ios_command_wait(handle)
                        self.handleLock.withLock { self.currentCommandHandle = nil }
                        ios_command_release(handle)
                    }

                    // Reset streams before closing
                    ios_setStreams(stdin, stdout, stderr)

                    // Flush and close write ends (signals EOF to the reader)
                    fflush(stdoutFile)
                    fflush(stderrFile)
                    fclose(stdoutFile)
                    fclose(stderrFile)

                    // Wait for the reader to see EOF and finish draining
                    readerDone.wait()
                    let output = outputLock.withLock { streamedOutput }

                    continuation.resume(returning: (output, exitCode))
                }
            }

            // Strip ANSI escape sequences from output
            accumulatedOutput = Self.stripANSI(rawOutput)

            // Final UI update
            let displayOutput = Self.truncateForDisplay(accumulatedOutput)
            onOutput(displayOutput)

            // Truncate final output for AI context
            let finalOutput = String(accumulatedOutput.prefix(Self.maxOutputLength))
            let duration = Date().timeIntervalSince(startTime)

            return CommandExecutionResult(
                output: finalOutput,
                exitCode: Int(commandExitCode),
                duration: duration
            )
        }

        currentTask = task

        do {
            let result = try await task.value
            currentTask = nil

            let outputPreview = result.output.prefix(100)
            Self.logger.debug("Command completed in \(result.duration)s, output: \(outputPreview)...")
            return result
        } catch is CancellationError {
            currentTask = nil
            throw IOSLocalExecutorError.cancelled
        } catch {
            currentTask = nil
            throw error
        }
    }

    /// Cancel any currently executing command
    func cancel() {
        currentTask?.cancel()
        currentTask = nil

        // Task cancellation never interrupts the blocking ios_command_wait —
        // kill the command so the serial queue frees up for the next one.
        handleLock.withLock {
            if let handle = currentCommandHandle {
                ios_command_kill(handle)
            }
        }
    }

    // MARK: - Private Helpers

    /// Strip ANSI escape sequences from output
    private nonisolated static func stripANSI(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return ansiPattern.stringByReplacingMatches(in: input, range: range, withTemplate: "")
    }

    /// Truncate output for display (keep most recent characters)
    private nonisolated static func truncateForDisplay(_ output: String) -> String {
        if output.count <= Self.maxDisplayLength {
            return output
        }
        return "... (truncated)\n" + String(output.suffix(Self.maxDisplayLength - 20))
    }
}

#endif // !targetEnvironment(macCatalyst)
#endif
