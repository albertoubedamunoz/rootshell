//
//  TerminalView+RemotePorts.swift
//  rootshell
//
//  Starts and stops the per-pane listening-port scan at the same boundaries
//  as the session and the surface's visibility.
//

import Foundation

extension Ghostty.TerminalView {
    /// Called when the session is ready. No-op for transports that cannot run
    /// an out-of-band command (Mosh has no such channel).
    func startRemotePortMonitor() {
        // Local shells are not remote hosts; the pill is for SSH/tssh/mosh.
        guard connectionConfig.underlyingSSHConfig != nil,
              RemoteExecProbe.canProbe(self) else {
            remotePortMonitor?.stop()
            return
        }
        if remotePortMonitor == nil {
            remotePortMonitor = RemotePortMonitor(terminal: self)
        }
        remotePortMonitor?.start()
    }

    func stopRemotePortMonitor() {
        remotePortMonitor?.stop()
        remotePortMonitor = nil
        Task { await remotePortForwarder.stopAll() }
    }

    func setRemotePortMonitorVisible(_ visible: Bool) {
        remotePortMonitor?.setVisible(visible)
    }
}
