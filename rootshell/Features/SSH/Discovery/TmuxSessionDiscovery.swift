//
//  TmuxSessionDiscovery.swift
//  rootshell
//
//  Data models, parser, and discovery method for tmux session detection on SSH hosts.
//

import Foundation
import Citadel
import NIO
import NIOFoundationCompat
import os

// MARK: - Data Models

struct TmuxSessionInfo: Identifiable, Equatable, Sendable {
    let name: String
    let isAttached: Bool
    let windowCount: Int
    let lastAttached: String
    let activePanes: [TmuxPaneInfo]
    var capturedContent: String?

    var id: String { name }

    var activeCommand: String? {
        activePanes.first(where: { $0.isActivePane })?.currentCommand
    }

    var activePath: String? {
        activePanes.first(where: { $0.isActivePane })?.currentPath
    }

    var activeWindowName: String? {
        activePanes.first(where: { $0.isActivePane })?.windowName
    }
}

struct TmuxPaneInfo: Equatable, Sendable {
    let windowName: String
    let isActivePane: Bool
    let currentCommand: String
    let currentPath: String
}

// MARK: - Errors

enum TmuxDiscoveryError: LocalizedError {
    case notConnected
    case timeout
    case tmuxNotInstalled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "SSH client not connected"
        case .timeout: return "Tmux discovery timed out"
        case .tmuxNotInstalled: return "tmux is not installed on the remote host"
        }
    }
}

// MARK: - Discovery Command

enum TmuxDiscoveryCommand {
    /// Field delimiter for tmux format output. Using a multi-char string instead
    /// of \t because tab characters can be lost through SSH exec channels.
    static let delimiter = "%%"

    /// Uses login shell (-l) so TMPDIR and other env vars are set correctly.
    /// On macOS, tmux stores its socket under $TMPDIR which differs between
    /// interactive sessions and bare SSH exec channels.
    static let command: String = {
        let d = delimiter
        return "sh -lc '\(SSHConfig.remoteExecPathPrefix)command -v tmux >/dev/null 2>&1 || exit 1; echo \"::SESSIONS::\"; tmux list-sessions -F \"#{session_name}\(d)#{?session_attached,attached,detached}\(d)#{session_windows}\(d)#{t:session_last_attached}\" 2>/dev/null; echo \"::PANES::\"; tmux list-panes -a -F \"#{session_name}\(d)#{window_name}\(d)#{window_active}\(d)#{pane_active}\(d)#{pane_current_command}\(d)#{pane_current_path}\" 2>/dev/null; echo \"::CAPTURES::\"; for s in $(tmux list-sessions -F \"#{session_name}\" 2>/dev/null); do printf \"::CAPTURE:%s::\\n\" \"$s\"; tmux capture-pane -t \"$s:\" -p -e 2>/dev/null; done'"
    }()
}

// MARK: - Parser

