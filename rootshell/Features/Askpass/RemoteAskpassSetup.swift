//
//  RemoteAskpassSetup.swift
//  rootshell
//
//  Prepares the remote side of credential forwarding: creates
//  `~/.rootshell` (0700), removes this pane's stale socket, and returns
//  the absolute socket path for the streamlocal forward.
//
//  The socket is named after the pane token, which already reaches the
//  remote as `LC_ROOTSHELL_PANE`, so `rootshell-askpass` can find its
//  own pane's socket. A stale token (tmux, reattach) falls back to the
//  newest socket in the helper.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import Citadel

nonisolated enum RemoteAskpassSetup {

    enum SetupError: Error, LocalizedError {
        case commandFailed(String)
        case malformedOutput

        var errorDescription: String? {
            switch self {
            case .commandFailed(let detail): return "Credential socket setup failed: \(detail)"
            case .malformedOutput: return "Credential socket setup returned no home directory"
            }
        }
    }

    /// Socket name component. Restricted to `[A-Za-z0-9-]` because it is
    /// interpolated into a shell command.
    static func socketID(paneToken: String?) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        if let paneToken, !paneToken.isEmpty, paneToken.count <= 64, paneToken.allSatisfy(allowed.contains) {
            return paneToken
        }
        return UUID().uuidString
    }

    /// Wrapped in `sh -c` because tsshd execs commands without a shell
    /// (see ``GPGRemotePathResolver/probeCommand``).
    static func setupCommand(socketID: String) -> String {
        #"sh -c 'umask 077; mkdir -p "$HOME/.rootshell" && rm -f "$HOME/.rootshell/askpass-\#(socketID).sock" && printf "%s" "$HOME"'"#
    }

    static func prepare(socketID: String, usingCitadel client: SSHClient) async throws -> String {
        do {
            let buffer = try await client.executeCommand(setupCommand(socketID: socketID), maxResponseSize: 4096)
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            return try socketPath(fromOutput: String(decoding: bytes, as: UTF8.self), socketID: socketID)
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.commandFailed(error.localizedDescription)
        }
    }

    static func prepare(socketID: String, usingTrzsz transport: TrzszGoTransport) async throws -> String {
        do {
            let data = try await transport.runRemoteCommand(setupCommand(socketID: socketID))
            return try socketPath(fromOutput: String(decoding: data, as: UTF8.self), socketID: socketID)
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.commandFailed(error.localizedDescription)
        }
    }

    static func socketPath(fromOutput output: String, socketID: String) throws -> String {
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard home.hasPrefix("/"), !home.contains("\n") else { throw SetupError.malformedOutput }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/.rootshell/askpass-\(socketID).sock"
    }
}
