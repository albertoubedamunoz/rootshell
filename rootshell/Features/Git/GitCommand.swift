#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog

/// Shared one-time libgit2 initialization.
/// Used by both `GitCommand` (intercepted path) and `git_main` (ios_system path).
enum GitInitializer {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "git")

    static let initOnce: Void = {
        git_libgit2_init()
        let sshResult = git_ssh_custom_transport_register()
        if sshResult != 0 {
            logger.warning("Failed to register SSH transport: \(sshResult)")
        }
    }()
}

/// Runs a git subcommand on a background queue, sending styled output to
/// the terminal. Follows the PingCommand pattern: @MainActor, self-contained,
/// concurrent-safe per tab.
@MainActor
final class GitCommand {
    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "git")

    let config: GitCommandParser.GitCommandConfig
    let cols: UInt16
    let output: @Sendable (String) -> Void
    var onComplete: (() -> Void)?
    var onPagedComplete: ((String) -> Void)?
    var onEditorNeeded: ((GitEditorRequest) -> Void)?
    private(set) var lastExitCode: Int32 = 0

    /// SSH connection override for this specific git command.
    /// Set before `start()` by the caller; installed as a thread-local on the
    /// commandQueue so the subtransport factory picks it up for this instance only.
    var connectionOverride: GitConnectionOverride?

    private let commandQueue = DispatchQueue(label: "com.rootshell.git", qos: .userInitiated)
    private var isCancelled = false

    /// Subcommands that should use the pager by default.
    private static let pagedSubcommands: Set<String> = ["diff", "log", "blame", "reflog"]

    /// Whether this command should buffer output for paging.
    var shouldPage: Bool {
        !config.noPager && Self.pagedSubcommands.contains(config.subcommand)
    }

    /// Thread-safe append-only buffer for paged output.
    /// Only accessed from the serial `commandQueue`, so no locking needed.
    private nonisolated final class PagedOutputBox: @unchecked Sendable {
        var buffer = ""
        func append(_ text: String) { buffer += text }
    }

    init(config: GitCommandParser.GitCommandConfig,
         cols: UInt16,
         output: @escaping @Sendable (String) -> Void) {
        self.config = config
        self.cols = cols
        self.output = output
    }

    /// Start executing the git command on a background queue.
    func start() {
        // Ensure libgit2 is initialized (ref-counted, thread-safe)
        _ = GitInitializer.initOnce

        let subcommand = config.subcommand
        let args = config.args
        let workDir = config.workingDirectory
        let termCols = cols
        let paging = shouldPage

        // When paging, buffer output instead of streaming it
        let pagedBox: PagedOutputBox? = paging ? PagedOutputBox() : nil
        let outputCb: @Sendable (String) -> Void = if let pagedBox {
            { text in pagedBox.append(text) }
        } else {
            output
        }

        let override = connectionOverride
        commandQueue.async { [weak self] in
            // Install connection override as thread-local so the subtransport
            // factory (called by libgit2 on this thread) picks it up.
            GitConnectionOverride.setForCurrentThread(override)
            defer { GitConnectionOverride.setForCurrentThread(nil) }

            // Per-invocation init/shutdown (ref-counted)
            git_libgit2_init()
            defer { git_libgit2_shutdown() }

            let exitCode: Int32

            if subcommand == "version" {
                let major = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                let minor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                let rev = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                defer { major.deallocate(); minor.deallocate(); rev.deallocate() }

                git_libgit2_version(major, minor, rev)
                outputCb("git (libgit2 \(major.pointee).\(minor.pointee).\(rev.pointee))\r\n")
                exitCode = 0
            } else {
                do {
                    exitCode = try GitCommandDispatch.run(
                        subcommand: subcommand,
                        workingDirectory: workDir,
                        args: args,
                        cols: termCols,
                        output: outputCb,
                        statusOutput: outputCb,
                        progressDefault: true
                    )
                } catch let error as GitError {
                    if case .editorNeeded(let request) = error {
                        Self.logger.info("git \(subcommand) requesting editor for \(request.filePath)")
                        Task { @MainActor [weak self] in
                            self?.onEditorNeeded?(request)
                        }
                        return  // Don't call onComplete — editor flow handles completion
                    }
                    outputCb(error.styledDescription)
                    exitCode = 1
                } catch {
                    outputCb(GitStyle.fg(GitStyle.errorColor, "fatal: \(error.localizedDescription)\r\n"))
                    exitCode = 1
                }
            }

            let code = exitCode
            Self.logger.debug("git \(subcommand) exited with code \(code)")

            // Assign on the MainActor right before the completion callbacks
            // (which read lastExitCode) so the property stays MainActor-isolated.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastExitCode = code
                if let pagedBox, !pagedBox.buffer.isEmpty {
                    self.onPagedComplete?(pagedBox.buffer)
                } else {
                    self.onComplete?()
                }
            }
        }
    }

    /// Cancel the running command.
    func cancel() {
        isCancelled = true
        output("^C\r\n")
        onComplete?()
    }
}

#endif
