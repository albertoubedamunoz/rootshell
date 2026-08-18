//
//  TunnelStatistics.swift
//  rootshell
//
//  Statistics tracking for background port forward tunnels
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

/// Statistics for a running background tunnel
struct TunnelStatistics: Codable, Sendable, Equatable {
    /// Profile ID this tunnel belongs to
    let tunnelID: UUID

    /// Total bytes received through all forwards
    var bytesIn: UInt64 = 0

    /// Total bytes sent through all forwards
    var bytesOut: UInt64 = 0

    /// Total number of forwarded connections (completed)
    var connectionCount: Int = 0

    /// When data last flowed through any forward
    var lastActivity: Date?

    /// When this tunnel started
    var startedAt: Date?

    /// Per-forward statistics
    var forwardStats: [UUID: ForwardStatistics] = [:]

    // MARK: - Per-Forward Statistics

    /// Statistics for an individual port forward
    struct ForwardStatistics: Codable, Sendable, Equatable {
        let forwardID: UUID

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        /// Currently active connections through this forward
        var activeConnections: Int = 0

        /// Total connections handled by this forward
        var totalConnections: Int = 0

        init(forwardID: UUID) {
            self.forwardID = forwardID
        }
    }

    // MARK: - Initialization

    init(tunnelID: UUID) {
        self.tunnelID = tunnelID
    }

    // MARK: - Computed Properties

    /// Total bytes transferred (in + out)
    var totalBytes: UInt64 {
        bytesIn + bytesOut
    }

    /// Human-readable total transfer amount
    var totalBytesFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .memory)
    }

    /// Human-readable bytes in
    var bytesInFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesIn), countStyle: .memory)
    }

    /// Human-readable bytes out
    var bytesOutFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesOut), countStyle: .memory)
    }

    /// Duration since tunnel started
    var uptime: TimeInterval? {
        guard let startedAt = startedAt else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Human-readable uptime
    var uptimeFormatted: String? {
        guard let uptime = uptime else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: uptime)
    }

    /// Total active connections across all forwards
    var totalActiveConnections: Int {
        forwardStats.values.reduce(0) { $0 + $1.activeConnections }
    }

    // MARK: - Mutation Methods

    /// Record bytes received on a specific forward
    mutating func recordBytesIn(_ bytes: Int, forwardID: UUID) {
        bytesIn += UInt64(bytes)
        lastActivity = Date()

        if forwardStats[forwardID] == nil {
            forwardStats[forwardID] = ForwardStatistics(forwardID: forwardID)
        }
        forwardStats[forwardID]?.bytesIn += UInt64(bytes)
    }

    /// Record bytes sent on a specific forward
    mutating func recordBytesOut(_ bytes: Int, forwardID: UUID) {
        bytesOut += UInt64(bytes)
        lastActivity = Date()

        if forwardStats[forwardID] == nil {
            forwardStats[forwardID] = ForwardStatistics(forwardID: forwardID)
        }
        forwardStats[forwardID]?.bytesOut += UInt64(bytes)
    }

    /// Record a new connection on a forward
    mutating func recordConnectionOpened(forwardID: UUID) {
        if forwardStats[forwardID] == nil {
            forwardStats[forwardID] = ForwardStatistics(forwardID: forwardID)
        }
        forwardStats[forwardID]?.activeConnections += 1
        forwardStats[forwardID]?.totalConnections += 1
    }

    /// Record a connection closed on a forward
    mutating func recordConnectionClosed(forwardID: UUID) {
        if forwardStats[forwardID] == nil {
            forwardStats[forwardID] = ForwardStatistics(forwardID: forwardID)
        }
        let currentActive = forwardStats[forwardID]?.activeConnections ?? 1
        forwardStats[forwardID]?.activeConnections = max(0, currentActive - 1)
        connectionCount += 1
    }

    /// Reset all statistics
    mutating func reset() {
        bytesIn = 0
        bytesOut = 0
        connectionCount = 0
        lastActivity = nil
        startedAt = nil
        forwardStats.removeAll()
    }

    /// Mark tunnel as started
    mutating func markStarted() {
        startedAt = Date()
    }
}
