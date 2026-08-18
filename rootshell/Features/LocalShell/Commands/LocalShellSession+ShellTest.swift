#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - shelltest command

/// `shelltest` runs the shell interpreter conformance suite on-device.
///
/// Usage:
///   shelltest              — pure-interpreter tier (deterministic, no ios_system)
///   shelltest external     — also run cases that exercise real ios_system commands
///   shelltest <id-prefix>  — run only cases whose id starts with the prefix
extension LocalShellSession {

    func handleShellTestCommand(_ command: String) {
        sessionMode = .scriptRunning
        onTitleChange?("shelltest")
        let arguments = command.split(separator: " ").dropFirst().map(String.init)
        commandQueue.async { [weak self] in
            self?.runShellConformanceSuite(arguments: arguments)
        }
    }

    nonisolated private func runShellConformanceSuite(arguments: [String]) {
        guard !hasStopped else { return }
        scriptCancellationToken.reset()

        let includeExternal = arguments.contains("external") || arguments.contains("--external")
        let filter = arguments.first { $0 != "external" && $0 != "--external" }

        var hooks: ShellConformanceTest.ExternalHooks?
        if includeExternal {
            hooks = ShellConformanceTest.ExternalHooks(
                executeExternal: { [weak self] cmd in
                    self?.runScriptExternalCommand(cmd) ?? 127
                },
                captureExternal: { [weak self] cmd in
                    self?.captureCommandOutput(cmd) ?? (127, "")
                }
            )
        }

        let summary = ShellConformanceTest.run(
            filter: filter,
            hooks: hooks,
            isCancelled: { [weak self] in
                guard let self else { return true }
                return self.scriptCancellationToken.isCancelled || self.hasStopped
            },
            emit: { [weak self] line in
                guard let self else { return }
                let terminal = line.replacingOccurrences(of: "\n", with: "\r\n")
                self.outputBatcher.enqueue(Data(terminal.utf8))
            }
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = summary.failed == 0 && !summary.aborted
            self.lastCommandSucceeded = ok
            self.scriptCommandExitCode = ok ? 0 : 1
            self.recoverFromScriptExecution()
        }
    }
}

#endif
