#if !targetEnvironment(macCatalyst)

import Foundation
import NetworkExtension

extension LocalShellSession {
    private enum VPNAction {
        case status
        case list
        case start(String)
        case stop
    }

    private enum VPNProfileMatch {
        case found(ConnectionProfile)
        case ambiguous([ConnectionProfile])
        case notFound
    }

    /// Handle the vpn command: show status, list VPN profiles, start or stop the tunnel.
    func handleVPNCommand(_ command: String) {
        let args = Array(Self.splitArgv(command).dropFirst())

        if args.contains("-h") || args.contains("--help") || args.first == "help" {
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            onOutput?(normalizeLineEndings(Self.vpnHelpText))
            displayPrompt()
            return
        }

        let subcommand = args.first?.lowercased() ?? "status"
        let operands = args.dropFirst()
        let action: VPNAction?
        var problem = "'\(subcommand)' takes no arguments"
        switch subcommand {
        case "status", "st":
            action = operands.isEmpty ? .status : nil
        case "list", "ls":
            action = operands.isEmpty ? .list : nil
        case "start", "up", "connect":
            action = operands.isEmpty ? nil : .start(operands.joined(separator: " "))
            problem = "'\(subcommand)' needs a profile name"
        case "stop", "down", "disconnect":
            action = operands.isEmpty ? .stop : nil
        default:
            action = nil
            problem = "unknown command '\(subcommand)'"
        }

        guard let action else {
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            vpnFailure("vpn: \(problem)")
            vpnPrint(TerminalStyle.fg(TerminalStyle.dim, "usage: vpn [status | list | start <profile> | stop]"))
            displayPrompt()
            return
        }

        vpnTask?.cancel()
        onTitleChange?("vpn \(subcommand)")
        sessionMode = .vpnRunning
        vpnTask = Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.runVPNAction(action)
            guard !Task.isCancelled else { return }
            self.vpnTask = nil
            self.sessionMode = .localShell
            self.lastCommandSucceeded = succeeded
            self.scriptCommandExitCode = succeeded ? 0 : 1
            guard self.isRunning else { return }
            self.onTitleChange?(self.formatPathForTitle(sessionCurrentDirectory))
            self.displayPrompt()
        }
    }

    /// Ctrl-C: stop waiting and return to the prompt; a started tunnel change carries on.
    func cancelVPNCommand() {
        vpnTask?.cancel()
        vpnTask = nil
        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 130
        cleanupInlineSpinner()
        onOutput?("^C\r\n")
        displayPrompt()
    }

    private func runVPNAction(_ action: VPNAction) async -> Bool {
        await VPNManager.shared.refreshStatusFromSystem()
        switch action {
        case .status:
            await printVPNStatus()
            return true
        case .list:
            printVPNProfiles()
            return true
        case .start(let query):
            return await startVPNProfile(matching: query)
        case .stop:
            return await stopVPN()
        }
    }

    // MARK: - Status

    private func printVPNStatus() async {
        let vpn = VPNManager.shared
        if vpn.status == .connected {
            await vpn.requestStatusUpdate()
        }

        let cols = vpnColumns
        let status = vpn.status
        let isUp = status.isActive || status == .disconnecting
        let badge = "● \(status.logDescription)"
        var header = TerminalStyle.boldFg(vpnStatusColor(status), badge)
        let nameRoom = cols - RFWidth.width(of: badge) - 3
        if isUp, let name = vpn.activeProfileName, nameRoom >= 4 {
            header += TerminalStyle.fg(TerminalStyle.dim, " · ") + TerminalStyle.bold(RFWidth.truncate(name, to: nameRoom))
        }
        vpnPrint(header)

        var rows: [(label: String, value: String)] = []
        if isUp {
            if let profile = vpnProfiles.first(where: { $0.id == vpn.activeProfileID }) {
                rows.append(("host", profile.displayString))
            }
            if status == .connected, let since = vpn.connectedSince {
                rows.append(("uptime", ConnectionInfoSheet.formatDuration(from: since, to: Date())))
            }
            if let stats = vpn.statistics {
                if let mode = stats.tsshMode {
                    rows.append(("transport", mode))
                }
                rows.append(("traffic", "↓ \(stats.formattedBytesIn)  ↑ \(stats.formattedBytesOut)"))
                rows.append(("flows", "\(stats.activeConnections) (\(stats.activeTCPConnections) TCP, \(stats.activeUDPConnections) UDP)"))
            }
        } else if let error = vpn.lastExtensionError.flatMap(Self.firstLine) {
            rows.append(("last error", error))
        }

        let labelWidth = 10
        for row in rows {
            let label = row.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
            vpnPrint("  " + TerminalStyle.fg(TerminalStyle.dim, label) + " " + vpnFit(row.value, indent: labelWidth + 3))
        }

        if !isUp {
            let hint = vpnProfiles.isEmpty
                ? "Enable VPN in a connection profile's settings."
                : "vpn start <profile> to connect, vpn list for profiles."
            vpnPrint("  " + TerminalStyle.fg(TerminalStyle.dim, vpnFit(hint, indent: 2)))
        }
    }

    // MARK: - List

    private func printVPNProfiles() {
        let profiles = vpnProfiles
        guard !profiles.isEmpty else {
            vpnPrint(TerminalStyle.fg(TerminalStyle.dim, "No VPN profiles. Enable VPN in a connection profile's settings."))
            return
        }

        let vpn = VPNManager.shared
        let cols = vpnColumns
        let marker = 2
        let gap = String(repeating: " ", count: 2)
        let kindWidth = 4
        var nameWidth = max(4, profiles.map { RFWidth.width(of: $0.name) }.max() ?? 0)
        var hostWidth = max(4, profiles.map { RFWidth.width(of: $0.displayString) }.max() ?? 0)

        // Drop the type column first, then share the rest between name and host.
        let showKind = marker + nameWidth + gap.count + hostWidth + gap.count + kindWidth <= cols
        if !showKind {
            let room = cols - marker - gap.count
            if nameWidth + hostWidth > room {
                nameWidth = min(nameWidth, max(room / 2, room - hostWidth))
                hostWidth = room - nameWidth
            }
        }
        let showHost = showKind || hostWidth >= 6
        if !showHost {
            nameWidth = max(1, cols - marker)
        }

        func cell(_ text: String, _ width: Int) -> String {
            let truncated = RFWidth.truncate(text, to: width)
            return truncated + String(repeating: " ", count: max(0, width - RFWidth.width(of: truncated)))
        }

        var header = "  " + cell("NAME", nameWidth)
        if showHost { header += gap + cell("HOST", hostWidth) }
        if showKind { header += gap + "TYPE" }
        vpnPrint(TerminalStyle.fg(TerminalStyle.dim, header))

        let activeID = (vpn.status.isActive || vpn.status == .disconnecting) ? vpn.activeProfileID : nil
        for profile in profiles {
            let isActive = profile.id == activeID
            let name = cell(profile.name, nameWidth)
            var line = isActive
                ? TerminalStyle.fg(vpnStatusColor(vpn.status), "●") + " " + TerminalStyle.bold(name)
                : "  " + name
            if showHost { line += gap + cell(profile.displayString, hostWidth) }
            if showKind { line += gap + TerminalStyle.fg(TerminalStyle.cyan, profile.vpnTransportName) }
            vpnPrint(line)
        }
    }

    // MARK: - Start / Stop

    private func startVPNProfile(matching query: String) async -> Bool {
        let profile: ConnectionProfile
        switch resolveVPNProfile(query) {
        case .found(let match):
            profile = match
        case .notFound:
            vpnFailure("No VPN profile matches '\(query)'. Run 'vpn list' to see them.")
            return false
        case .ambiguous(let matches):
            vpnFailure("'\(query)' matches \(matches.count) profiles:")
            for match in matches {
                vpnPrint("  " + vpnFit(match.name, indent: 2))
            }
            return false
        }

        let vpn = VPNManager.shared
        if vpn.status == .connected, vpn.activeProfileID == profile.id {
            vpnSuccess("Already connected to \(profile.name).")
            return true
        }

        startInlineSpinner(message: "Connecting VPN to \(profile.name)...")
        let previousError = vpn.lastExtensionError
        let outcome: VPNConnectionPoller.ConnectOutcome
        do {
            try await vpn.startVPN(for: profile)
            guard let snapshot = VPNSharedProfileStore.profile(id: profile.id) else {
                throw VPNStartController.StartError.profileNotFound
            }
            outcome = await VPNConnectionPoller.pollForConnection(
                snapshot: snapshot,
                writeConnectedState: false,
                treatUnknownFinalStatusAsFailed: false,
                seconds: 30
            )
        } catch {
            cleanupVPNSpinner()
            vpnFailure(error.localizedDescription)
            return false
        }
        cleanupVPNSpinner()

        switch outcome {
        case .connected:
            vpnSuccess("Connected to \(profile.name).")
            return true
        case .failed:
            let error = vpn.lastExtensionError == previousError ? nil : vpn.lastExtensionError.flatMap(Self.firstLine)
            vpnFailure("\(profile.name) failed to connect: \(error ?? "the tunnel stopped").")
            return false
        case .timeout:
            vpnFailure("Still connecting to \(profile.name). Check 'vpn status'.")
            return false
        }
    }

    private func stopVPN() async -> Bool {
        let vpn = VPNManager.shared
        guard vpn.status.isActive || vpn.status == .disconnecting else {
            vpnPrint(TerminalStyle.fg(TerminalStyle.dim, "VPN is not connected."))
            return true
        }

        let name = vpn.activeProfileName ?? "VPN"
        startInlineSpinner(message: "Disconnecting VPN from \(name)...")
        let outcome: VPNConnectionPoller.DisconnectOutcome
        do {
            try await vpn.stopVPN()
            guard let manager = try await NETunnelProviderManager.loadAllFromPreferences().first else {
                cleanupVPNSpinner()
                vpnSuccess("Disconnected from \(name).")
                return true
            }
            outcome = await VPNConnectionPoller.pollForDisconnection(manager: manager, checkSharedState: false, seconds: 10)
        } catch {
            cleanupVPNSpinner()
            vpnFailure(error.localizedDescription)
            return false
        }
        cleanupVPNSpinner()

        switch outcome {
        case .disconnected:
            vpnSuccess("Disconnected from \(name).")
            return true
        case .timeout:
            vpnFailure("Still disconnecting from \(name). Check 'vpn status'.")
            return false
        }
    }

    // MARK: - Helpers

    private var vpnProfiles: [ConnectionProfile] {
        ConnectionProfileManager.shared.profiles.filter(\.isVPNCapable)
    }

    /// Terminal width read per render so output follows resizes.
    private var vpnColumns: Int {
        max(20, Int(pty.windowSize.cols))
    }

    /// `text` truncated to the columns left after `indent`.
    private func vpnFit(_ text: String, indent: Int) -> String {
        RFWidth.truncate(text, to: max(1, vpnColumns - indent))
    }

    private func resolveVPNProfile(_ query: String) -> VPNProfileMatch {
        let profiles = vpnProfiles
        if let id = UUID(uuidString: query), let match = profiles.first(where: { $0.id == id }) {
            return .found(match)
        }
        let needle = query.lowercased()
        let tiers: [(ConnectionProfile) -> Bool] = [
            { $0.name.lowercased() == needle },
            { $0.name.lowercased().hasPrefix(needle) },
            { $0.name.lowercased().contains(needle) || $0.sshConfig.host.lowercased().contains(needle) },
        ]
        for tier in tiers {
            let matches = profiles.filter(tier)
            if matches.count == 1 { return .found(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return .notFound
    }

    private func vpnStatusColor(_ status: NEVPNStatus) -> TerminalStyle.Color {
        switch status {
        case .connected:
            return TerminalStyle.success
        case .connecting, .reasserting, .disconnecting:
            return TerminalStyle.warning
        case .invalid:
            return TerminalStyle.error
        default:
            return TerminalStyle.dim
        }
    }

    /// Ctrl-C already cleared the spinner for a cancelled run.
    private func cleanupVPNSpinner() {
        guard !Task.isCancelled else { return }
        cleanupInlineSpinner()
    }

    private func vpnSuccess(_ message: String) {
        vpnPrint(TerminalStyle.fg(TerminalStyle.success, TerminalStyle.checkIcon) + " " + vpnFit(message, indent: 2))
    }

    /// Failures wrap rather than truncate so the full reason stays readable.
    private func vpnFailure(_ message: String) {
        vpnPrint(TerminalStyle.fg(TerminalStyle.error, TerminalStyle.crossIcon + " " + message))
    }

    /// Drops late output from a run that Ctrl-C already returned to the prompt.
    private func vpnPrint(_ line: String) {
        guard !Task.isCancelled else { return }
        onOutput?(line + "\r\n")
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    private static let vpnHelpText = """
usage: vpn [status]
       vpn list
       vpn start <profile>
       vpn stop

Manage the rootshell VPN. Profiles appear here once VPN is enabled in
their connection settings.

Commands:
  status             Tunnel state, profile, uptime, and traffic (default)
  list, ls           VPN profiles; ● marks the active one
  start, up, connect Connect <profile>, switching from any active tunnel.
                     Matches a name, a name prefix, or a host.
  stop, down         Disconnect the active tunnel

start and stop wait for the tunnel to settle. Ctrl-C stops waiting but
does not cancel the change.

"""
}

#endif // !targetEnvironment(macCatalyst)
