//
//  main.swift
//  rootshellvpn (VPN host)
//
//  LSUIElement agent that hosts the packet-tunnel system extension for the
//  macOS Standalone build. On launch it ensures the extension is activated and
//  starts the control server; the Catalyst app drives start/stop over the
//  App Group socket.
//

import AppKit
import os.log

let log = Logger(subsystem: "com.kk2.rootshellvpn.host", category: "main")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another host agent is already running, defer to it
        // so stale agents don't accumulate and fight over the control socket.
        // (On update the app kills the old host first, so this new one wins.)
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.kk2.rootshellvpn")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            log.info("another VPN host is already running; exiting")
            NSApp.terminate(nil)
            return
        }

        log.info("host launched at \(Bundle.main.bundlePath, privacy: .public)")
        // Activation happens on demand (awaited) when the app sends
        // `activateExtension`, so we don't race the tunnel start or double-submit.
        VPNControlServer.shared.start()

        // A live tunnel using an agent-backed key needs its signing broker
        // back after a host relaunch, or in-tunnel reconnects can't re-auth.
        Task { @MainActor in
            await VPNTunnelController.shared.resumeAgentBrokerIfNeeded()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // agent: no Dock icon
app.run()
