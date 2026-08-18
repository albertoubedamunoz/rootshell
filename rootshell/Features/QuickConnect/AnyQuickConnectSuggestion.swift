//
//  AnyQuickConnectSuggestion.swift
//  rootshell
//
//  Type-erased wrapper for QuickConnectSuggestion (needed for SwiftUI arrays)
//

import Foundation

/// Type-erased wrapper for QuickConnectSuggestion
struct AnyQuickConnectSuggestion: QuickConnectSuggestion {
    private let _id: UUID
    private let _sourceType: SuggestionSourceType
    private let _displayString: String
    private let _completionString: String
    private let _detailText: String?
    private let _sortPriority: Int
    private let _matches: (String, MatchingMode) -> Bool

    init<S: QuickConnectSuggestion>(_ suggestion: S) {
        _id = suggestion.id
        _sourceType = suggestion.sourceType
        _displayString = suggestion.displayString
        _completionString = suggestion.completionString
        _detailText = suggestion.detailText
        _sortPriority = suggestion.sortPriority

        // Capture the matches function
        _matches = { searchText, mode in
            suggestion.matches(searchText, mode: mode)
        }
    }

    var id: UUID { _id }
    var sourceType: SuggestionSourceType { _sourceType }
    var displayString: String { _displayString }
    var completionString: String { _completionString }
    var detailText: String? { _detailText }
    var sortPriority: Int { _sortPriority }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        _matches(searchText, mode)
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(_id)
    }

    static func == (lhs: AnyQuickConnectSuggestion, rhs: AnyQuickConnectSuggestion) -> Bool {
        lhs._id == rhs._id
    }
}
