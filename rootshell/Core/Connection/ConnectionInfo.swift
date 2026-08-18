//
//  ConnectionInfo.swift
//  rootshell
//
//  Unified connection info enum for the Connection Info sheet
//

import Foundation

/// Unified connection information across all session types
enum ConnectionInfo: Identifiable, Sendable {
    case local(shell: String, workingDirectory: String?, connectedAt: Date)
    case ssh(SSHConnectionInfo)
    case kubernetes(cluster: String, node: String, connectedAt: Date)
    case console(provider: String, instance: String, connectedAt: Date)
    case mosh(SSHConnectionInfo)
    case trzsz(SSHConnectionInfo, transportMode: String? = nil, transportRef: TSSHTransportRef? = nil)
    case vnc(VNCConnectionInfo)

    var id: String {
        switch self {
        case .local: return "local"
        case .ssh(let info): return "ssh-\(info.host)-\(info.port)"
        case .kubernetes(let cluster, let node, _): return "k8s-\(cluster)-\(node)"
        case .console(let provider, let instance, _): return "console-\(provider)-\(instance)"
        case .mosh(let info): return "mosh-\(info.host)-\(info.port)"
        case .trzsz(let info, _, _): return "trzsz-\(info.host)-\(info.port)"
        case .vnc(let info): return "vnc-\(info.host)-\(info.port)"
        }
    }

    /// Display name for the connection type
    var typeName: String {
        switch self {
        case .local: return "Local Shell"
        case .ssh: return "SSH"
        case .kubernetes: return "Kubernetes"
        case .console: return "Console"
        case .mosh: return "Mosh"
        case .trzsz: return "Trzsz"
        case .vnc: return "VNC"
        }
    }

    /// The connection start time
    var connectedAt: Date {
        switch self {
        case .local(_, _, let date): return date
        case .ssh(let info): return info.connectedAt
        case .kubernetes(_, _, let date): return date
        case .console(_, _, let date): return date
        case .mosh(let info): return info.connectedAt
        case .trzsz(let info, _, _): return info.connectedAt
        case .vnc(let info): return info.connectedAt
        }
    }
}
