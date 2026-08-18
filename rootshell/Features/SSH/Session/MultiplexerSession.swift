//
//  MultiplexerSession.swift
//  rootshell
//
//  Unified model for terminal multiplexer sessions (tmux, zellij, herdr).
//

import Foundation

// MARK: - Multiplexer Type

enum MultiplexerType: String, Sendable, Equatable, Hashable {
    case tmux
    case zellij
    case herdr
}

// MARK: - Unified Session Model

struct MultiplexerSession: Identifiable, Equatable, Sendable {
    let type: MultiplexerType
    let name: String
    let isAttached: Bool
    /// Summary detail: "3w" for tmux window count, "Created 2h ago" for zellij
    let detail: String
    /// Secondary info: active command+path for tmux, nil for zellij
    let subtitle: String?
    /// ANSI-captured terminal content for preview rendering
    var capturedContent: String?
    /// Whether this is an exited zellij session that can be resurrected
    let isExited: Bool

    var id: String { "\(type.rawValue):\(name)" }
}

// MARK: - Factory: from TmuxSessionInfo

extension MultiplexerSession {
    static func from(tmux session: TmuxSessionInfo) -> MultiplexerSession {
        let detail = "\(session.windowCount)w"
        let command = session.activeCommand
        let path = session.activePath.map { shortenPath($0) }
        let subtitle = [command, path].compactMap { $0 }.joined(separator: " ")

        return MultiplexerSession(
            type: .tmux,
            name: session.name,
            isAttached: session.isAttached,
            detail: detail,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            capturedContent: session.capturedContent,
            isExited: false
        )
    }

    private static func shortenPath(_ path: String) -> String {
        if path.hasPrefix("/home/") {
            return "~" + String(path.dropFirst(5 + path.dropFirst(6).prefix(while: { $0 != "/" }).count))
        }
        if path.hasPrefix("/Users/") {
            return "~" + String(path.dropFirst(6 + path.dropFirst(7).prefix(while: { $0 != "/" }).count))
        }
        return path
    }
}

// MARK: - Factory: from ZellijSessionInfo

extension MultiplexerSession {
    static func from(zellij session: ZellijSessionInfo) -> MultiplexerSession {
        MultiplexerSession(
            type: .zellij,
            name: session.name,
            isAttached: session.isAttached,
            detail: session.createdAgo,
            subtitle: nil,
            capturedContent: session.capturedContent,
            isExited: session.isExited
        )
    }
}

// MARK: - Factory: from HerdrSessionInfo

extension MultiplexerSession {
    static func from(herdr session: HerdrSessionInfo) -> MultiplexerSession {
        MultiplexerSession(
            type: .herdr,
            name: session.name,
            // herdr's session list has no attached-client notion; stopped
            // sessions surface through isExited instead.
            isAttached: false,
            detail: session.detailText,
            subtitle: session.agentSubtitle,
            capturedContent: session.capturedContent,
            isExited: !session.isRunning
        )
    }
}
