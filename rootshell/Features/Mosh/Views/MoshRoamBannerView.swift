//
//  MoshRoamBannerView.swift
//  rootshell
//
//  SwiftUI view for Mosh roam banner overlay with liquid glass effect
//

import SwiftUI

/// Modern pill-shaped Mosh roam banner overlay
///
/// Features:
/// - Rounded rectangle that adapts to content size
/// - Liquid glass effect on iOS 26+ / macOS 26+
/// - System colors that adapt to light/dark mode
/// - "R" badge to indicate roaming state
/// - Hole-punch activity indicator
/// - Graceful text wrapping for long messages
struct MoshRoamBannerView: View {
    let state: MoshRoamBannerState
    var rebuildJumpConnection: (() -> Void)? = nil

    /// Maximum width for the banner (leaves margin on sides)
    private let maxWidth: CGFloat = 400

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // "R" badge for roam indicator (stays at top when text wraps)
            Text("R")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Message and hole-punch indicator in a flexible layout
            VStack(alignment: .leading, spacing: 4) {
                // Message text - allows wrapping
                Text(state.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let rebuildJumpConnection {
                    Button("Rebuild Jump Connection", action: rebuildJumpConnection)
                        .font(.system(size: 12))
                }

                // Hole-punch indicator on its own line if present
                if state.holePunchInProgress {
                    HStack(spacing: 4) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .symbolEffect(.pulse, isActive: true)
                            .scaleEffect(0.6)
                            #if os(visionOS)
                            .foregroundStyle(.primary)
                            #else
                            .foregroundStyle(.secondary)
                            #endif

                        Text("Punching...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: maxWidth)
        .bannerBackground()
    }
}

// MARK: - Banner Background Extension

extension View {
    /// Applies appropriate background based on platform and OS version
    ///
    /// - iOS 26+/macOS 26+: Uses liquid glass effect via `.glassEffect()`
    /// - Earlier versions: Uses `.ultraThinMaterial` as fallback
    /// - visionOS: Uses `.regularMaterial` for proper volumetric appearance
    @ViewBuilder
    func bannerBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        #if os(visionOS)
        self
            .background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self
                .glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        #endif
    }
}
