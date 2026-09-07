// Transport-independent connection metadata for a tmux control-mode gateway.
import Foundation

nonisolated struct TmuxConnectionInfo: Sendable {
    let gatewayID: UUID
    let controllerID: UUID?
    let windowID: Int?
    let paneID: Int?
    let openedAt: Date
}

nonisolated struct TmuxConnectionSnapshot: Sendable {
    let server: Server
    let session: Session
    let client: Client
    let window: Window?
    let pane: Pane?
    var counters: Counters?
    let updatedAt: Date

    struct Server: Sendable {
        let version: String?
        let host: String?
        let pid: UInt64?
        let socketPath: String?
        let startedAt: Date?
    }

    struct Session: Sendable {
        let id: Int
        let name: String?
        let createdAt: Date?
        let windows: Int?
        let panes: Int?
        let attachedClients: Int?
    }

    struct Client: Sendable {
        let name: String?
        let createdAt: Date?
        let flags: String?
    }

    struct Window: Sendable {
        let id: Int
        let index: Int?
        let panes: Int?
        let width: Int?
        let height: Int?
        let name: String?
    }

    struct Pane: Sendable {
        let id: Int
        let windowID: Int
        let width: Int?
        let height: Int?
    }

    struct Counters: Sendable {
        /// Bytes received by the control parser since the viewer was created.
        let receivedBytes: UInt64?
        /// Viewer counters restart when the control viewer is recreated.
        let outputEvents: UInt64
        let notifications: UInt64
    }
}

nonisolated enum TmuxConnectionInfoError: Error, LocalizedError {
    case malformedReply
    case sessionChanged
    case unavailable

    var errorDescription: String? {
        switch self {
        case .malformedReply: return "tmux returned incomplete connection information."
        case .sessionChanged: return "The tmux session changed. Refreshing connection information…"
        case .unavailable: return "The tmux control-mode gateway is unavailable or reconnecting."
        }
    }
}

/// q: escapes separators and backslashes as well as shell metacharacters.
/// Decode those escapes before interpreting fields. Unlike splitting on spaces
/// or newlines, this preserves names containing whitespace (including newlines).
nonisolated enum TmuxConnectionInfoParser {
    static let metadataKeys = [
        "version", "host", "pid", "socket_path", "start_time",
        "session_id", "session_name", "session_created", "session_windows", "session_attached",
        "client_name", "client_created", "client_flags", "client_control_mode"
    ]
    static let windowKeys = [
        "window_id", "window_index", "window_panes", "window_width", "window_height", "window_name"
    ]
    static let paneKeys = ["pane_id", "pane_width", "pane_height", "window_id"]

    /// A tmux double-quoted argument, with escaped tabs expanded by its command
    /// parser. Keys are internal constants, never user-supplied command text.
    static func formatArgument(_ keys: [String]) -> String {
        "\"" + keys.map { "#{q:\($0)}" }.joined(separator: "\\t") + "\""
    }

    static func records(_ body: String) throws -> [[String]] {
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var escaped = false
        for character in normalized {
            if escaped {
                field.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\t" {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
        }
        guard !escaped else { throw TmuxConnectionInfoError.malformedReply }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    static func text(_ value: String) -> String? { value.isEmpty ? nil : value }

    static func count(_ value: String) -> Int? {
        guard let number = Int(value), number >= 0 else { return nil }
        return number
    }

    static func date(_ value: String) -> Date? {
        guard let seconds = UInt64(value), seconds > 0,
              seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }

    static func identifier(_ value: String, prefix: Character) -> Int? {
        guard value.first == prefix else { return nil }
        return count(String(value.dropFirst()))
    }

    static func parseWindows(_ body: String) throws -> [TmuxConnectionSnapshot.Window] {
        try records(body).map { fields in
            guard fields.count == windowKeys.count,
                  let id = identifier(fields[0], prefix: "@") else {
                throw TmuxConnectionInfoError.malformedReply
            }
            return TmuxConnectionSnapshot.Window(
                id: id, index: count(fields[1]), panes: count(fields[2]),
                width: count(fields[3]), height: count(fields[4]), name: text(fields[5]))
        }
    }

    static func parsePane(_ body: String) throws -> TmuxConnectionSnapshot.Pane {
        let rows = try records(body)
        guard rows.count == 1, let fields = rows.first, fields.count == paneKeys.count,
              let id = identifier(fields[0], prefix: "%"),
              let windowID = identifier(fields[3], prefix: "@") else {
            throw TmuxConnectionInfoError.malformedReply
        }
        return TmuxConnectionSnapshot.Pane(id: id, windowID: windowID, width: count(fields[1]), height: count(fields[2]))
    }

    static func parseMetadata(_ body: String, windows: [TmuxConnectionSnapshot.Window],
                              windowID: Int?, pane: TmuxConnectionSnapshot.Pane?) throws -> TmuxConnectionSnapshot {
        let rows = try records(body)
        guard rows.count == 1, let f = rows.first, f.count == metadataKeys.count,
              let sessionID = identifier(f[5], prefix: "$"), f[13] == "1" else {
            throw TmuxConnectionInfoError.malformedReply
        }
        let windowCount = count(f[8])
        var paneCount: Int? = windowCount == windows.count ? 0 : nil
        for window in windows {
            if let total = paneCount, let panes = window.panes {
                let sum = total.addingReportingOverflow(panes)
                paneCount = sum.overflow ? nil : sum.partialValue
            } else { paneCount = nil }
        }
        return TmuxConnectionSnapshot(
            server: .init(version: text(f[0]), host: text(f[1]), pid: UInt64(f[2]),
                          socketPath: text(f[3]), startedAt: date(f[4])),
            session: .init(id: sessionID, name: text(f[6]), createdAt: date(f[7]),
                           windows: windowCount, panes: paneCount, attachedClients: count(f[9])),
            client: .init(name: text(f[10]), createdAt: date(f[11]), flags: text(f[12])),
            window: windows.first { $0.id == windowID }, pane: pane, updatedAt: Date())
    }
}
