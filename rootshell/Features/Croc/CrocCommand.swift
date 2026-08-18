#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// MainActor command wrapper for croc.
/// Manages lifecycle: start → run → cancel/complete.
///
/// The actual transfer work runs on a **detached** task (off MainActor) via
/// `CrocClient`.  Only the thin lifecycle/cancel/finish shell lives here.
///
/// Output closures are `@Sendable` and called directly from the background
/// task — no MainActor hop per output call.
@MainActor
final class CrocCommand {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell.croc", category: "CrocCommand")

    /// @Sendable output closures — called directly from CrocClient's background
    /// task without hopping to MainActor.  The terminal's onOutput callback is
    /// already @Sendable and thread-safe.
    let output: @Sendable (String) -> Void
    let outputData: @Sendable (Data) -> Void

    /// Called when the command completes (success, failure, or cancellation).
    var onComplete: (() -> Void)?

    /// Called when user input is needed (accept/reject, resume, etc.)
    /// This DOES need MainActor because it mutates session state (crocPromptHandler).
    var onPrompt: ((String, @escaping @Sendable (String) -> Void) -> Void)?

    /// Whether the command failed.
    private(set) var didFail = false
    private var hasCompleted = false

    private var task: Task<Void, Never>?
    private var client: CrocClient?
    private let parseResult: CrocCommandParser.ParseResult

    init(
        parseResult: CrocCommandParser.ParseResult,
        output: @escaping @Sendable (String) -> Void,
        outputData: (@Sendable (Data) -> Void)? = nil
    ) {
        self.parseResult = parseResult
        self.output = output
        self.outputData = outputData ?? { data in
            output(String(decoding: data, as: UTF8.self))
        }
    }

    /// Start the croc command.
    func start() {
        let parseResult = self.parseResult
        let output = self.output
        let outputData = self.outputData

        // Build the client — CrocClient is NOT @MainActor.
        let client: CrocClient
        switch parseResult {
        case .send(let options, _), .receive(let options), .relay(let options):
            client = CrocClient(options: options, output: output, outputData: outputData)
        default:
            handleSynchronous(parseResult)
            return
        }
        self.client = client

        // Wire up prompt callback.  Prompts need MainActor because the
        // response handler is stored on the session (crocPromptHandler).
        if let onPrompt = self.onPrompt {
            client.onPrompt = { prompt, respond in
                Task { @MainActor in
                    onPrompt(prompt, respond)
                }
            }
        }

        // Launch the transfer on a detached task — all heavy work (network,
        // crypto, file I/O) runs on the cooperative thread pool.
        task = Task.detached { [weak self] in
            var failed = false
            do {
                switch parseResult {
                case .send(let options, let paths):
                    if options.sendingText {
                        let tempPath = NSTemporaryDirectory() + "croc-stdin-\(UUID().uuidString)"
                        try options.text.write(toFile: tempPath, atomically: true, encoding: .utf8)
                        defer { try? FileManager.default.removeItem(atPath: tempPath) }
                        try await client.send(paths: [tempPath])
                    } else {
                        try await client.send(paths: paths)
                    }
                case .receive(let options):
                    try await client.receive(code: options.sharedSecret)
                case .relay:
                    try await client.startRelay()
                default:
                    break
                }
            } catch let error as CrocError where error.isCancellation {
                // User cancelled — not a failure.
            } catch is CancellationError {
                // Cooperative task cancellation.
            } catch {
                output("croc: \(error.localizedDescription)\r\n")
                failed = true
            }

            // Hop back to MainActor only for lifecycle cleanup.
            let didFail = failed
            await MainActor.run { [weak self] in
                self?.finish(failed: didFail)
            }
        }
    }

    /// Cancel the running command (CTRL-C).
    func cancel() {
        client?.cancel()
        task?.cancel()
        output("^C\r\n")
        // For relay, let the detached task finish after awaiting clean relay
        // shutdown so the "Relay stopped." message prints before the prompt.
        if case .relay = parseResult {
            return
        }
        finish(failed: false)
    }

    private func finish(failed: Bool? = nil) {
        guard !hasCompleted else { return }
        hasCompleted = true
        if let failed {
            didFail = failed
        }
        onComplete?()
    }

    private func handleSynchronous(_ result: CrocCommandParser.ParseResult) {
        switch result {
        case .print(let text, let exitCode):
            output(text)
            finish(failed: exitCode != 0)
        case .help:
            output(CrocCommandParser.helpText)
            finish(failed: false)
        case .error(let message):
            output("croc: \(message)\r\n")
            finish(failed: true)
        default:
            finish(failed: false)
        }
    }
}

#endif
