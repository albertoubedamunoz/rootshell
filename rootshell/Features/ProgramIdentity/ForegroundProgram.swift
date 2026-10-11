//
//  ForegroundProgram.swift
//  rootshell
//
//  What a pane is running right now: its shell at a prompt, or the program
//  in the foreground. Feeds the tab and sidebar logos and the Running card.
//

import Foundation

nonisolated struct ForegroundProgram: Equatable, Sendable {
    /// Where the identity came from. Higher raw values win when a pane has
    /// more than one source.
    enum Source: Int, Comparable, Sendable, CaseIterable {
        /// `$SHELL` from a one-shot exec probe; knows nothing about commands.
        case loginShell
        /// The local PTY's foreground process group.
        case localProcess
        /// tmux `#{pane_current_command}`.
        case tmux
        /// herdr's `PaneInfo.foreground_process`.
        case herdr
        /// The shell's own OSC 7501 reports (`ShellProgramReports`).
        case shellReport

        static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Normalized command name (`ProgramNameNormalizer`).
    var name: String
    /// Full command line, when the source has one.
    var commandLine: String?
    /// The pane's own shell sits at a prompt.
    var isShell: Bool
    var source: Source

    var entry: ProgramCatalog.Entry? { ProgramCatalog.entry(for: name) }

    /// Every pane running something shows a mark: an unknown shell gets the
    /// terminal glyph, an unknown program the generic running glyph.
    var mark: BrandMark? {
        entry?.mark ?? (isShell ? .symbol("terminal") : ProgramCatalog.runningProgramMark)
    }

    var displayName: String { entry?.displayName ?? name }

    /// Shells sit at a prompt and multiplexers host whole sessions; neither
    /// is a program the user is waiting on.
    var showsRunningCard: Bool { !isShell && entry?.kind != .multiplexer }

    /// Builds an identity from a raw process name and its arguments, or nil
    /// when nothing usable remains.
    init?(rawName: String, arguments: [String] = [], commandLine: String? = nil,
          isShell: Bool? = nil, source: Source) {
        guard let name = ProgramNameNormalizer.normalize(name: rawName, arguments: arguments) else {
            return nil
        }
        self.name = name
        self.commandLine = commandLine
        // Sources that can't tell a prompt from a program fall back to the
        // catalog: a known shell with no script operand (`bash build.sh`
        // is a program run) is at a prompt.
        self.isShell = isShell ?? (ProgramCatalog.entry(for: name)?.kind == .shell
            && arguments.dropFirst().allSatisfy { $0.hasPrefix("-") })
        self.source = source
    }
}

/// A logo for a tab, sidebar row or card: a brand imageset in its own
/// colours, an official monochrome mark drawn in the text colour, or, for
/// programs without a logo, an SF Symbol in the text colour.
nonisolated enum BrandMark: Hashable, Sendable {
    case asset(String)
    case template(String)
    case symbol(String)
}
