//
//  TmuxCommandQuoting.swift
//  rootshell
//

import Foundation

/// Quoting for arguments sent to the tmux command parser.
nonisolated enum TmuxCommandQuoting {
    /// Single quotes; adjacent tokens join, so `'` becomes `'\''`.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// For arguments tmux runs through format expansion (`-c start-directory`).
    static func quotedFormatLiteral(_ value: String) -> String {
        quoted(value.replacingOccurrences(of: "#", with: "##"))
    }
}
