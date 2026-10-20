//
//  TerminalView+RemotePorts.swift
//  rootshell
//
//  Starts and stops the per-pane listening-port scan at the same boundaries
//  as the session and the surface's visibility.
//

import Foundation

extension Ghostty.TerminalView {
    /// Called when the session is ready, or when a tmux -CC or herdr binding
    /// attaches. No-op for transports that cannot run an out-of-band command.
    func startRemotePortMonitor() {
        // A projected pane has no session of its own; the monitor resolves its
        // gateway on every scan, since the gateway may not be ready yet.
        if !isTmuxPane, !isHerdrPane {
            // Local shells are not remote hosts; the pill is for SSH/tssh/mosh.
            guard connectionConfig.underlyingSSHConfig != nil,
                  RemoteExecProbe.canProbe(self) else {
                remotePortMonitor?.stop()
                return
            }
        }
        if remotePortMonitor == nil {
            remotePortMonitor = RemotePortMonitor(terminal: self)
        }
        // The surface usually reports occlusion before the session becomes
        // ready, so `setOcclusion` has already run by now and this monitor
        // never saw it. Seed visibility from the surface's current state,
        // otherwise the first scan only happens after a tab switch.
        remotePortMonitor?.setVisible(isTabVisible)
        remotePortMonitor?.start()
    }

    /// Forwards are left alone: they belong to the connection, which may
    /// outlive this pane (a tmux gateway) and tears them down itself.
    func stopRemotePortMonitor() {
        remotePortMonitor?.stop()
        remotePortMonitor = nil
    }

    /// tmux -CC and herdr panes never see `sessionDidBecomeReady`.
    func syncProjectedRemotePortMonitor() {
        if isTmuxPane || isHerdrPane {
            startRemotePortMonitor()
        } else {
            stopRemotePortMonitor()
        }
    }

    func setRemotePortMonitorVisible(_ visible: Bool) {
        remotePortMonitor?.setVisible(visible)
    }
}
