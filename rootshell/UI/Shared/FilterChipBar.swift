//
//  FilterChipBar.swift
//  rootshell
//
//  Horizontal scrolling bar of removable filter chips.
//

import SwiftUI

/// A horizontal scrolling bar of filter chips, each with an optional icon, label, and remove button.
/// Used by ProfilesBrowseSheet (tag chips) and SSHHostBrowseSheet (account chips).
struct FilterChipBar<Item: Identifiable, Icon: View>: View {
    let items: [Item]
    let label: (Item) -> String
    @ViewBuilder let icon: (Item) -> Icon
    let onRemove: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        icon(item)
                        Text(label(item))
                            .font(.caption)
                        Button(action: { onRemove(item) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(12)
                }
            }
        }
    }
}