enum TmuxDiscoveryParser {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "TmuxDiscoveryParser"
    )

    static func parse(output: String) -> [TmuxSessionInfo] {
        let parts = output.components(separatedBy: "::SESSIONS::")
        guard parts.count >= 2 else {
            return []
        }

        let afterSessions = parts[1]

        // Split off captures section first (optional)
        let capturesSplit = afterSessions.components(separatedBy: "::CAPTURES::")
        let beforeCaptures = capturesSplit[0]
        let capturesBlock = capturesSplit.count >= 2 ? capturesSplit[1] : ""

        let sectionParts = beforeCaptures.components(separatedBy: "::PANES::")
        let sessionsBlock = sectionParts[0]
        let panesBlock = sectionParts.count >= 2 ? sectionParts[1] : ""

        // Parse captures, keyed by session name
        var capturesBySession: [String: String] = [:]
        if !capturesBlock.isEmpty {
            // Split on ::CAPTURE:name:: markers
            let capturePattern = "::CAPTURE:"
            let captureChunks = capturesBlock.components(separatedBy: capturePattern)
            for chunk in captureChunks {
                // Each chunk starts with "session_name::\n...content..."
                guard let markerEnd = chunk.range(of: "::\n") ?? chunk.range(of: "::\r\n") else { continue }
                let sessionName = String(chunk[chunk.startIndex..<markerEnd.lowerBound])
                let content = String(chunk[markerEnd.upperBound...])
                // Trim trailing whitespace but preserve internal structure
                let trimmed = content.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if !trimmed.isEmpty {
                    capturesBySession[sessionName] = trimmed
                }
            }
        }

        // Parse panes first, keyed by session name
        let delimiter = TmuxDiscoveryCommand.delimiter
        var panesBySession: [String: [TmuxPaneInfo]] = [:]
        for line in panesBlock.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = String(line).components(separatedBy: delimiter)
            guard fields.count >= 6 else { continue }

            let sessionName = fields[0]
            let windowActive = fields[2] == "1"
            let paneActive = fields[3] == "1"

            // Only include panes from the active window
            guard windowActive else { continue }

            let pane = TmuxPaneInfo(
                windowName: fields[1],
                isActivePane: paneActive,
                currentCommand: fields[4],
                currentPath: fields[5]
            )
            panesBySession[sessionName, default: []].append(pane)
        }

        // Parse sessions
        var sessions: [TmuxSessionInfo] = []
        for line in sessionsBlock.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = String(line).components(separatedBy: delimiter)
            guard fields.count >= 4 else { continue }

            let name = fields[0]
            let isAttached = fields[1] == "attached"
            let windowCount = Int(fields[2]) ?? 1
            let lastAttached = fields[3]

            let session = TmuxSessionInfo(
                name: name,
                isAttached: isAttached,
                windowCount: windowCount,
                lastAttached: lastAttached,
                activePanes: panesBySession[name] ?? [],
                capturedContent: capturesBySession[name]
            )
            sessions.append(session)
        }

        let count = sessions.count
        logger.info("Parsed \(count) tmux sessions")
        return sessions
    }
}

// MARK: - Discovery Runner

@MainActor
enum TmuxDiscoveryRunner {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "TmuxDiscovery"
    )

    /// Execute the discovery command on the given SSH client with a 5-second timeout.
    static func execute(on client: SSHClient) async throws -> [TmuxSessionInfo] {
        let output: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @Sendable in
                let buf = try await client.executeCommand(TmuxDiscoveryCommand.command)
                let data = Data(buffer: buf)
                return String(data: data, encoding: .utf8) ?? ""
            }
            group.addTask { @Sendable in
                try await Task.sleep(for: .seconds(5))
                throw TmuxDiscoveryError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if output.isEmpty {
            logger.info("Empty output from tmux discovery (tmux not installed or no sessions)")
            throw TmuxDiscoveryError.tmuxNotInstalled
        }

        return TmuxDiscoveryParser.parse(output: output)
    }

    /// Discover tmux sessions using an existing CitadelSSHSession's client.
    static func discover(using session: CitadelSSHSession) async throws -> [TmuxSessionInfo] {
        guard let client = session.client else {
            throw TmuxDiscoveryError.notConnected
        }
        return try await execute(on: client)
    }

    /// Discover tmux sessions by creating a temporary SSH connection.
    /// Used for session types (Trzsz, Mosh) whose SSH client is closed after spawn.
    static func discover(using config: SSHConfig) async throws -> [TmuxSessionInfo] {
        logger.info("Creating temporary SSH connection for tmux discovery")

        // Strict: the main session already validated this host, so its saved
        // key passes silently; unknown or changed keys reject.
        let (client, jumpClient) = try await SSHConnectionHelper.connect(
            config: config,
            onHostKeyValidation: nil
        )

        defer {
            Task { try? await client.close() }
            if let jumpClient {
                Task { try? await jumpClient.close() }
            }
        }

        return try await execute(on: client)
    }
}
