import Foundation

// MARK: - Multiplexer Type

nonisolated enum MultiplexerType: String, Codable, Sendable, Equatable, Hashable {
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
nonisolated struct MuxSessionTarget: Codable, Equatable, Hashable, Sendable {
    let type: MultiplexerType
    let sessionName: String
    let controlMode: Bool
    let tmuxSocket: TmuxSocketIdentity?
    /// Original profile selector, retained when tmux reports its resolved path.
    let tmuxSocketSelector: TmuxSocketIdentity?

    var configuredTmuxSocket: TmuxSocketIdentity? { tmuxSocketSelector ?? tmuxSocket }

    init?(type: MultiplexerType, sessionName: String?, controlMode: Bool = false,
          tmuxSocket: TmuxSocketIdentity? = .defaultServer,
          tmuxSocketSelector: TmuxSocketIdentity? = nil) {
        guard let sessionName, !sessionName.isEmpty else { return nil }
        guard type != .tmux || tmuxSocket != nil else { return nil }
        self.type = type
        self.sessionName = sessionName
        self.controlMode = controlMode && (type == .tmux || type == .herdr)
        self.tmuxSocket = type == .tmux ? tmuxSocket : nil
        self.tmuxSocketSelector = type == .tmux ? tmuxSocketSelector : nil
    }

    /// Missing remote identity (including a local gateway) is never a match.
    func matchesLiveAttachment(_ attachment: Self?, connectionKey: String?,
                               requestedConnectionKey: String, isActive: Bool) -> Bool {
        guard isActive, connectionKey == requestedConnectionKey, let attachment,
              type == attachment.type, sessionName == attachment.sessionName,
              controlMode == attachment.controlMode else { return false }
        // The control client reports a resolved -S path. Its original -L name
        // (or default-server selection) is also a valid way to address it.
        return tmuxSocket == attachment.tmuxSocket
            || (type == .tmux && tmuxSocket != nil && tmuxSocket == attachment.configuredTmuxSocket)
    }

    /// herdr control mode opens its own channel beside the gateway shell.
    var execCommand: String? {
        let name = LoginShellCommand.doubleQuoted(sessionName)
        let command: String
        switch type {
        case .tmux:
            let target = LoginShellCommand.doubleQuoted("=" + sessionName)
            command = "exec tmux \(tmuxSocket?.arguments ?? "")\(controlMode ? "-CC " : "")attach-session -t \(target)"
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

nonisolated enum TmuxSocketIdentity: Codable, Equatable, Hashable, Sendable {
    case defaultServer
    case name(String)
    case path(String)

    var arguments: String {
        switch self {
        case .defaultServer: return ""
        case .name(let name): return "-L \(LoginShellCommand.doubleQuoted(name)) "
        case .path(let path): return "-S \(LoginShellCommand.doubleQuoted(path)) "
        }
    }

    /// The in-band identity is host:socket,pid,start_time. Split the numeric
    /// suffix from the right so commas and colons in socket paths survive.
    static func fromServerIdentity(_ identity: String) -> Self? {
        guard let started = identity.lastIndex(of: ","),
              let pid = identity[..<started].lastIndex(of: ","),
              let socket = identity[..<pid].range(of: ":/") else { return nil }
        return .path(String(identity[identity.index(after: socket.lowerBound)..<pid]))
    }

    /// Fallback while a control client's in-band query is pending, and for raw
    /// auto-start attachments. Unrecognized shell programs stay unknown.
    static func fromStartupCommand(_ command: String) -> Self? {
        guard var words = literalWords(command) else { return nil }
        if words.first == "exec" { words.removeFirst() }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return nil }
        if ["sh", "bash", "zsh"].contains(program), words.count == 3,
           ["-c", "-lc"].contains(words[1]) {
            return fromStartupCommand(words[2])
        }
        guard program == "tmux" else { return nil }
        var socket: Self = .defaultServer
        var explicitPath: Self?
        var index = 1
        while index < words.count, words[index].hasPrefix("-") {
            let flag = words[index]
            if flag == "-L" || flag == "-S" || flag == "-f" {
                index += 1
                guard index < words.count, !words[index].isEmpty else { return nil }
                if flag == "-L" { socket = .name(words[index]) }
                if flag == "-S" { explicitPath = .path(words[index]) }
            } else if flag.hasPrefix("-L"), flag.count > 2 {
                socket = .name(String(flag.dropFirst(2)))
            } else if flag.hasPrefix("-S"), flag.count > 2 {
                explicitPath = .path(String(flag.dropFirst(2)))
            }
            index += 1
        }
        return explicitPath ?? socket
    }

    private static func literalWords(_ command: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                if quote == "\"", !"$`\"\\\n".contains(character) { word.append("\\") }
                if character != "\n" { word.append(character) }
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if character == quote {
                quote = nil
            } else if quote == nil, character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace, quote == nil {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                // Never treat an unevaluated expansion or shell operator as a
                // literal socket selector; the live control query resolves it.
                if quote != "'", "$`".contains(character) { return nil }
                if quote == nil, ";|&()<>{}*?[]".contains(character) { return nil }
                if quote == nil, word.isEmpty, character == "~" { return nil }
                word.append(character)
            }
        }
        guard quote == nil, !escaped else { return nil }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
