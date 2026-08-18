//
//  PortForwardError.swift
//  rootshell
//
//  Error types for SSH port forwarding
//
//  Copyright (c) 2025 Kit Knox / Rootshell LLC
//

import Foundation

/// Errors for SSH port forwarding operations
enum PortForwardError: LocalizedError {
    /// Failed to bind to a local port
    case bindFailed(port: Int, underlying: Error)

    /// Failed to connect to the target through SSH
    case connectionFailed(target: String, underlying: Error)

    /// The SSH session was closed while forwarding was active
    case sessionClosed

    /// Remote server rejected the port forward request
    case remoteRejected(port: Int)

    /// Port is already in use by another forward
    case portInUse(port: Int)

    /// Invalid forward configuration
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .bindFailed(let port, let underlying):
            return "Failed to bind to port \(port): \(underlying.localizedDescription)"
        case .connectionFailed(let target, let underlying):
            return "Failed to connect to \(target): \(underlying.localizedDescription)"
        case .sessionClosed:
            return "SSH session closed"
        case .remoteRejected(let port):
            return "Remote server rejected port forward on port \(port)"
        case .portInUse(let port):
            return "Port \(port) is already in use"
        case .invalidConfiguration(let reason):
            return "Invalid port forward configuration: \(reason)"
        }
    }

    /// Whether this error is recoverable (user might retry)
    var isRecoverable: Bool {
        switch self {
        case .bindFailed, .connectionFailed, .remoteRejected:
            return true
        case .sessionClosed, .portInUse, .invalidConfiguration:
            return false
        }
    }
}

/// Status of a port forward
enum PortForwardStatus: Equatable, Sendable {
    /// Forward is configured but not yet started
    case pending

    /// Forward is active and working
    case active

    /// Forward failed with an error
    case failed(String)

    /// Forward was stopped
    case stopped

    static func == (lhs: PortForwardStatus, rhs: PortForwardStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.active, .active), (.stopped, .stopped):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}
