#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    /// Handle an `rf` (rootshell files) command — launch the TUI file browser.
    func handleRFCommand(_ command: String) {
        let result = RFCommandParser.parse(command: command, workingDirectory: sessionCurrentDirectory)

        switch result {
        case .launch(let path):
            let sink = self.outputSink
            let rfCommand = RFCommand(
                initialPath: path,
                cols: pty.windowSize.cols,
                rows: pty.windowSize.rows,
                themeTabId: containingTabId,
                themeWindowId: windowId,
                onOutput: { data in sink.emit(data) },
                onComplete: { [weak self] finalDirectory in
                    guard let self else { return }
                    self.activeRFCommand = nil
                    self.rfShellSuspended = false
                    self.sessionMode = .localShell
                    self.lastCommandSucceeded = true
                    self.scriptCommandExitCode = 0

                    // If rf requested a CWD change (Q key), change the session's directory
                    if let dir = finalDirectory {
                        let sessionPtr = IOSSystemSessionKey.key(for: self.sessionID)
                        ios_switchSession(sessionPtr)
                        chdir(dir)
                        let oldPwd = self.sharedShellEnvironment.getVariable("PWD") ?? ""
                        self.sharedShellEnvironment.setVariable("PWD", value: dir)
                        self.sharedShellEnvironment.exportVariable("PWD", value: dir)
                        self.sharedShellEnvironment.setVariable("OLDPWD", value: oldPwd)
                        self.sharedShellEnvironment.exportVariable("OLDPWD", value: oldPwd)
                    }

                    guard self.isRunning else { return }
                    self.promptCache.invalidate()
                    self.onTitleChange?(self.formatPathForTitle(self.sessionCurrentDirectory))
                    self.displayPrompt()
                },
                onOpenEditor: { [weak self] filePath, editor in
                    guard let self else { return }
                    // rf has already exited alternate screen but we keep activeRFCommand alive
                    // so we can resume after the editor exits.

                    guard self.isRunning else { return }

                    // Launch the editor with a completion handler that resumes rf
                    if editor == "hx" || editor == "helix" {
                        self.launchHelixThenResumeRF(filePath: filePath)
                    } else {
                        // For other editors, run via ios_system then resume rf
                        self.launchEditorThenResumeRF(editor: editor, filePath: filePath)
                    }
                },
                onDropToShell: { [weak self] directory in
                    guard let self else { return }
                    guard self.isRunning else { return }
                    self.dropToShellFromRF(directory: directory)
                },
                onCrocSend: { [weak self] paths in
                    guard let self else { return }
                    guard self.isRunning else { return }
                    self.launchCrocSendThenResumeRF(paths: paths)
                }
            )

            // Route rf's SFTP keyboard-interactive prompts through the shared
            // prompt sheet (via the terminal view), same as every other path.
            rfCommand.onKeyboardInteractiveChallenge = { [weak self] challenge in
                guard let self, let handler = self.onKeyboardInteractiveChallenge else { return nil }
                return await handler(challenge)
            }

            sessionMode = .rfBrowserRunning
            activeRFCommand = rfCommand
            onTitleChange?("rf")

            rfCommand.start()

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayRFHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?("rf: \(message)\r\n")
            displayPrompt()
        }
    }

    /// Launch Helix editor, then resume rf when Helix exits.
    private func launchHelixThenResumeRF(filePath: String) {
        let sink = self.outputSink
        let helixConfig = HelixCommandParser.parse(
            command: "hx \"\(filePath)\"",
            workingDirectory: sessionCurrentDirectory
        )

        guard case .launch(let config) = helixConfig else {
            resumeRF()
            return
        }

        let helixCommand = HelixCommand(
            config: config,
            cols: pty.windowSize.cols,
            rows: pty.windowSize.rows,
            onOutput: { data in sink.emit(data) },
            onComplete: { [weak self] in
                guard let self else { return }
                self.activeHelixCommand = nil
                self.resumeRF()
            }
        )

        sessionMode = .helixRunning
        activeHelixCommand = helixCommand
        onTitleChange?("hx \(config.displayTitle)")
        helixCommand.start()
    }

    /// Launch a non-helix editor via ios_system, then resume rf.
    private func launchEditorThenResumeRF(editor: String, filePath: String) {
        let cmd = "\(editor) \"\(filePath)\""
        sessionMode = .localShell
        commandQueue.async { [weak self] in
            self?.runExternalCommand(cmd)
            Task { @MainActor [weak self] in
                self?.resumeRF()
            }
        }
    }

    /// Launch croc send for the given file paths, then resume rf when done.
    private func launchCrocSendThenResumeRF(paths: [String]) {
        var options = CrocOptions()
        options.isSender = true
        let parseResult = CrocCommandParser.ParseResult.send(options, paths: paths)

        let outputCb = self.onOutput ?? { _ in }
        let outputDataCb = self.onOutputData
        let crocCommand = CrocCommand(
            parseResult: parseResult,
            output: outputCb,
            outputData: outputDataCb
        )

        crocCommand.onComplete = { [weak self] in
            guard let self else { return }
            self.activeCrocCommand = nil
            self.crocPromptHandler = nil
            self.resumeRF()
        }

        crocCommand.onPrompt = { [weak self] prompt, respond in
            guard let self else { respond("n"); return }
            self.onOutput?(prompt)
            self.crocPromptHandler = respond
        }

        sessionMode = .crocRunning
        activeCrocCommand = crocCommand
        onTitleChange?("croc send")
        crocCommand.start()
    }

    /// Drop to an interactive shell from rf, resuming rf on `exit`.
    private func dropToShellFromRF(directory: String) {
        let sessionPtr = IOSSystemSessionKey.key(for: sessionID)
        ios_switchSession(sessionPtr)
        chdir(directory)
        let oldPwd = sharedShellEnvironment.getVariable("PWD") ?? ""
        sharedShellEnvironment.setVariable("PWD", value: directory)
        sharedShellEnvironment.exportVariable("PWD", value: directory)
        sharedShellEnvironment.setVariable("OLDPWD", value: oldPwd)
        sharedShellEnvironment.exportVariable("OLDPWD", value: oldPwd)

        sessionMode = .localShell
        rfShellSuspended = true
        promptCache.invalidate()
        onTitleChange?(formatPathForTitle(directory))
        displayPrompt()
    }

    /// Resume the rf file browser after an editor or shell exits.
    func resumeRF() {
        guard let rfCommand = activeRFCommand, isRunning else {
            // rf was cancelled or session ended — clean up
            activeRFCommand = nil
            sessionMode = .localShell
            if isRunning {
                onTitleChange?(formatPathForTitle(sessionCurrentDirectory))
                displayPrompt()
            }
            return
        }

        // Handle pending remote edit (upload if modified), refresh directory,
        // then re-enter rf
        sessionMode = .rfBrowserRunning
        onTitleChange?("rf")
        rfCommand.resumeAfterExternalEditor()
    }

    /// Display rf usage help.
    func displayRFHelp() {
        let helpText = """
usage: rf [path]

rootshell files - TUI file browser

Arguments:
  path          Directory to open (default: current directory)
  --help, -h    Show this help

Navigation:
  j/↓, k/↑     Move cursor down/up
  h/←           Go to parent directory
  l/→/Enter     Enter directory or open file in editor
  e             Open file in editor ($EDITOR, default: hx)
                Remote: downloads file, edits locally, uploads if saved
  g, G          Jump to top/bottom
  PgUp, PgDn    Page scroll
  Shift+j/k     Scroll preview line
  Ctrl-d/u      Scroll preview half-page
  -/Backspace   Go back in history
  =             Go forward in history

Search & Filter:
  /             Filter files by name (live)
  S             Search file contents (ripgrep)
  :             Go to directory path (Tab for completion)

File Operations:
  y             Yank (copy) files
  d             Yank-cut (move) files
  u             Unyank (clear clipboard & selection)
  p/P           Paste / Paste (overwrite)
  D             Delete (with confirmation)
  r             Rename
  a/A           Create file / Create directory
  C             Send with croc 🐊 (local tabs only)

Config:
  ~/.config/rf/rf.yaml    Persistent settings (show_hidden, sort_by)

Selection:
  Space         Toggle selection
  v/V           Visual select / unselect mode

Tabs:
  t             New tab
  w             Close tab
  1-9           Switch to tab N
  Tab/S-Tab     Next/previous tab

SFTP:
  o             Open SFTP connection (user@host[:port])
                Opens a new tab browsing a remote host via SFTP.
                Yank/paste works across local and SFTP tabs.

Other:
  .             Toggle hidden files
  s             Cycle sort order
  m + a-z       Set bookmark
  ' + a-z       Jump to bookmark
  ;             Drop to shell (exit to return)
  q/Esc         Quit
  Q             Quit and cd to current directory
  Ctrl-L        Refresh

Mouse:
  Click         Select file / switch tab
  Double-click  Enter directory / open file
  Scroll        Scroll file list or preview
  Drag separator  Resize columns

"""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif
