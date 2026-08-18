#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Sendable wrapper for OpaquePointer (Helix handle) that must cross
/// actor boundaries for background cleanup. Safety: the handle is only
/// ever used by one thread at a time after transfer.
private struct SendableHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Manages a single Helix editor instance running on a background thread.
///
/// Each instance owns a pair of pipes for communication:
/// - Input pipe: Swift writes keystrokes → Helix reads terminal input
/// - Output pipe: Helix writes ANSI output → Swift reads and forwards to Ghostty
///
/// The Helix editor runs on a dedicated Rust thread with its own tokio runtime,
/// enabling multiple independent editors across terminal tabs.
@MainActor
final class HelixCommand {
    nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "helix")

    private let config: HelixLaunchConfig
    private var handle: OpaquePointer? // HelixHandle*

    // Pipe FDs: Swift owns the write end of input and read end of output.
    // Helix owns the read end of input and write end of output.
    private var inputWriteFd: Int32 = -1
    private var outputReadFd: Int32 = -1

    private var outputTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    var onOutput: (@Sendable (Data) -> Void)?
    var onComplete: (() -> Void)?

    private let cols: UInt16
    private let rows: UInt16

    init(config: HelixLaunchConfig, cols: UInt16, rows: UInt16,
         onOutput: (@Sendable (Data) -> Void)?, onComplete: (() -> Void)?) {
        self.config = config
        self.cols = cols
        self.rows = rows
        self.onOutput = onOutput
        self.onComplete = onComplete
    }

    func start() {
        // Create pipe pairs
        var inPipe: [Int32] = [0, 0]
        var outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else {
            Self.logger.error("Failed to create pipes for Helix")
            onComplete?()
            return
        }

        // inPipe[0] = read end (Helix reads input) — ownership transfers to Rust
        // inPipe[1] = write end (Swift writes keystrokes) — we keep this
        // outPipe[0] = read end (Swift reads output) — we keep this
        // outPipe[1] = write end (Helix writes ANSI) — ownership transfers to Rust
        inputWriteFd = inPipe[1]
        outputReadFd = outPipe[0]

        let helixInputFd = inPipe[0]
        let helixOutputFd = outPipe[1]

        // Get runtime path from app bundle
        guard let runtimePath = Bundle.main.path(forResource: "helix-runtime", ofType: nil) else {
            Self.logger.error("Helix runtime not found in app bundle")
            let msg = "hx: runtime directory not found in app bundle\r\n"
            onOutput?(Data(msg.utf8))
            // Close all pipe FDs since we're not passing them to Helix
            close(inPipe[0]); close(inPipe[1])
            close(outPipe[0]); close(outPipe[1])
            inputWriteFd = -1
            outputReadFd = -1
            onComplete?()
            return
        }

        // Convert args to C string array and call helix_create_with_args
        let createdHandle: OpaquePointer? = runtimePath.withCString { rtPath in
            // Build C argv array
            let cArgs = config.args.map { strdup($0)! }
            defer { cArgs.forEach { free($0) } }
            let argv: [UnsafePointer<CChar>?] = cArgs.map { UnsafePointer($0) }
            return argv.withUnsafeBufferPointer { buf in
                helix_create_with_args(
                    helixInputFd, helixOutputFd,
                    cols, rows, rtPath,
                    Int32(config.args.count),
                    buf.baseAddress!
                )
            }
        }

        guard let createdHandle else {
            Self.logger.error("helix_create_with_args returned NULL")
            let msg = "hx: failed to create editor instance\r\n"
            onOutput?(Data(msg.utf8))
            // Helix didn't take ownership, close the FDs it would have owned
            close(helixInputFd)
            close(helixOutputFd)
            closePipes()
            onComplete?()
            return
        }

        handle = createdHandle
        let logCols = cols
        let logRows = rows
        Self.logger.info("Helix started: \(logCols)x\(logRows)")

        // Start reading output from Helix
        startOutputReader()

        // Poll for completion
        startCompletionPoll()
    }

    /// Forward raw input bytes to Helix's input pipe
    func sendInput(_ data: Data) {
        guard inputWriteFd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = Darwin.write(inputWriteFd, base, ptr.count)
        }
    }

    /// Notify Helix of a terminal resize
    func resize(cols: UInt16, rows: UInt16) {
        guard let handle else { return }
        helix_resize(handle, cols, rows)
    }

    /// Request graceful shutdown
    func cancel() {
        guard let handle else { return }
        helix_shutdown(handle)
        // Close pipes to unblock the Helix thread immediately.
        // Without this, the thread may be blocked writing to the output pipe
        // and will never check the shutdown flag.
        closePipes()
    }

    /// Read Helix's ANSI output and forward to the terminal
    private func startOutputReader() {
        let readFd = outputReadFd
        let onOutput = onOutput
        outputTask = Task.detached {
            let bufferSize = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while !Task.isCancelled {
                let bytesRead = Darwin.read(readFd, buffer, bufferSize)
                if bytesRead <= 0 { break }
                let data = Data(bytes: buffer, count: bytesRead)
                onOutput?(data)
            }
        }
    }

    /// Poll helix_is_running to detect when the editor exits
    private func startCompletionPoll() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { break }
                guard let handle = self.handle else { break }
                if !helix_is_running(handle) {
                    Self.logger.info("Helix exited")
                    self.cleanup()
                    self.onComplete?()
                    break
                }
            }
        }
    }

    /// Close Swift's ends of the pipes to unblock the Helix thread.
    /// Closing the output read FD causes EPIPE on Helix's next write.
    /// Closing the input write FD causes EOF on Helix's input reader.
    private func closePipes() {
        if inputWriteFd >= 0 {
            close(inputWriteFd)
            inputWriteFd = -1
        }
        if outputReadFd >= 0 {
            close(outputReadFd)
            outputReadFd = -1
        }
    }

    private func cleanup() {
        outputTask?.cancel()
        pollTask?.cancel()
        closePipes()

        // Dispatch helix_destroy to a background thread. It calls thread.join()
        // which blocks until the Helix thread exits — must never block MainActor.
        if let handle {
            self.handle = nil
            let h = SendableHandle(pointer: handle)
            DispatchQueue.global(qos: .utility).async {
                helix_destroy(h.pointer)
            }
        }
    }

    deinit {
        // Close pipes to unblock the Helix thread, then dispatch destroy
        // to a background thread so we never block the MainActor on join().
        let sendableH = handle.map { SendableHandle(pointer: $0) }
        let inFd = inputWriteFd
        let outFd = outputReadFd
        if sendableH != nil || inFd >= 0 || outFd >= 0 {
            DispatchQueue.global(qos: .utility).async {
                if inFd >= 0 { close(inFd) }
                if outFd >= 0 { close(outFd) }
                if let sendableH {
                    helix_shutdown(sendableH.pointer)
                    helix_destroy(sendableH.pointer)
                }
            }
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
