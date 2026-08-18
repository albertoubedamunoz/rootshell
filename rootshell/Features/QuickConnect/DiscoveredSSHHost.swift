//
//  DiscoveredSSHHost.swift
//  rootshell
//
//  Model for mDNS-discovered hosts on the local network
//

import Foundation

/// The kind of service a discovered host advertises. Each Bonjour
/// service type maps to one kind (`_ssh._tcp` → ssh, `_rfb._tcp` → vnc).
enum DiscoveredServiceKind: String, Sendable, Hashable {
    case ssh
    case vnc
}

/// Represents a host discovered via mDNS advertising a supported service
/// (SSH via _ssh._tcp, Screen Sharing via _rfb._tcp)
struct DiscoveredSSHHost: Identifiable, Hashable, Sendable {
    /// Unique identifier for this discovered host
    let id: UUID

    /// Bonjour service name (e.g., "My MacBook Pro")
    let serviceName: String

    /// Resolved hostname (e.g., "my-macbook-pro.local")
    let hostname: String

    /// Service port (usually 22 for SSH, 5900 for VNC)
    let port: UInt16

    /// Which service this host advertises
    let kind: DiscoveredServiceKind

    /// When this host was discovered
    let discoveredAt: Date

    init(
        id: UUID = UUID(),
        serviceName: String,
        hostname: String,
        port: UInt16 = 22,
        kind: DiscoveredServiceKind = .ssh,
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.serviceName = serviceName
        self.hostname = hostname
        self.port = port
        self.kind = kind
        self.discoveredAt = discoveredAt
    }
}
