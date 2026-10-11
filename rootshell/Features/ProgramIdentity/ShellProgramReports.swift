//
//  ShellProgramReports.swift
//  rootshell
//
//  OSC 7501 records a shell integration sends about itself and its
//  foreground command. They are ordinary reports on the wire, under ids in
//  our own namespace, but the shell can only say WHAT runs, never how it is
//  doing, so they feed the pane's identity and never the agent inbox.
//
//    state=idle:id=rootshell.shell:app=zsh            at each prompt
//    state=working:id=rootshell.shell/cmd:app=htop:title=<base64 cmdline>
//

import Foundation

nonisolated struct ShellProgramReports: Equatable, Sendable {
    static let shellID = "rootshell.shell"
    static let commandID = "rootshell.shell/cmd"

    enum Change: Sendable {
        /// idle, working or blocked: the record is live.
        case live
        /// done or error: the command finished.
        case finished
        case clear
    }

    struct Command: Equatable, Sendable {
        var app: String
        var commandLine: String?
    }

    private(set) var shellApp: String?
    private(set) var command: Command?

    static func owns(id: String) -> Bool {
        id == shellID || id.hasPrefix(shellID + "/")
    }

    mutating func apply(id: String, change: Change, app: String, title: String) {
        switch id {
        case Self.shellID:
            if change == .clear {
                // Clearing a record clears its children too.
                shellApp = nil
                command = nil
            } else if !app.isEmpty {
                shellApp = app
            }
        case Self.commandID:
            guard change == .live, !app.isEmpty else {
                command = nil
                return
            }
            command = Command(app: app, commandLine: title.isEmpty ? nil : title)
        default:
            break
        }
    }

    /// A clear with no id removes every record.
    mutating func clearAll() {
        shellApp = nil
        command = nil
    }

    /// OSC 133;D: the command's record is `working`, which a new prompt
    /// drops. The shell's own idle record stays (a terminal MAY drop it).
    mutating func commandFinished() {
        command = nil
    }

    var program: ForegroundProgram? {
        if let command {
            let arguments = command.commandLine.map(ProgramNameNormalizer.words(of:)) ?? []
            // The app value is the shell's own guess at the program; argv
            // unwraps `sudo htop` when the command line came along.
            let rawName = arguments.isEmpty ? command.app : arguments[0]
            if let program = ForegroundProgram(
                rawName: rawName, arguments: arguments, commandLine: command.commandLine,
                isShell: false, source: .shellReport) {
                return program
            }
        }
        guard let shellApp else { return nil }
        return ForegroundProgram(rawName: shellApp, isShell: true, source: .shellReport)
    }
}
