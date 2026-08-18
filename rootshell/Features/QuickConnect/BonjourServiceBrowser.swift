//
//  BonjourServiceBrowser.swift
//  rootshell
//
//  Per-service-type mDNS browsing engine. Owns one NWBrowser plus the
//  service-name / hostname dedup bookkeeping, and reports its results to
//  an owner (LocalNetworkDiscoveryManager) that layers path monitoring,
//  TTL, and pause/resume on top. One instance per Bonjour service type
//  (e.g. "_ssh._tcp" for SSH, "_rfb._tcp" for Screen Sharing).
//

import Foundation
import Network
import os.log

/// Browsing engine for a single Bonjour service type. Maintains the
/// discovered-host list with per-service dedup: multiple advertised
/// services can resolve to the same hostname, and only the first gets a
/// visible entry; the rest are tracked so one can take over if the
/// primary disappears.
@MainActor
final class BonjourServiceBrowser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LocalNetworkDiscovery")

    /// Bonjour service type this browser scans for (e.g. "_ssh._tcp").
    let serviceType: String

    /// Kind stamped onto every host this browser produces.
    let kind: DiscoveredServiceKind

    /// Port stamped onto discovered hosts (NWBrowser doesn't expose the
    /// advertised port; the actual port would only be known after resolution).
    let defaultPort: UInt16

    /// Currently discovered hosts for this service type.
    private(set) var discoveredHosts: [DiscoveredSSHHost] = []

    /// Whether the underlying NWBrowser is actively scanning. Forwards
    /// every assignment (not just changes) so an owner mirroring this into
    /// a @Published property sees the same assignment cadence as before
    /// the extraction.
    private(set) var isScanning: Bool = false {
        didSet { onScanningChanged?(isScanning) }
    }

    /// Fired after a browse-results batch that changed `discoveredHosts`.
    var onHostsChanged: (() -> Void)?

    /// Fired on every `isScanning` assignment with the new value.
    var onScanningChanged: ((Bool) -> Void)?

    /// Whether a browser object currently exists (started and not stopped).
    var isBrowsing: Bool { browser != nil }

    // MARK: - Private State

    private var browser: NWBrowser?

    /// Track discovered services by their service name for deduplication
    private var knownServiceNames: Set<String> = []

    /// Maps each resolved hostname to the set of service names that resolve to it.
    /// Only the first service for a hostname gets an entry in discoveredHosts;
    /// the rest are tracked here so they can take over if the primary is removed.
    private var hostnameServices: [String: Set<String>] = [:]

    /// Human-readable service label for log messages.
    private var logLabel: String {
        switch kind {
        case .ssh: return "SSH"
        case .vnc: return "VNC"
        }
    }

    // MARK: - Lifecycle

    init(serviceType: String, kind: DiscoveredServiceKind, defaultPort: UInt16) {
        self.serviceType = serviceType
        self.kind = kind
        self.defaultPort = defaultPort
    }

    deinit {
        browser?.cancel()
    }

    // MARK: - Control

    func start() {
        guard browser == nil else {
            Self.logger.debug("Browser already running")
            return
        }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: parameters)

        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                self?.handleBrowseResults(results, changes: changes)
            }
        }

        browser?.start(queue: DispatchQueue.global(qos: .utility))
        isScanning = true
        let type = serviceType
        Self.logger.info("Started mDNS browser for \(type)")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isScanning = false
        Self.logger.info("Stopped mDNS browser")
    }

    func restart() {
        stop()
        // Preserve all tracking state (knownServiceNames, hostnameServices,
        // discoveredHosts). The new NWBrowser reports all currently-visible
        // services as .added; existing entries in knownServiceNames block
        // duplicates while genuinely new services pass through. This also
        // preserves secondary service mappings that can't be reconstructed
        // from discoveredHosts alone, and keeps results visible if the new
        // browser fails to start.
        start()
    }

    /// Drop all discovered hosts and tracking state. Does not fire
    /// `onHostsChanged` — the owner clears its own mirror alongside.
    func clear() {
        discoveredHosts.removeAll()
        knownServiceNames.removeAll()
        hostnameServices.removeAll()
    }

    // MARK: - Browse Handling

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            Self.logger.debug("Browser ready")
        case .failed(let error):
            Self.logger.error("Browser failed: \(error.localizedDescription)")
            isScanning = false
        case .cancelled:
            Self.logger.debug("Browser cancelled")
            isScanning = false
        case .setup:
            Self.logger.debug("Browser setting up")
        case .waiting(let error):
            Self.logger.warning("Browser waiting: \(error.localizedDescription)")
        @unknown default:
            Self.logger.debug("Browser unknown state")
        }
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        var hostsChanged = false
        let now = Date()
        let label = logLabel

        for change in changes {
            switch change {
            case .added(let result):
                if let host = makeDiscoveredHost(from: result, discoveredAt: now) {
                    guard !knownServiceNames.contains(host.serviceName) else { continue }
                    knownServiceNames.insert(host.serviceName)
                    let isNewHostname = hostnameServices[host.hostname] == nil
                    hostnameServices[host.hostname, default: []].insert(host.serviceName)
                    if isNewHostname {
                        discoveredHosts.append(host)
                        hostsChanged = true
                        Self.logger.info("Discovered \(label) host: \(host.serviceName) at \(host.hostname)")
                    } else {
                        Self.logger.debug("Additional service \(host.serviceName) for known host \(host.hostname)")
                    }
                }

            case .removed(let result):
                if case .service(let name, _, _, _) = result.endpoint {
                    guard knownServiceNames.contains(name) else { continue }
                    knownServiceNames.remove(name)
                    // Find which hostname this service belonged to
                    guard let hostname = hostnameServices.first(where: { $0.value.contains(name) })?.key else { continue }
                    hostnameServices[hostname]?.remove(name)
                    if hostnameServices[hostname]?.isEmpty ?? true {
                        // Last service for this hostname — remove the host entry
                        hostnameServices.removeValue(forKey: hostname)
                        discoveredHosts.removeAll { $0.hostname == hostname }
                        hostsChanged = true
                        Self.logger.info("\(label) host removed: \(name) (\(hostname))")
                    } else if let index = discoveredHosts.firstIndex(where: { $0.serviceName == name }) {
                        // The displayed entry used this service name; swap to a remaining one
                        let remaining = hostnameServices[hostname]!.first!
                        discoveredHosts[index] = DiscoveredSSHHost(
                            serviceName: remaining,
                            hostname: hostname,
                            port: discoveredHosts[index].port,
                            kind: kind,
                            discoveredAt: discoveredHosts[index].discoveredAt
                        )
                        hostsChanged = true
                        Self.logger.info("\(label) service \(name) removed, replaced by \(remaining) for \(hostname)")
                    }
                }

            case .changed(old: _, new: let newResult, flags: _):
                if let host = makeDiscoveredHost(from: newResult, discoveredAt: now) {
                    guard knownServiceNames.contains(host.serviceName) else { continue }
                    // Find the old hostname for this service (if any) and update tracking
                    let oldHostname = hostnameServices.first(where: { $0.value.contains(host.serviceName) })?.key
                    if let oldHostname, oldHostname != host.hostname {
                        // Hostname changed — migrate between hostname groups
                        hostnameServices[oldHostname]?.remove(host.serviceName)
                        if hostnameServices[oldHostname]?.isEmpty ?? true {
                            hostnameServices.removeValue(forKey: oldHostname)
                        }
                    }
                    hostnameServices[host.hostname, default: []].insert(host.serviceName)

                    if let index = discoveredHosts.firstIndex(where: { $0.serviceName == host.serviceName }) {
                        if let oldHostname, oldHostname != host.hostname,
                           discoveredHosts.contains(where: { $0.hostname == host.hostname && $0.serviceName != host.serviceName }) {
                            // New hostname already covered by another entry — remove this duplicate
                            discoveredHosts.remove(at: index)
                            // Backfill: if old hostname still has other services, it needs a visible entry
                            if let remainingService = hostnameServices[oldHostname]?.first,
                               !discoveredHosts.contains(where: { $0.hostname == oldHostname }) {
                                discoveredHosts.append(DiscoveredSSHHost(
                                    serviceName: remainingService,
                                    hostname: oldHostname,
                                    port: host.port,
                                    kind: kind,
                                    discoveredAt: now
                                ))
                            }
                        } else {
                            discoveredHosts[index] = host
                        }
                        hostsChanged = true
                    } else if !discoveredHosts.contains(where: { $0.hostname == host.hostname }) {
                        // Secondary service moved to an unrepresented hostname — materialize it
                        discoveredHosts.append(host)
                        hostsChanged = true
                    }
                }

            case .identical:
                break

            @unknown default:
                break
            }
        }

        // Reconcile tracking state against the browser's full results set.
        // Services that we track but the browser no longer reports are stale
        // (e.g. disappeared while the browser was stopped between restarts).
        let currentServiceNames = Set(results.compactMap { result -> String? in
            if case .service(let name, _, _, _) = result.endpoint { return name }
            return nil
        })
        let staleNames = knownServiceNames.subtracting(currentServiceNames)
        for staleName in staleNames {
            knownServiceNames.remove(staleName)
            guard let hostname = hostnameServices.first(where: { $0.value.contains(staleName) })?.key else { continue }
            hostnameServices[hostname]?.remove(staleName)
            if hostnameServices[hostname]?.isEmpty ?? true {
                hostnameServices.removeValue(forKey: hostname)
                discoveredHosts.removeAll { $0.hostname == hostname }
                hostsChanged = true
            } else if let index = discoveredHosts.firstIndex(where: { $0.serviceName == staleName }) {
                let remaining = hostnameServices[hostname]!.first!
                discoveredHosts[index] = DiscoveredSSHHost(
                    serviceName: remaining,
                    hostname: hostname,
                    port: discoveredHosts[index].port,
                    kind: kind,
                    discoveredAt: discoveredHosts[index].discoveredAt
                )
                hostsChanged = true
            }
        }

        if hostsChanged {
            onHostsChanged?()
        }
    }

    private func makeDiscoveredHost(from result: NWBrowser.Result, discoveredAt: Date) -> DiscoveredSSHHost? {
        guard case .service(let name, _, let domain, _) = result.endpoint else {
            return nil
        }

        // Build hostname from service name and domain
        // Service name is like "My MacBook Pro" or "John's MacBook", domain is "local."
        // We want "my-macbook-pro.local" or "johns-macbook.local"
        // Remove apostrophes, quotes, and other special characters; replace spaces with hyphens
        let sanitizedName = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")      // straight apostrophe
            .replacingOccurrences(of: "\u{2019}", with: "") // curly apostrophe (right single quote)
            .replacingOccurrences(of: "\u{2018}", with: "") // curly apostrophe (left single quote)
            .replacingOccurrences(of: "\"", with: "")     // straight double quote
            .replacingOccurrences(of: "\u{201C}", with: "") // curly double quote (left)
            .replacingOccurrences(of: "\u{201D}", with: "") // curly double quote (right)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }  // keep only valid hostname chars
            .replacingOccurrences(of: "--", with: "-")  // collapse double hyphens
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))  // trim leading/trailing hyphens

        let hostname: String
        if domain == "local." {
            hostname = "\(sanitizedName).local"
        } else {
            hostname = "\(sanitizedName).\(domain)"
        }

        return DiscoveredSSHHost(
            serviceName: name,
            hostname: hostname,
            port: defaultPort,
            kind: kind,
            discoveredAt: discoveredAt
        )
    }
}
