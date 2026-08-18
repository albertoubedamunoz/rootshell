//
//  SOCKSPortRegistry.swift
//  rootshell
//
//  Multi-tab port coordination for SOCKS5 dynamic port forwards.
//  Prevents multiple tabs from binding the same SOCKS port.
//

import Foundation

/// Singleton registry coordinating SOCKS5 ports across tabs/sessions.
/// When a second tab tries to bind a port already claimed by another session,
/// the registry returns false and the forward should report as handled elsewhere
/// rather than failing with an error.
@MainActor
final class SOCKSPortRegistry {
    static let shared = SOCKSPortRegistry()

    /// Maps bound port -> forward UUID that owns it
    private var boundPorts: [Int: UUID] = [:]

    private init() {}

    /// Claim a port for a forward. Returns true if claimed successfully.
    /// Returns false if the port is already claimed by a different forward.
    func claim(port: Int, forwardID: UUID) -> Bool {
        if let existing = boundPorts[port] {
            return existing == forwardID // Already claimed by same forward
        }
        boundPorts[port] = forwardID
        return true
    }

    /// Release a port previously claimed by a forward.
    func release(port: Int, forwardID: UUID) {
        if boundPorts[port] == forwardID {
            boundPorts.removeValue(forKey: port)
        }
    }

    /// Release all ports claimed by a given forward.
    func releaseAll(forwardID: UUID) {
        boundPorts = boundPorts.filter { $0.value != forwardID }
    }

    /// Check if a port is claimed by any forward.
    func isClaimed(port: Int) -> Bool {
        boundPorts[port] != nil
    }
}
