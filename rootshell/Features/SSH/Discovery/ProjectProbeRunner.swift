//
//  ProjectProbeRunner.swift
//  rootshell
//
//  Runs ProjectProbeCommand over the connection a pane already holds, via
//  RemoteExecProbe. Never touches the user's interactive shell.
//

import Foundation

@MainActor
enum ProjectProbeRunner {

    /// Shared with every other out-of-band probe; see RemoteExecProbe.
    typealias ProbeError = RemoteExecProbe.ProbeError

    /// Whether a probe could run for this pane RIGHT NOW.
    static func canProbe(_ sessionOwner: Ghostty.TerminalView) -> Bool {
        RemoteExecProbe.canProbe(sessionOwner)
    }

    /// Probes `paths` on the host behind `sessionOwner`'s session.
    ///
    /// `sessionOwner` is the pane that actually HOLDS the connection: for an
    /// ordinary SSH pane that is the pane itself, for a tmux -CC pane it is
    /// the gateway, since a pane rides the gateway's connection and the
    /// repositories live on the gateway's host. The caller resolves that.
    static func probe(
        paths: [String],
        paneToken: String? = nil,
        on sessionOwner: Ghostty.TerminalView
    ) async throws -> ProjectProbeResult {
        // A pane token alone is worth probing for: it discovers the directory
        // that a plain SSH pane has no other way to report.
        guard !paths.isEmpty || paneToken != nil else { return ProjectProbeResult() }

        let (command, nonce) = ProjectProbeCommand.command(
            paths: paths,
            paneToken: paneToken,
            pathPrefix: SSHConfig.remoteExecPathPrefix)
        let output = try await RemoteExecProbe.run(command, on: sessionOwner)
        return ProjectProbeCommand.parse(output: output, nonce: nonce)
    }
}
