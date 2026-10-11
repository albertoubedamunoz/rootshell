//
//  TerminalView+ForegroundProgram.swift
//  rootshell
//
//  Resolves the pane's shell or foreground program from whichever sources
//  this pane has (shell reports, herdr, tmux, the local PTY, the login
//  shell) and promotes a long-lived program to a Running card.
//

import Foundation

extension Ghostty.TerminalView {
    /// Long enough that `ls` or `git status` never flashes a card.
    static let foregroundProgramCardDelay: Duration = .milliseconds(1500)

    func setForegroundProgram(_ program: ForegroundProgram?, from source: ForegroundProgram.Source) {
        guard foregroundProgramSources[source] != program else { return }
        foregroundProgramSources[source] = program
        let resolved = foregroundProgramSources.max { $0.key < $1.key }?.value
        let previous = presentation.foregroundProgram
        guard previous != resolved else { return }
        presentation.foregroundProgram = resolved
        // A second source catching up on the same program keeps its card.
        guard previous?.name != resolved?.name || previous?.isShell != resolved?.isShell else { return }
        scheduleForegroundProgramCard(for: resolved)
    }

    private func scheduleForegroundProgramCard(for program: ForegroundProgram?) {
        foregroundProgramCardTask?.cancel()
        foregroundProgramCardTask = nil
        if presentation.foregroundProgramCardSince != nil {
            presentation.foregroundProgramCardSince = nil
            AgentAttentionCenter.shared.foregroundProgramCardDidChange()
        }
        guard let program, program.showsRunningCard else { return }
        let since = Date()
        foregroundProgramCardTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: Self.foregroundProgramCardDelay)) != nil,
                  let self, self.presentation.foregroundProgram?.name == program.name else { return }
            self.foregroundProgramCardTask = nil
            self.presentation.foregroundProgramCardSince = since
            AgentAttentionCenter.shared.foregroundProgramCardDidChange()
        }
    }

    // MARK: - Session lifetime

    /// Runs before the new session's output is wired, so everything it
    /// reports lands in fresh state. The old records stay on screen, and in
    /// reserve, until the new session is ready.
    func foregroundSessionWillChange() {
        if previousSessionShellReports == nil {
            previousSessionShellReports = shellProgramReports
        }
        shellProgramReports = ShellProgramReports()
        loginShellProbeTask?.cancel()
        loginShellProbeTask = nil
        localForegroundPollTask?.cancel()
        localForegroundPollTask = nil
        localForegroundProbeTask?.cancel()
        localForegroundProbeTask = nil
        localForegroundProcessGroup = nil
        setForegroundProgram(nil, from: .localProcess)
    }

    /// A resumed remote PTY keeps running whatever it ran, and its shell
    /// sends nothing new for a command already started, so its records come
    /// back unless the new stream has said anything since. A fresh session
    /// keeps only what it reported itself.
    func foregroundSessionDidBecomeReady() {
        if let previous = previousSessionShellReports {
            previousSessionShellReports = nil
            let resumed = (session as? TrzszSession)?.wasResumed == true
                || (session as? MoshSession)?.wasResumed == true
            if resumed { shellProgramReports = previous }
        }
        setForegroundProgram(shellProgramReports.program, from: .shellReport)
        startLocalForegroundPolling()
        probeLoginShellIfRemote()
    }

    /// Any shell-record event from the new stream, including a clear or a
    /// command finishing, outranks what the replaced session reported.
    private func newSessionReportedShellState() {
        previousSessionShellReports = nil
    }

    // MARK: - Shell reports (OSC 7501)

    /// Records under `ShellProgramReports.shellID` describe the pane rather
    /// than a program's own state, so they never reach the agent inbox.
    func applyShellProgramReport(_ report: Ghostty.Action.ProgramStatus) {
        newSessionReportedShellState()
        let change: ShellProgramReports.Change
        switch report.state {
        case .idle: change = .idle
        case .working, .blocked: change = .active
        case .done, .error: change = .finished
        case .clear: change = .clear
        }
        shellProgramReports.apply(id: report.id, change: change, app: report.app, title: report.title)
        if ProgramStatusDebugLogger.shared.isEnabled {
            ProgramStatusDebugLogger.shared.event(
                "SHELL", "pane=\(uuid) id=\"\(report.id)\" -> \(shellProgramReports.program?.name ?? "nil")")
        }
        setForegroundProgram(shellProgramReports.program, from: .shellReport)
    }

    func clearShellProgramReports() {
        newSessionReportedShellState()
        shellProgramReports.clearAll()
        setForegroundProgram(nil, from: .shellReport)
    }

    /// OSC 133;D: the shell is back at a prompt.
    func noteForegroundCommandFinished() {
        newSessionReportedShellState()
        shellProgramReports.commandFinished()
        setForegroundProgram(shellProgramReports.program, from: .shellReport)
        noteLocalForegroundMayHaveChanged()
    }

    // MARK: - Local PTY

    /// Content events flow only while agent detection or a tmux controller
    /// wants them, so local panes also poll: one ioctl a second, and a full
    /// lookup every few seconds to catch `exec` within a group.
    private static let localForegroundPollInterval: Duration = .seconds(1)
    private static let localForegroundRevalidateEvery = 5

    private func startLocalForegroundPolling() {
        localForegroundPollTask?.cancel()
        localForegroundPollTask = nil
        #if targetEnvironment(macCatalyst)
        guard session is CatalystLocalShellSession else { return }
        localForegroundPollTask = Task { @MainActor [weak self] in
            var tick = 0
            while (try? await Task.sleep(for: Self.localForegroundPollInterval)) != nil {
                guard let self, let session = self.session as? CatalystLocalShellSession,
                      session.isRunning else { return }
                guard !Ghostty.isAppBackgroundedAtomic else { continue }
                tick += 1
                self.probeLocalForeground(revalidate: tick % Self.localForegroundRevalidateEvery == 0)
            }
        }
        #endif
    }

    /// Output speeds the poll up: one probe per 300ms burst, revalidating,
    /// since output in an unchanged group is how `exec htop` shows itself.
    func noteLocalForegroundMayHaveChanged() {
        #if targetEnvironment(macCatalyst)
        guard localForegroundProbeTask == nil, session is CatalystLocalShellSession else { return }
        localForegroundProbeTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil, let self else { return }
            self.localForegroundProbeTask = nil
            self.probeLocalForeground(revalidate: true)
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func probeLocalForeground(revalidate: Bool) {
        // A tmux -CC gateway or projected pane gets its identity from tmux.
        guard tmuxPaneBinding == nil, tmuxController == nil,
              let session = session as? CatalystLocalShellSession,
              let group = session.foregroundProcessGroup() else {
            localForegroundProcessGroup = nil
            setForegroundProgram(nil, from: .localProcess)
            return
        }
        guard group != localForegroundProcessGroup || revalidate else { return }
        // Arguments matter too: `exec bash build.sh` from bash keeps both the
        // group and the executable. Only a resolved lookup is remembered, so a
        // failed one is retried.
        let program = LocalForegroundProcessProbe.program(processGroup: group)
        localForegroundProcessGroup = program == nil ? nil : group
        setForegroundProgram(program, from: .localProcess)
    }
    #endif

    // MARK: - Login shell

    /// One exec probe per connection for the remote account's `$SHELL`, the
    /// lowest-priority identity: any shell report or multiplexer overrides it.
    private func probeLoginShellIfRemote() {
        let citadel = session as? CitadelSSHSession
        let trzsz = session as? TrzszSession
        guard citadel != nil || trzsz != nil else { return }
        loginShellProbeTask = Task { @MainActor [weak self] in
            let path: String?
            if let citadel {
                path = await SessionDiscoveryRunner.loginShell(using: citadel)
            } else if let trzsz {
                path = await SessionDiscoveryRunner.loginShell(using: trzsz)
            } else {
                path = nil
            }
            guard !Task.isCancelled, let self else { return }
            self.loginShellProbeTask = nil
            let program = path.flatMap {
                ForegroundProgram(rawName: $0, isShell: true, source: .loginShell)
            }
            self.setForegroundProgram(program, from: .loginShell)
        }
    }
}
