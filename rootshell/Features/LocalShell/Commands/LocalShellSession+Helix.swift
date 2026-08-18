#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Handle an `hx` command
    func handleHelixCommand(_ command: String) {
        let result = HelixCommandParser.parse(command: command, workingDirectory: sessionCurrentDirectory)

        switch result {
        case .launch(let config):
            launchHelix(config: config)

        case .help:
            displayHelixHelp()

        case .version:
            displayHelixVersion()

        case .error(let message):
            onOutput?("\r\nhx: \(message)\r\n")
            displayPrompt()
        }
    }

    private func launchHelix(config: HelixLaunchConfig) {
        // Capture outputSink directly — it's nonisolated and @unchecked Sendable,
        // safe to call from HelixCommand's detached output reader task.
        let sink = self.outputSink
        let helixCommand = HelixCommand(
            config: config,
            cols: pty.windowSize.cols,
            rows: pty.windowSize.rows,
            onOutput: { data in
                sink.emit(data)
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.activeHelixCommand = nil
                self.sessionMode = .localShell

                guard self.isRunning else { return }
                self.onTitleChange?(self.formatPathForTitle(sessionCurrentDirectory))
                self.displayPrompt()
            }
        )

        sessionMode = .helixRunning
        activeHelixCommand = helixCommand

        // Update tab title
        let title = config.displayTitle
        onTitleChange?("hx \(title)")

        helixCommand.start()
    }

    /// Display the Helix version from the Rust FFI
    private func displayHelixVersion() {
        var versionString = "helix (unknown version)"
        if let cStr = helix_version() {
            versionString = "helix \(String(cString: cStr))"
        }
        onOutput?("\r\n\(versionString)\r\n")
        displayPrompt()
    }

    /// Display hx usage help
    func displayHelixHelp() {
        let helpText = """

usage: hx [FLAGS] [files]...

Helix - A post-modern text editor

Arguments:
  [files]...    Sets the input file(s) to use, position with +row or +row:col or file:row:col

Options:
      --tutor                 Opens the tutorial
      --vsplit                Splits all given files vertically into different windows
      --hsplit                Splits all given files horizontally into different windows
  -c, --config <file>         Specifies a file to use for config
      --log <file>            Specifies a file to use for logging
  -w, --working-dir <path>    Specify an initial working directory
  -v                          Increases logging verbosity each use (up to -vvv)
  -V, --version               Prints version information
  -h, --help                  Prints help information

  -g, --grammar <fetch|build> Fetch or build tree-sitter grammars
      --health [CATEGORY]     Check for potential errors in editor setup
                              CATEGORY can be a language or one of 'clipboard',
                              'languages', 'all-languages' or 'all'

"""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif // !targetEnvironment(macCatalyst)
