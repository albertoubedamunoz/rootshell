//
//  AttachmentUploadBannerView.swift
//  rootshell
//
//  SwiftUI banner for attachment upload progress.
//  Follows MoshRoamBannerView pattern with liquid glass effect.
//

import SwiftUI

/// State for the upload progress banner
struct AttachmentUploadBannerState: Equatable {
    enum Phase: Equatable {
        case connecting
        case uploading(fileName: String, fileIndex: Int, totalFiles: Int, progress: Double)
        case completed(fileCount: Int)
        case failed(message: String)
    }

    let phase: Phase

    static func from(_ uploadState: AttachmentUploadState) -> AttachmentUploadBannerState? {
        switch uploadState {
        case .idle:
            return nil
        case .connecting:
            return AttachmentUploadBannerState(phase: .connecting)
        case .uploading(let name, let idx, let total, let progress):
            return AttachmentUploadBannerState(phase: .uploading(
                fileName: name, fileIndex: idx, totalFiles: total, progress: progress
            ))
        case .completed(let paths):
            return AttachmentUploadBannerState(phase: .completed(fileCount: paths.count))
        case .failed(let error):
            return AttachmentUploadBannerState(phase: .failed(message: error.localizedDescription))
        }
    }
}

/// Pill-shaped upload progress banner
struct AttachmentUploadBannerView: View {
    let state: AttachmentUploadBannerState
    var onCancel: (() -> Void)?

    private let maxWidth: CGFloat = 400

    var body: some View {
        HStack(spacing: 8) {
            icon
            content
            Spacer(minLength: 0)
            if showsCancelButton {
                cancelButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth)
        .bannerBackground()
    }

    // MARK: - Icon

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .connecting:
            Image(systemName: "arrow.up.circle")
                .symbolEffect(.pulse, isActive: true)
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        case .uploading:
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 14))
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .connecting:
            Text("Connecting for upload...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)

        case .uploading(let fileName, let fileIndex, let totalFiles, let progress):
            VStack(alignment: .leading, spacing: 3) {
                if totalFiles > 1 {
                    Text("Uploading \(fileIndex + 1)/\(totalFiles): \(fileName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("Uploading \(fileName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                // Progress bar
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.secondary.opacity(0.2))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.blue)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                }
                .frame(height: 4)

                Text(progress, format: .wholePercent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

        case .completed(let fileCount):
            if fileCount > 1 {
                Text("\(fileCount) files uploaded")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            } else {
                Text("Upload complete")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

        case .failed(let message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Cancel Button

    private var showsCancelButton: Bool {
        switch state.phase {
        case .connecting, .uploading: return true
        default: return false
        }
    }

    private var cancelButton: some View {
        Button {
            onCancel?()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
        .buttonStyle(.plain)
    }
}
