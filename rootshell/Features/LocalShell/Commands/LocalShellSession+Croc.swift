#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {

    /// Handle a croc command (send, receive, or relay).
    func handleCrocCommand(_ command: String) {
        let result = CrocCommandParser.parse(command: command)

        switch result {
        case .send, .receive, .relay:
            // Capture the @Sendable output callback directly — no MainActor
            // hop needed since onOutput is already thread-safe.
            let outputCb = self.onOutput ?? { _ in }
            let outputDataCb = self.onOutputData
            let crocCommand = CrocCommand(
                parseResult: result,
                output: outputCb,
                outputData: outputDataCb
            )

            crocCommand.onComplete = { [weak self] in
                guard let self else { return }
                self.activeCrocCommand = nil
                self.sessionMode = .localShell
                self.lastCommandSucceeded = !crocCommand.didFail
                self.scriptCommandExitCode = crocCommand.didFail ? 1 : 0

                guard self.isRunning else { return }
                self.onTitleChange?(self.formatPathForTitle(sessionCurrentDirectory))
                self.displayPrompt()
            }

            // Handle user prompts (accept/reject files, resume, etc.)
            crocCommand.onPrompt = { [weak self] prompt, respond in
                guard let self else { respond("n"); return }
                self.onOutput?(prompt)
                // Store the response handler for when user provides input
                self.crocPromptHandler = respond
            }

            sessionMode = .crocRunning
            activeCrocCommand = crocCommand

            let cmdDisplay = String(command.prefix(30))
            onTitleChange?(cmdDisplay)

            crocCommand.start()

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            onOutput?(normalizeLineEndings(CrocCommandParser.helpText))
            displayPrompt()

        case .print(let text, let exitCode):
            lastCommandSucceeded = exitCode == 0
            scriptCommandExitCode = Int32(exactly: exitCode)
            onOutput?(normalizeLineEndings(text))
            displayPrompt()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?("croc: \(message)\r\n")
            displayPrompt()
        }
    }
}

#endif
