//
//  HistorySuggestion.swift
//  rootshell
//
//  Adapter that makes SSHConnectionHistoryEntry conform to QuickConnectSuggestion
//

import Foundation

/// Wrapper that makes SSHConnectionHistoryEntry conform to QuickConnectSuggestion
struct HistorySuggestion: QuickConnectSuggestion {
    let entry: SSHConnectionHistoryEntry

    var id: UUID { entry.id }
    var sourceType: SuggestionSourceType { .history }
    var displayString: String { entry.displayString }
    var completionString: String { entry.displayString }

    var detailText: String? {
        var parts: [String] = ["History"]
        if entry.connectionProtocol == .mosh || entry.connectionProtocol == .trzsz {
            parts.append("Roam")
        }
        if entry.hasJumpHost {
            parts.append("via jump host")
        }
        if entry.agentConfig?.enabled == true {
            parts.append("agent forwarding")
        }
        return parts.joined(separator: " | ")
    }

    var sortPriority: Int {
        // More recent = higher priority (lower number)
        // Convert to hours ago for reasonable int values
        Int(-entry.lastUsed.timeIntervalSince1970 / 3600)
    }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        entry.matches(searchText, mode: mode)
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistorySuggestion, rhs: HistorySuggestion) -> Bool {
        lhs.id == rhs.id
    }
}
