//
//  TerminalTargetKey.swift
//  rootshell
//

import Foundation

/// Identifies the machine a pane's shell runs on, for caches keyed per host.
nonisolated enum TerminalTargetKey {
    static let local = "local"

    static func remote(username: String, host: String, port: Int) -> String {
        "\(username)@\(host):\(port)"
    }
}
