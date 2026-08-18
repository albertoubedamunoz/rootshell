//
//  LocalNetworkSuggestion.swift
//  rootshell
//
//  Adapter that makes DiscoveredSSHHost conform to QuickConnectSuggestion
//

import Foundation

/// Wrapper that makes DiscoveredSSHHost conform to QuickConnectSuggestion
struct LocalNetworkSuggestion: QuickConnectSuggestion {
    let host: DiscoveredSSHHost

    /// Optional matching history entry for username lookup
    let matchedHistoryEntry: SSHConnectionHistoryEntry?

    var id: UUID { host.id }
    var sourceType: SuggestionSourceType { .localNetwork }

    /// Show the Bonjour service name for inline preview
    var displayString: String {
        host.serviceName
    }

    /// Complete to a vnc:// URL for Screen Sharing hosts, user@host if we
    /// have history, otherwise just the hostname
    var completionString: String {
        if host.kind == .vnc {
            return "vnc://\(host.hostname)"
        }
        if let entry = matchedHistoryEntry {
            return "\(entry.username)@\(host.hostname)"
        }
        return host.hostname
    }

    /// Detail text showing local network context
    var detailText: String? {
        var parts: [String] = ["Local Network"]

        if host.kind == .vnc {
            parts.append("Screen Sharing")
        }

        if let entry = matchedHistoryEntry {
            parts.append("\(entry.username)@\(host.hostname)")
        } else {
            parts.append(host.hostname)
        }

        let defaultPort: UInt16 = host.kind == .vnc ? 5900 : 22
        if host.port != defaultPort {
            parts.append("port \(host.port)")
        }

        return parts.joined(separator: ": ")
    }

    var sortPriority: Int {
        // Hosts with matching history get higher priority
        matchedHistoryEntry != nil ? 0 : 50
    }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        let query = searchText.lowercased()

        switch mode {
        case .prefix:
            // Match against service name or hostname with prefix matching
            if host.serviceName.lowercased().hasPrefix(query) { return true }
            if host.hostname.lowercased().hasPrefix(query) { return true }
            // Also match username@host if we have history
            if let entry = matchedHistoryEntry {
                let full = "\(entry.username)@\(host.hostname)".lowercased()
                if full.hasPrefix(query) { return true }
            }
            return false

        case .substring:
            // Substring match anywhere in service name, hostname, or full connection string
            if host.serviceName.lowercased().contains(query) { return true }
            if host.hostname.lowercased().contains(query) { return true }
            if let entry = matchedHistoryEntry {
                let full = "\(entry.username)@\(host.hostname)".lowercased()
                if full.contains(query) { return true }
            }
            return false
        }
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LocalNetworkSuggestion, rhs: LocalNetworkSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}
