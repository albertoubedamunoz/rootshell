import Foundation

// MARK: - Multiplexer Type

nonisolated enum MultiplexerType: String, Sendable, Equatable, Hashable {
    case tmux
    case zellij
    case herdr
    case zmx

    /// Whether the multiplexer, rather than its inner program, owns the screen.
    var ownsAlternateScreen: Bool {
        switch self {
        case .tmux, .zellij, .herdr: return true
        case .zmx: return false
        }
    }

    /// SF Symbol representing this multiplexer.
    ///
    var iconName: String {
        switch self {
        case .tmux: return "rectangle.split.2x1"
        case .zellij: return "rectangle.split.3x1"
        case .herdr: return "square.grid.2x2"
        case .zmx: return "rectangle"
        }
    }
}

/// The actual attachment to resume, independent of profile and global defaults.
nonisolated struct MuxSessionTarget: Equatable, Hashable, Sendable {
    let type: MultiplexerType
    let sessionName: String
    let controlMode: Bool

    init?(type: MultiplexerType, sessionName: String?, controlMode: Bool = false) {
        guard let sessionName, !sessionName.isEmpty else { return nil }
        self.type = type
        self.sessionName = sessionName
        self.controlMode = controlMode && (type == .tmux || type == .herdr)
    }

    /// Missing remote identity (including a local gateway) is never a match.
    func matchesLiveAttachment(_ attachment: Self?, connectionKey: String?,
                               requestedConnectionKey: String, isActive: Bool) -> Bool {
        isActive && connectionKey == requestedConnectionKey && attachment == self
    }

    /// herdr control mode opens its own channel beside the gateway shell.
    var execCommand: String? {
        let name = LoginShellCommand.doubleQuoted(sessionName)
        let command: String
        switch type {
        case .tmux:
            let target = LoginShellCommand.doubleQuoted("=" + sessionName)
            command = "exec tmux \(controlMode ? "-CC " : "")attach-session -t \(target)"
        case .herdr:
            guard !controlMode else { return nil }
            command = "exec herdr session attach \(name)"
        case .zellij:
            command = "exec zellij attach \(name)"
        case .zmx:
            command = "ZMX_SESSION_PREFIX= exec zmx attach \(name)"
        }
        return LoginShellCommand.runInPOSIXShell(LoginShellCommand.pathPrefix + command)
    }
}
