//
//  CloudInstanceSuggestion.swift
//  rootshell
//
//  Adapter that makes CloudInstance conform to QuickConnectSuggestion
//

import Foundation

/// Wrapper that makes CloudInstance conform to QuickConnectSuggestion
struct CloudInstanceSuggestion: QuickConnectSuggestion {
    let instance: CloudInstance
    let providerDisplayName: String

    var id: UUID { instance.id }
    var sourceType: SuggestionSourceType { .cloudInstance }

    /// Show the VM label for inline preview
    var displayString: String {
        instance.label
    }

    /// Complete to user@ip format
    var completionString: String {
        guard let host = instance.sshHost else { return instance.label }
        return "\(instance.defaultSSHUsername)@\(host)"
    }

    /// Rich detail: "Linode: gpu1 (ID: 12345) - us-east - running - 192.168.1.1"
    var detailText: String? {
        var parts: [String] = ["\(providerDisplayName): \(instance.label)"]
        parts.append("(ID: \(instance.providerInstanceID))")
        if let region = instance.region {
            parts.append("- \(region)")
        }
        parts.append("- \(instance.status.displayName)")
        if let ip = instance.ipv4Address {
            parts.append("- \(ip)")
        }
        if instance.isNetworkDevice, let os = OSDisplay.name(for: instance.image) {
            parts.append("- \(os)")
        }
        return parts.joined(separator: " ")
    }

    var sortPriority: Int {
        // Running instances get priority
        instance.status == .running ? 0 : 100
    }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        let query = searchText.lowercased()

        switch mode {
        case .prefix:
            // Match against label, IP, hostname with prefix matching
            if instance.label.lowercased().hasPrefix(query) { return true }
            if instance.ipv4Address?.hasPrefix(query) == true { return true }
            if instance.hostname?.lowercased().hasPrefix(query) == true { return true }
            // Also check tags with prefix matching
            if instance.tags.contains(where: { $0.lowercased().hasPrefix(query) }) { return true }
            return false

        case .substring:
            // Use the existing CloudInstance.matches(query:) for substring search
            return instance.matches(query: searchText)
        }
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CloudInstanceSuggestion, rhs: CloudInstanceSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}
