import Foundation

/// A verified local attachment, never a shell command to replay. Shared with
/// the helper so validation and launch use the same allowlist and wire format.
public nonisolated struct LocalMultiplexerAttachment: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var kind: String
    public var controlMode: Bool
    public var executable: String
    public var socketPath: String
    public var socketDevice: UInt64
    public var socketInode: UInt64
    public var serverPID: Int32
    public var serverStartedAt: UInt64
    public var sessionName: String
    public var sessionID: Int?
    public var sessionCreatedAt: UInt64?
    public var environment: [String: String]

    public static let environmentKeys: Set<String> = [
        "ZELLIJ_SOCKET_DIR", "ZELLIJ_CONFIG_DIR", "ZELLIJ_CONFIG_FILE",
        "HERDR_CONFIG_PATH", "HERDR_SOCKET_PATH", "HERDR_SESSION",
        "ZMX_DIR", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"
    ]

    public var isValid: Bool {
        version == 1 && ["tmux", "zellij", "herdr", "zmx"].contains(kind)
            && (!controlMode || kind == "tmux")
            && executable.hasPrefix("/") && socketPath.hasPrefix("/")
            && (executable as NSString).lastPathComponent == kind
            && socketInode > 0 && serverPID > 0 && serverStartedAt > 0
            && !sessionName.isEmpty && sessionName.utf8.count <= 1024
            && (kind != "tmux" || (sessionID.map { $0 >= 0 } == true && sessionCreatedAt != nil))
            && Set(environment.keys).isSubset(of: Self.environmentKeys)
            && ([executable, socketPath, sessionName] + Array(environment.values)).allSatisfy {
                $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// No create flags, shell aliases, or inherited inside-multiplexer identity.
    public var attachArguments: [String] {
        switch kind {
        case "tmux":
            return ["-S", socketPath] + (controlMode ? ["-CC"] : [])
                + ["attach-session", "-t", "$\(sessionID ?? -1)"]
        // herdr's session subcommand rejects `--` and overrides custom socket
        // selection. Its normal entry point honors the verified API socket.
        case "herdr": return []
        case "zmx": return ["attach", sessionName]
        default: return ["attach", "--", sessionName]
        }
    }

    public var launchEnvironment: [String: String] {
        var result = environment
        switch kind {
        case "zmx":
            result["ZMX_DIR"] = (socketPath as NSString).deletingLastPathComponent
        case "herdr":
            result["HERDR_SESSION"] = sessionName
            if result["HERDR_SOCKET_PATH"] == nil {
                result["HERDR_SOCKET_PATH"] = ((socketPath as NSString).deletingLastPathComponent as NSString)
                    .appendingPathComponent("herdr.sock")
            }
        default: break
        }
        return result
    }

    /// One trusted startup command, run by the helper before the login shell.
    /// All variable data are single-quoted arguments, not executable syntax.
    public var attachCommand: String {
        let cleared = ["TMUX", "TMUX_PANE", "ZELLIJ", "ZELLIJ_SESSION_NAME", "HERDR_ENV", "ZMX_SESSION", "ZMX_SESSION_PREFIX"]
        return (["/usr/bin/env"] + cleared.flatMap { ["-u", $0] }
            + launchEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + [executable] + attachArguments).map(Self.quote).joined(separator: " ")
    }
}

/// A bad/newer optional recovery record must not discard the entire window.
@propertyWrapper
nonisolated struct LossyLocalMultiplexerAttachment: Codable, Equatable, Sendable {
    var wrappedValue: LocalMultiplexerAttachment?
    init(wrappedValue: LocalMultiplexerAttachment? = nil) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let value = try? LocalMultiplexerAttachment(from: decoder)
        wrappedValue = value?.isValid == true ? value : nil
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue?.isValid == true ? wrappedValue : nil)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LossyLocalMultiplexerAttachment.Type, forKey key: Key) throws -> LossyLocalMultiplexerAttachment {
        try decodeIfPresent(type, forKey: key) ?? .init()
    }
}
