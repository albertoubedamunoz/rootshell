//
//  SuggestionDetailView.swift
//  rootshell
//
//  Shows detailed information about the currently matched suggestion
//

import SwiftUI

/// Shows detailed information about the currently matched cloud instance or history entry
/// When no detail is available, shows a "Browse Hosts" button if onBrowse is provided
struct SuggestionDetailView: View {
    let detailText: String?
    let isRefreshing: Bool
    var onBrowse: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Refreshing cloud instances...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let detail = detailText {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let browseAction = onBrowse {
                Button(action: browseAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.caption)
                        Text("Browse Hosts")
                            .font(.caption)
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: 20)
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: detailText)
        .animation(.easeInOut(duration: 0.2), value: isRefreshing)
    }
}

#Preview {
    VStack(spacing: 20) {
        SuggestionDetailView(
            detailText: "Linode: gpu1 (ID: 12345) - us-east - Running - 192.168.1.1",
            isRefreshing: false
        )

        SuggestionDetailView(
            detailText: nil,
            isRefreshing: true
        )

        SuggestionDetailView(
            detailText: "History | via jump host",
            isRefreshing: false
        )
    }
    .padding()
}
