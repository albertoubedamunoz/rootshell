//
//  GPGRemotePathResolver.swift
//  rootshell
//
//  Resolves `{HOME}` / `{UID}` placeholders in the GPG forwarding
//  socket path by probing the remote at setup time. OpenSSH itself
//  can't do this — `RemoteForward` ships the path string to sshd
//  verbatim and sshd's `bind(2)` does no expansion (see
//  openssh-portable/readconf.c parse_forward, which only handles
//  `$VAR` expansion locally at config-load time). Since we control
//  both ends, we run one short shell command over the SSH transport
//  and substitute.
//
//  The probe uses `printf '%s\n%s\n' "$(id -u)" "$HOME"` — preferred
//  over `echo` because `echo`'s portability is awful (BSD vs GNU
//  flag handling, trailing-newline behaviour, etc.). `printf` is in
//  POSIX and behaves identically across macOS, Linux, BSDs, and
//  busybox.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import NIOCore
import Citadel
import os.log

enum GPGRemotePathResolver {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "GPGRemotePathResolver"
    )

    /// Result of one probe + substitution.
    struct ResolvedPath: Sendable, Equatable {
        let path: String
        /// True if any placeholder was substituted. Useful for logs
        /// that want to differentiate "user gave us a literal path"
        /// from "we filled in HOME from `id -u` / printf".
        let substituted: Bool
        /// Probed UID, if a probe was run. Nil when the input path
        /// had no placeholders so no probe was attempted.
        let remoteUID: String?
        /// Probed HOME, if a probe was run. Same caveat as ``remoteUID``.
        let remoteHome: String?
    }

    enum ResolverError: Error, LocalizedError {
        case probeFailed(String)
        case malformedProbeOutput(String)

        var errorDescription: String? {
            switch self {
            case .probeFailed(let detail):
                return "Probe of remote UID/HOME failed: \(detail). Fix: edit the GPG socket path to a literal value."
            case .malformedProbeOutput(let raw):
                return "Could not parse remote UID/HOME probe output: \(raw)"
            }
        }
    }

    /// The shell command sent to the remote.
    ///
    /// Wrapped in an explicit `sh -c '...'` because TSSHD's exec
    /// path (tsshd/session.go `getSessionStartCmd`) doesn't run
    /// commands through a shell — it parses the cmd string with
    /// shlex and `exec.Command`s the binary directly, so `$(id -u)`
    /// would be passed as a literal argument to `printf` rather than
    /// being substituted. Citadel works without the wrap because
    /// sshd wraps exec channels in `$SHELL -c`, but the double-wrap
    /// is harmless (sh just re-executes the inner sh -c). Sending
    /// the same string through both paths keeps the resolver code
    /// transport-agnostic.
    ///
    /// `printf` (not `echo`) for portability — BSD vs GNU `echo`
    /// disagree on `-n` and `\` interpretation. The literal `\n` in
    /// the format string is interpreted by `printf` itself.
    static let probeCommand = #"sh -c 'printf "%s\n%s" "$(id -u)" "$HOME"'"#

    /// Resolve a Citadel-transport path. Citadel exposes
    /// ``SSHClient/executeCommand(_:)`` natively, so the probe is
    /// just a one-liner.
    static func resolve(
        path: String,
        usingCitadel client: SSHClient
    ) async throws -> ResolvedPath {
        guard requiresProbe(path: path) else {
            return ResolvedPath(path: path, substituted: false, remoteUID: nil, remoteHome: nil)
        }
        do {
            let buffer = try await client.executeCommand(probeCommand, maxResponseSize: 4096)
            let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
            let raw = String(bytes: bytes, encoding: .utf8) ?? ""
            let (uid, home) = try parseProbeOutput(raw)
            let substituted = substitute(path: path, uid: uid, home: home)
            return ResolvedPath(path: substituted, substituted: true, remoteUID: uid, remoteHome: home)
        } catch let err as ResolverError {
            throw err
        } catch {
            throw ResolverError.probeFailed(error.localizedDescription)
        }
    }

    /// Resolve a tssh-transport path via the iosbridge `runCommand`
    /// helper. Same probe semantics as the Citadel path.
    static func resolve(
        path: String,
        usingTrzsz transport: TrzszGoTransport
    ) async throws -> ResolvedPath {
        guard requiresProbe(path: path) else {
            return ResolvedPath(path: path, substituted: false, remoteUID: nil, remoteHome: nil)
        }
        do {
            let bytes = try await transport.runRemoteCommand(probeCommand)
            let raw = String(data: bytes, encoding: .utf8) ?? ""
            let (uid, home) = try parseProbeOutput(raw)
            let substituted = substitute(path: path, uid: uid, home: home)
            return ResolvedPath(path: substituted, substituted: true, remoteUID: uid, remoteHome: home)
        } catch let err as ResolverError {
            throw err
        } catch {
            throw ResolverError.probeFailed(error.localizedDescription)
        }
    }

    // MARK: - Internals

    /// Cheap check so callers that pass a literal absolute path
    /// skip the round-trip entirely. Matches both placeholders so
    /// any path with at least one placeholder triggers the probe.
    private static func requiresProbe(path: String) -> Bool {
        path.contains("{UID}") || path.contains("{HOME}")
    }

    /// Parse the two-line probe output. Tolerant of trailing
    /// whitespace and the carriage returns some shells inject in
    /// CRLF environments.
    private static func parseProbeOutput(_ raw: String) throws -> (uid: String, home: String) {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmedRaw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw ResolverError.malformedProbeOutput(raw)
        }
        let uid = lines[0]
        let home = lines[1]
        // Light sanity check: UID is decimal, HOME starts with `/`.
        guard uid.allSatisfy({ $0.isNumber }), !uid.isEmpty else {
            throw ResolverError.malformedProbeOutput(raw)
        }
        guard home.hasPrefix("/") else {
            throw ResolverError.malformedProbeOutput(raw)
        }
        return (uid, home)
    }

    /// Order matters: substitute `{HOME}` first because it might
    /// contain `{UID}` if some user is doing something weird (we
    /// still substitute it correctly because the `{HOME}` literal
    /// has already been replaced).
    private static func substitute(path: String, uid: String, home: String) -> String {
        path
            .replacingOccurrences(of: "{HOME}", with: home)
            .replacingOccurrences(of: "{UID}", with: uid)
    }
}
