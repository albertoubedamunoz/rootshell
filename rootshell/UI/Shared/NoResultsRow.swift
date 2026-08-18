//
//  NoResultsRow.swift
//  rootshell
//
//  Simple empty-state row for browse sheets.
//

import SwiftUI

/// A row showing an icon and message when no results match a search.
struct NoResultsRow: View {
    var icon: String = "magnifyingglass"
    var message: LocalizedStringKey

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
        }
    }
}
