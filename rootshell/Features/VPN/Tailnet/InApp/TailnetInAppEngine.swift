//
//  TailnetInAppEngine.swift
//  rootshell
//
//  Tailscale running inside rootshell ("rootshell Only"): no VPN, only the
//  app's own connections reach the tailnet. Shares the VPN's node identity,
//  so only one of the two modes runs at a time.
//

#if !CHINA_BUILD

import Foundation
import os
import UIKit

@MainActor
@Observable
final class TailnetInAppEngine {
    static let shared = TailnetInAppEngine()

    private static let logger = Logger(subsystem: "com.rootshell", category: "TailnetInApp")

    private(set) var status: TailnetStatus?
    /// The Go engine is up (in any login state).
    private(set) var isStarted = false
    private(set) var lastError: String?
    private var startTask: Task<Void, Error>?

    var isRunning: Bool { status?.isRunning == true }

    private init() {
        // A suspended app misses network changes; let Tailscale re-check.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if TailnetInAppEngine.shared.isStarted { TailnetPathMonitor.shared.refresh() }
            }
        }
    }

    // MARK: - Lifecycle

    /// Applies saved settings at launch; without connect-on-demand a turned-on
    /// engine starts right away.
    func appDidLaunch() {
        syncRouting()
        let mode = TailnetModeSettings.load()
        guard mode.effectiveMode == .rootshellOnly, mode.inAppEnabled else { return }
        Task {
            await updateShellProxy()
            if !mode.connectOnDemand { try? await start() }
        }
    }

    /// Turns rootshell Only on and starts the engine, showing the login page
    /// if it needs one.
    func turnOn() async throws {
        var mode = TailnetModeSettings.load()
        mode.inAppEnabled = true
        TailnetModeSettings.store(mode)
        syncRouting()
        try await start()
        await updateShellProxy()
        TailnetLoginCoordinator.shared.watch()
    }

    func turnOff() async {
        var mode = TailnetModeSettings.load()
        mode.inAppEnabled = false
        TailnetModeSettings.store(mode)
        syncRouting()
        await stop()
        await updateShellProxy()
    }

    func start() async throws {
        if isStarted { return }
        if let startTask { return try await startTask.value }
        let task = Task { try await performStart() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func performStart() async throws {
        guard TailnetGo.isSupported else {
            throw TailnetGo.GoError(message: String(localized: "Tailscale isn't available in this build.", comment: "In-app Tailscale unsupported error"))
        }
        // One node key can't run in two processes.
        if TailnetPlatform.supportsWholeDevice {
            await VPNManager.shared.stopTailnetVPNAndWait()
        }

        let settings = VPNTailnetProfile.settings()
        let mode = TailnetModeSettings.load()
        let stateDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("tailscale-inapp", isDirectory: true).path ?? ""
        let config: [String: Any] = [
            "hostname": settings.hostname.isEmpty ? Self.defaultHostname : settings.hostname,
            "acceptRoutes": settings.acceptRoutes,
            "exitNodeID": mode.exitNodeID ?? "",
            "exitNodeAllowLAN": mode.exitNodeAllowLAN,
            "stateDir": stateDir,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let callback = TailnetGoCallback { status in
            Task { @MainActor in TailnetInAppEngine.shared.apply(status) }
        }
        Self.logger.info("Starting in-app Tailscale")
        await TailnetPathMonitor.shared.start()
        do {
            try await TailnetGo.start(configJSON: json, store: TailnetGoStateStore(), callback: callback)
        } catch {
            TailnetPathMonitor.shared.stop()
            throw error
        }
        isStarted = true
        lastError = nil
        TailnetStateHandoff.engineDidStart()
        apply(await TailnetGo.status())
    }

    func stop() async {
        startTask?.cancel()
        guard isStarted else { return }
        Self.logger.info("Stopping in-app Tailscale")
        await TailnetGo.stop()
        isStarted = false
        TailnetPathMonitor.shared.stop()
        status = nil
        TailnetRouting.shared.update { $0.routedHosts = [] }
    }

    /// The Whole Device VPN is about to start with the same node key.
    func stopForVPN() async {
        await stop()
    }

    /// Starts the engine if needed and waits for it to come online. False
    /// when it needs a sign-in (the login page is offered) or times out.
    func ensureRunning(timeout: Duration = .seconds(10)) async -> Bool {
        if TailnetGo.isRunning { return true }
        do {
            try await start()
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("In-app Tailscale failed to start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if TailnetGo.isRunning { return true }
            if status?.needsLogin == true {
                Self.logger.info("In-app Tailscale needs sign-in")
                TailnetLoginCoordinator.shared.watch()
                return false
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        let running = TailnetGo.isRunning
        if !running {
            Self.logger.error("In-app Tailscale not running after \(String(describing: timeout), privacy: .public) (state \(self.status?.state ?? "none", privacy: .public))")
        }
        return running
    }

    // MARK: - Commands

    func login() async -> String? {
        do {
            try await start()
            try await TailnetGo.login()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func logout() async -> String? {
        guard isStarted else {
            return String(localized: "Tailscale isn't running.", comment: "In-app Tailscale sign-out error")
        }
        do {
            try await TailnetGo.logout()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard isStarted else { return }
        apply(await TailnetGo.status())
    }

    /// Pushes changed device and exit-node settings into the running engine.
    func applyPrefs() async {
        syncRouting()
        TailnetRouting.shared.update { $0.routedHosts = [] }
        guard isStarted else { return }
        let settings = VPNTailnetProfile.settings()
        let mode = TailnetModeSettings.load()
        let prefs: [String: Any] = [
            "hostname": settings.hostname.isEmpty ? Self.defaultHostname : settings.hostname,
            "acceptRoutes": settings.acceptRoutes,
            "exitNodeID": mode.exitNodeID ?? "",
            "exitNodeAllowLAN": mode.exitNodeAllowLAN,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: prefs) else { return }
        do {
            try await TailnetGo.setPrefs(json: String(decoding: data, as: UTF8.self))
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - State

    private func apply(_ newStatus: TailnetStatus?) {
        guard isStarted else { return }
        status = newStatus
        guard let newStatus else { return }
        VPNTailnetProfile.recordBackendState(newStatus.state)
        if newStatus.isRunning {
            cachePeers(newStatus)
        }
    }

    /// Mirrors settings into the thread-safe routing snapshot.
    func syncRouting() {
        let mode = TailnetModeSettings.load()
        TailnetRouting.shared.update { TailnetRouting.apply(mode, to: &$0) }
    }

    /// Starts the loopback proxy local-shell tools use, or stops it.
    func updateShellProxy() async {
        let mode = TailnetModeSettings.load()
        let wanted = mode.effectiveMode == .rootshellOnly && mode.inAppEnabled && mode.useInLocalShell
        guard wanted, TailnetGo.isSupported else {
            await TailnetGo.stopProxy()
            TailnetRouting.shared.update { $0.shellProxyEnvironment = nil }
            return
        }
        do {
            let info = try await TailnetGo.startProxy()
            let env = [
                "ALL_PROXY": "socks5h://\(info.user):\(info.pass)@127.0.0.1:\(info.port)",
                "NO_PROXY": "localhost,127.0.0.1,::1",
            ]
            TailnetRouting.shared.update { $0.shellProxyEnvironment = env }
        } catch {
            Self.logger.error("Tailscale shell proxy failed: \(error.localizedDescription, privacy: .public)")
            TailnetRouting.shared.update { $0.shellProxyEnvironment = nil }
        }
    }

    // MARK: - Peer cache

    private func cachePeers(_ status: TailnetStatus) {
        var names = Set<String>()
        for peer in status.peers ?? [] {
            names.insert(peer.displayName.lowercased())
            if let dns = peer.dnsName, !dns.isEmpty { names.insert(dns.lowercased()) }
        }
        TailnetRouting.shared.storePeers(suffix: status.magicDNSSuffix?.lowercased(), names: names)
    }

    static var defaultHostname: String {
        #if targetEnvironment(macCatalyst)
        "rootshell-mac"
        #else
        "rootshell-" + UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "-")
        #endif
    }
}

#endif
