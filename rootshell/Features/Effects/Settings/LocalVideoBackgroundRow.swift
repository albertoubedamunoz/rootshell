//
//  LocalVideoBackgroundRow.swift
//  rootshell
//
//  Row for a user-imported video background in Settings.
//

import SwiftUI

struct LocalVideoBackgroundRow: View {
    let video: LocalVideoBackground
    let isActive: Bool
    let onSelect: () -> Void

    @ObservedObject private var manager = LocalVideoBackgroundManager.shared
    @State private var showingRename = false
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 12) {
            LocalVideoThumbnailView(videoId: video.id)
                .frame(width: 60, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(video.displayName)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(metadataLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            actionView
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .alert("Rename Video", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                manager.rename(id: video.id, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if video.duration > 0 {
            parts.append(formatDuration(video.duration))
        }
        if video.fileSize > 0 {
            parts.append(formatBytes(video.fileSize))
        }
        parts.append(video.seamlessLoop ? "Seamless" : "Crossfade")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionView: some View {
        HStack(spacing: 8) {
            if isActive {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.blue)
            }
            Menu {
                if !isActive {
                    Button {
                        onSelect()
                    } label: {
                        Label("Use This Video", systemImage: "checkmark.circle")
                    }
                }
                Button {
                    renameText = video.displayName
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    manager.setLoopingMode(
                        id: video.id,
                        seamless: !video.seamlessLoop,
                        crossfadeDuration: video.crossfadeDuration
                    )
                } label: {
                    Label(
                        video.seamlessLoop ? "Use Crossfade Loop" : "Use Seamless Loop",
                        systemImage: "repeat"
                    )
                }
                Button(role: .destructive) {
                    manager.delete(id: video.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct LocalVideoThumbnailView: View {
    let videoId: String
    @ObservedObject private var manager = LocalVideoBackgroundManager.shared

    var body: some View {
        Group {
            if let image = manager.thumbnail(for: videoId) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "film")
                            .foregroundColor(.secondary)
                    }
            }
        }
    }
}
