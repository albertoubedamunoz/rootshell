//
//  BackgroundTunnelManager.swift
//  rootshell
//
//  Singleton manager for all background port forward tunnels
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
import os.log

/// Manages all background port forward tunnels
@MainActor
@Observable
final class BackgroundTunnelManager {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "BackgroundTunnelManager")

    /// Shared singleton instance
    static let shared = BackgroundTunnelManager()

    // MARK: - State

    /// Active tunnels by profile ID
    private(set) var activeTunnels: [UUID: BackgroundTunnel] = [:]

    /// Profile IDs that are enabled for auto-start
    private(set) var enabledProfileIDs: Set<UUID> = []

    /// Event history (in-memory, capped)
    private(set) var eventHistory: [TunnelEvent] = []

    /// Maximum events to keep in memory
    private let maxEventHistory = 500

    // MARK: - Computed Properties

    /// Number of running tunnels
    var runningCount: Int {
        activeTunnels.values.filter { $0.state.isConnected }.count
    }

    /// Whether any tunnel is running
    var isAnyTunnelRunning: Bool {
        activeTunnels.values.contains { $0.state.isConnected }
    }

    /// Whether any tunnel is active (including connecting/reconnecting)
    var isAnyTunnelActive: Bool {
        activeTunnels.values.contains { $0.state.isActive }
    }

    /// Total statistics across all tunnels
    var totalStatistics: TunnelStatistics {
        var total = TunnelStatistics(tunnelID: UUID())
        for tunnel in activeTunnels.values {
            total.bytesIn += tunnel.statistics.bytesIn
            total.bytesOut += tunnel.statistics.bytesOut
            total.connectionCount += tunnel.statistics.connectionCount
        }
        return total
    }

    // MARK: - Persistence Keys

    private let enabledProfilesKey = "backgroundTunnelEnabledProfiles"

    // MARK: - Initialization

    private init() {
        loadEnabledProfiles()
    }

    // MARK: - Public Methods

    /// Start a tunnel for the given profile.
    /// - Parameter onHostKeyValidation: host-key prompt for the INITIAL connect
    ///   only (interactive Settings starts). nil = strict: accept known keys,
    ///   reject new or changed. Background reconnects are always strict.
    func startTunnel(
        for profile: ConnectionProfile,
        onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)? = nil
    ) async throws {
        guard profile.hasPortForwards else {
            Self.logger.warning("Cannot start tunnel for profile without port forwards: \(profile.name)")
            throw TunnelError.noPortForwardsConfigured
        }

        // Check if already running
        if let existing = activeTunnels[profile.id], existing.state.isActive {
            Self.logger.info("Tunnel already active for \(profile.name)")
            return
        }

        Self.logger.info("Starting tunnel for profile: \(profile.name)")

        let tunnel = BackgroundTunnel(
            profileID: profile.id,
            sshConfig: profile.sshConfig,
            profileName: profile.name,
            connectionProtocol: profile.connectionProtocol,
            trzszTransportMode: profile.trzszTransportMode,
            trzszMTU: profile.trzszMTU,
            trzszPortMin: profile.trzszPortMin,
            trzszPortMax: profile.trzszPortMax
        )

        // Set up callbacks
        tunnel.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }

        tunnel.onStateChange = { [weak self] (state: TunnelState) in
            Self.logger.debug("Tunnel state changed to \(state.displayName)")
            self?.notifyTunnelCountChanged()
        }

        // Prompt (if any) applies to the initial connect only; cleared after
        // start so background reconnects never prompt into a dead view and
        // stay strict (known keys pass silently, new/changed reject).
        tunnel.onHostKeyValidation = onHostKeyValidation

        activeTunnels[profile.id] = tunnel

        defer { tunnel.onHostKeyValidation = nil }
        try await tunnel.start()
    }

    /// Stop a tunnel by profile ID
    func stopTunnel(for profileID: UUID) async {
        guard let tunnel = activeTunnels[profileID] else {
            Self.logger.warning("No tunnel found for profile ID: \(profileID)")
            return
        }

        Self.logger.info("Stopping tunnel for profile ID: \(profileID)")
        await tunnel.stop()
        activeTunnels.removeValue(forKey: profileID)
        notifyTunnelCountChanged()
    }

    /// Stop all tunnels
    func stopAllTunnels() async {
        Self.logger.info("Stopping all tunnels (\(self.activeTunnels.count) active)")

        for (profileID, tunnel) in activeTunnels {
            await tunnel.stop()
            activeTunnels.removeValue(forKey: profileID)
        }
        notifyTunnelCountChanged()
    }

    /// Set enabled state for a profile
    func setEnabled(_ enabled: Bool, for profileID: UUID) {
        if enabled {
            enabledProfileIDs.insert(profileID)
        } else {
            enabledProfileIDs.remove(profileID)
        }
        saveEnabledProfiles()

        Self.logger.info("Tunnel enabled state for \(profileID): \(enabled)")
    }

    /// Check if a profile is enabled
    func isEnabled(_ profileID: UUID) -> Bool {
        enabledProfileIDs.contains(profileID)
    }

    /// Toggle enabled state for a profile
    func toggleEnabled(for profileID: UUID) {
        if enabledProfileIDs.contains(profileID) {
            enabledProfileIDs.remove(profileID)
        } else {
            enabledProfileIDs.insert(profileID)
        }
        saveEnabledProfiles()
    }

    /// Start all enabled tunnels (called on app launch)
    func startEnabledTunnels() async {
        Self.logger.info("Starting enabled tunnels (\(self.enabledProfileIDs.count) enabled)")

        let profileManager = ConnectionProfileManager.shared

        for profileID in enabledProfileIDs {
            guard let profile = profileManager.profile(for: profileID) else {
                Self.logger.warning("Enabled profile not found: \(profileID)")
                continue
            }

            guard profile.hasPortForwards else {
                Self.logger.warning("Enabled profile has no port forwards: \(profile.name)")
                continue
            }

            do {
                try await startTunnel(for: profile)
            } catch {
                Self.logger.error("Failed to start tunnel for \(profile.name): \(error.localizedDescription)")
            }
        }
    }

    /// Get statistics for a specific tunnel
    func statistics(for profileID: UUID) -> TunnelStatistics? {
        activeTunnels[profileID]?.statistics
    }

    /// Get tunnel state for a profile
    func tunnelState(for profileID: UUID) -> TunnelState? {
        activeTunnels[profileID]?.state
    }

    /// Get tunnel by profile ID
    func tunnel(for profileID: UUID) -> BackgroundTunnel? {
        activeTunnels[profileID]
    }

    /// Reconnect a specific tunnel
    func reconnectTunnel(for profileID: UUID) async {
        guard let tunnel = activeTunnels[profileID] else { return }
        await tunnel.reconnect()
    }

    // MARK: - Event History

    /// Get events for a specific profile
    func events(for profileID: UUID, limit: Int = 100) -> [TunnelEvent] {
        Array(eventHistory
            .filter { $0.tunnelID == profileID }
            .suffix(limit))
    }

    /// Clear events for a specific profile
    func clearEvents(for profileID: UUID) {
        eventHistory.removeAll { $0.tunnelID == profileID }
    }

    /// Clear all event history
    func clearAllEvents() {
        eventHistory.removeAll()
    }

    // MARK: - Private Methods

    /// Notify SessionTracker that the background tunnel count changed.
    /// Uses active count (connecting + connected + reconnecting) rather than
    /// just connected count, so Location Diary stays on during reconnection.
    private func notifyTunnelCountChanged() {
        var profileCounts: [UUID: Int] = [:]
        var totalActive = 0
        for (profileID, tunnel) in activeTunnels where tunnel.state.isActive {
            profileCounts[profileID] = 1
            totalActive += 1
        }
        Self.logger.info("Background tunnel count changed: \(totalActive)")
        NotificationCenter.default.post(
            name: .backgroundTunnelCountChanged,
            object: nil,
            userInfo: [
                "runningCount": totalActive,
                "profileCounts": profileCounts,
            ]
        )
    }

    private func handleEvent(_ event: TunnelEvent) {
        // Add to history
        eventHistory.append(event)

        // Cap history size
        if eventHistory.count > maxEventHistory {
            eventHistory = Array(eventHistory.suffix(maxEventHistory))
        }

        Self.logger.debug("Tunnel event: \(event.type.displayName) - \(event.message ?? "")")
    }

    private func loadEnabledProfiles() {
        if let data = UserDefaults.standard.data(forKey: enabledProfilesKey),
           let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            enabledProfileIDs = ids
            Self.logger.info("Loaded \(ids.count) enabled tunnel profiles")
        }
    }

    private func saveEnabledProfiles() {
        if let data = try? JSONEncoder().encode(enabledProfileIDs) {
            UserDefaults.standard.set(data, forKey: enabledProfilesKey)
        }
    }
}

// MARK: - Tunnel Errors

enum TunnelError: LocalizedError {
    case noPortForwardsConfigured
    case connectionFailed(String)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .noPortForwardsConfigured:
            return "No port forwards configured for this profile"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .alreadyRunning:
            return "Tunnel is already running"
        }
    }
}

// MARK: - ConnectionProfileManager Extension

extension ConnectionProfileManager {
    /// Get all profiles that can be used as tunnels (have port forwards)
    var tunnelCapableProfiles: [ConnectionProfile] {
        profiles.filter { $0.hasPortForwards && !$0.isDeleted }
    }
}
