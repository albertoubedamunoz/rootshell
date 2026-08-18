//
//  QuickConnectSuggestion.swift
//  rootshell
//
//  Protocol for unified quick connect autocomplete suggestions
//

import Foundation

/// Source type for suggestions (for grouping/display)
enum SuggestionSourceType: String, CaseIterable {
    case profile = "Profiles"      // Highest priority
    case history = "History"
    case cloudInstance = "Cloud"
    case localNetwork = "Local Network"
}

/// Protocol for any item that can appear in quick connect autocomplete
protocol QuickConnectSuggestion: Identifiable, Hashable {
    /// Unique identifier for deduplication
    var id: UUID { get }

    /// The type of source this suggestion came from
    var sourceType: SuggestionSourceType { get }

    /// The string to display in the autocomplete dropdown (inline preview)
    /// For cloud instances, this is the VM label (e.g., "gpu1")
    /// For history, this is the connection string (e.g., "user@host")
    var displayString: String { get }

    /// The string to insert into the text field when Tab is pressed
    /// For cloud instances, this is "username@ip" (e.g., "root@192.168.1.1")
    /// For history, this matches displayString
    var completionString: String { get }

    /// Detailed description shown below the input field
    /// For cloud instances: "Linode: gpu1 (ID: 12345) - us-east - running - 192.168.1.1"
    var detailText: String? { get }

    /// Priority for sorting (lower = higher priority, within same sourceType)
    var sortPriority: Int { get }

    /// Match against user input
    func matches(_ searchText: String, mode: MatchingMode) -> Bool
}

// Default implementations
extension QuickConnectSuggestion {
    var detailText: String? { nil }
    var sortPriority: Int { 0 }
}
