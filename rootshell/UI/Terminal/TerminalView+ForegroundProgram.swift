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

    // MARK: - Shell reports (OSC 7501)

    /// Records under `ShellProgramReports.shellID` describe the pane rather
    /// than a program's own state, so they never reach the agent inbox.
    func applyShellProgramReport(_ report: Ghostty.Action.ProgramStatus) {
        let change: ShellProgramReports.Change
        switch report.state {
        case .idle, .working, .blocked: change = .live
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
        shellProgramReports.clearAll()
        setForegroundProgram(nil, from: .shellReport)
    }

    /// OSC 133;D: the shell is back at a prompt.
    func noteForegroundCommandFinished() {
        shellProgramReports.commandFinished()
        setForegroundProgram(shellProgramReports.program, from: .shellReport)
        noteLocalForegroundMayHaveChanged()
    }

    // MARK: - Local PTY

    /// Coalesces output bursts into one ioctl per 300ms; the process lookup
    /// runs only when the foreground group changed.
    func noteLocalForegroundMayHaveChanged() {
        #if targetEnvironment(macCatalyst)
        guard localForegroundProbeTask == nil, tmuxPaneBinding == nil, tmuxController == nil,
              session is CatalystLocalShellSession else { return }
        localForegroundProbeTask = Task { @MainActor [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil, let self else { return }
            self.localForegroundProbeTask = nil
            self.probeLocalForeground()
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func probeLocalForeground() {
        guard let session = session as? CatalystLocalShellSession,
              let group = session.foregroundProcessGroup() else {
            localForegroundProcessGroup = nil
            setForegroundProgram(nil, from: .localProcess)
            return
        }
        guard group != localForegroundProcessGroup else { return }
        localForegroundProcessGroup = group
        setForegroundProgram(LocalForegroundProcessProbe.program(processGroup: group), from: .localProcess)
    }
    #endif

    // MARK: - Login shell

    /// One exec probe per connection for the remote account's `$SHELL`, the
    /// lowest-priority identity: any shell report or multiplexer overrides it.
    func probeLoginShellIfRemote() {
        loginShellProbeTask?.cancel()
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
