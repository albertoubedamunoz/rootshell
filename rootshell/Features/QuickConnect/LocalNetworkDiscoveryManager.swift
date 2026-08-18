//
//  LocalNetworkDiscoveryManager.swift
//  rootshell
//
//  Manages mDNS discovery of SSH hosts on the local network.
//  Only scans when on WiFi or Ethernet.
//

import Foundation
import Network
import Combine
import os.log

/// Manages mDNS discovery of SSH services on the local network.
/// Owns the network-path gating, cache TTL, and background pause/resume;
/// the per-service-type browsing itself lives in ``BonjourServiceBrowser``.
@MainActor
final class LocalNetworkDiscoveryManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LocalNetworkDiscovery")

    static let shared = LocalNetworkDiscoveryManager()

    /// Cache TTL - 15 minutes
    static let cacheTTL: TimeInterval = 15 * 60

    // MARK: - Published State

    /// Currently discovered hosts across all browsed service types.
    /// Dedup is per-kind (each browser tracks its own service names and
    /// hostnames), so a Mac advertising both _ssh._tcp and _rfb._tcp
    /// appears twice: once as .ssh and once as .vnc.
    @Published private(set) var discoveredHosts: [DiscoveredSSHHost] = []

    /// Discovered Screen Sharing (_rfb._tcp) hosts.
    var discoveredVNCHosts: [DiscoveredSSHHost] {
        discoveredHosts.filter { $0.kind == .vnc }
    }

    /// Whether mDNS scanning is currently active
    @Published private(set) var isScanning: Bool = false

    /// Whether we're currently on a local network (WiFi or Ethernet)
    @Published private(set) var isOnLocalNetwork: Bool = false

    /// Publisher for cache changes (for QuickConnectSuggestionProvider to observe)
    let cacheDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Private State

    private let sshBrowser: BonjourServiceBrowser
    private let vncBrowser: BonjourServiceBrowser
    private var pathMonitor: NWPathMonitor?
    private var lastScanDate: Date?

    /// All browsers, sharing one lifecycle (path gating, TTL, pause/resume).
    private var browsers: [BonjourServiceBrowser] { [sshBrowser, vncBrowser] }

    // MARK: - Initialization

    private init() {
        sshBrowser = BonjourServiceBrowser(serviceType: "_ssh._tcp", kind: .ssh, defaultPort: 22)
        vncBrowser = BonjourServiceBrowser(serviceType: "_rfb._tcp", kind: .vnc, defaultPort: 5900)
        for browser in browsers {
            browser.onHostsChanged = { [weak self] in
                self?.handleBrowserHostsChanged()
            }
            browser.onScanningChanged = { [weak self] _ in
                guard let self else { return }
                self.isScanning = self.browsers.contains { $0.isScanning }
            }
        }
        setupPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
        // Each browser cancels its NWBrowser in its own deinit.
    }

    // MARK: - Public API

    /// Refresh discovery if cache is stale
    func refreshIfStale() {
        guard isOnLocalNetwork else {
            Self.logger.debug("Not refreshing - not on local network")
            return
        }

        if let lastScan = lastScanDate,
           Date().timeIntervalSince(lastScan) < Self.cacheTTL {
            Self.logger.debug("Cache still fresh, skipping refresh")
            return
        }

        Self.logger.info("Cache stale, restarting discovery")
        restartBrowsing()
    }

    /// Force a fresh scan regardless of TTL
    func forceRefresh() {
        guard isOnLocalNetwork else {
            Self.logger.debug("Cannot force refresh - not on local network")
            return
        }

        Self.logger.info("Force refresh requested")
        restartBrowsing()
    }

    // MARK: - Network Path Monitoring

    private func setupPathMonitor() {
        startPathMonitoring()
    }

    func pauseNetworkMonitoringForBackground() {
        guard pathMonitor != nil || browsers.contains(where: { $0.isBrowsing }) else { return }
        LifecycleDebugLogger.shared.checkpoint("LocalDiscovery.pathMonitor.pause")
        stopBrowsing()
        isOnLocalNetwork = false
        stopPathMonitoring()
    }

    func resumeNetworkMonitoringAfterForeground() {
        guard pathMonitor == nil else { return }
        LifecycleDebugLogger.shared.checkpoint("LocalDiscovery.pathMonitor.resume")
        startPathMonitoring()
    }

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard !Ghostty.isAppBackgroundedAtomic,
                  !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
            Task { @MainActor [weak self] in
                guard !Ghostty.isAppBackgroundedAtomic,
                      !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
                self?.handlePathUpdate(path)
            }
        }

        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasOnLocalNetwork = isOnLocalNetwork
        isOnLocalNetwork = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)

        Self.logger.debug("Network path update: wifi=\(path.usesInterfaceType(.wifi)), ethernet=\(path.usesInterfaceType(.wiredEthernet)), isLocal=\(self.isOnLocalNetwork)")

        if isOnLocalNetwork && !wasOnLocalNetwork {
            Self.logger.info("Now on local network, starting mDNS discovery")
            startBrowsing()
        } else if !isOnLocalNetwork && wasOnLocalNetwork {
            Self.logger.info("Left local network, stopping mDNS discovery")
            stopBrowsing()
            clearCache()
        }
    }

    // MARK: - mDNS Browsing

    private func startBrowsing() {
        browsers.forEach { $0.start() }
    }

    private func stopBrowsing() {
        browsers.forEach { $0.stop() }
    }

    private func restartBrowsing() {
        browsers.forEach { $0.restart() }
    }

    /// A browser reported a changed host set: merge all browsers into the
    /// published cache and stamp the TTL clock. Each browser dedups within
    /// its own service type, so concatenation preserves distinct entries
    /// for hosts advertising multiple services.
    private func handleBrowserHostsChanged() {
        discoveredHosts = browsers.flatMap { $0.discoveredHosts }
        lastScanDate = Date()
        cacheDidChange.send()
        let hostCount = discoveredHosts.count
        Self.logger.info("Updated discovered hosts, count: \(hostCount)")
    }

    private func clearCache() {
        browsers.forEach { $0.clear() }
        discoveredHosts.removeAll()
        lastScanDate = nil
        cacheDidChange.send()
        Self.logger.info("Cleared discovery cache")
    }
}
