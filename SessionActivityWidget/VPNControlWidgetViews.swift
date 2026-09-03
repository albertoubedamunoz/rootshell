//
//  VPNControlWidgetViews.swift
//  SessionActivityWidget
//
//  SwiftUI views for the VPN Control Widget (small and medium families).
//

import SwiftUI
import WidgetKit

// MARK: - Status

/// Presentation attributes derived from the raw status string.
private struct VPNStatusStyle {
    let color: Color
    let symbol: String
    let title: String
    let isConnected: Bool
    let isTransitioning: Bool

    init(status: String) {
        switch status {
        case "connected":
            color = .green
            symbol = "checkmark.shield.fill"
            title = String(localized: "Connected")
            isConnected = true
            isTransitioning = false
        case "connecting":
            color = .yellow
            symbol = "shield.lefthalf.filled"
            title = String(localized: "Connecting")
            isConnected = false
            isTransitioning = true
        case "reconnecting":
            color = .yellow
            symbol = "shield.lefthalf.filled"
            title = String(localized: "Reconnecting")
            isConnected = false
            isTransitioning = true
        case "disconnecting":
            color = .orange
            symbol = "shield.lefthalf.filled"
            title = String(localized: "Disconnecting")
            isConnected = false
            isTransitioning = true
        default:
            color = .gray
            symbol = "shield.slash.fill"
            title = String(localized: "Disconnected")
            isConnected = false
            isTransitioning = false
        }
    }
}

// MARK: - Background

/// Neutral widget fill with a status-tinted wash from the top-leading corner.
struct VPNControlWidgetBackground: View {
    let status: String

    var body: some View {
        let style = VPNStatusStyle(status: status)
        ZStack {
            Rectangle().fill(.fill.tertiary)
            LinearGradient(
                colors: [style.color.opacity(0.28), style.color.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - View

struct VPNControlWidgetView: View {
    let entry: VPNControlTimelineEntry

    @Environment(\.widgetFamily) private var widgetFamily

    private var style: VPNStatusStyle { VPNStatusStyle(status: entry.status) }

    private var canConnect: Bool {
        entry.profileID != nil && entry.profileName != nil && entry.host != nil
    }

    /// "user@host" when both are known, otherwise whichever exists.
    private var endpoint: String? {
        guard let host = entry.host, !host.isEmpty else { return nil }
        if let user = entry.username, !user.isEmpty { return "\(user)@\(host)" }
        return host
    }

    var body: some View {
        if !entry.isConfigured {
            unconfiguredView
        } else {
            switch widgetFamily {
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
    }

    // MARK: Pieces

    private func glyph(size: CGFloat) -> some View {
        Image(systemName: style.symbol)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .widgetAccentable()
    }

    private func title(_ font: Font) -> some View {
        Text(entry.profileName ?? "VPN")
            .font(font)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var transportChip: some View {
        Group {
            if let transport = entry.transport {
                Text(transport)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(style.color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(style.color.opacity(0.35), lineWidth: 3))
    }

    /// Compact "● Connected 1:02:33" line for the small family.
    private var statusLine: some View {
        let titleColor: AnyShapeStyle = style.isConnected
            ? AnyShapeStyle(style.color)
            : AnyShapeStyle(HierarchicalShapeStyle.secondary)
        return Group {
            if style.isConnected, let since = entry.connectedSince {
                // Word + timer rarely both fit at small width; fall back to
                // the timer alone (the dot and tint still read as connected).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        statusDot
                        Text(style.title).foregroundStyle(titleColor)
                        Text(since, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        statusDot
                        Text(since, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(titleColor)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    statusDot
                    Text(style.title).foregroundStyle(titleColor)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }

    private func detail(_ label: LocalizedStringKey, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Unconfigured

    private var unconfiguredView: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
                .widgetAccentable()
            Text("VPN Control")
                .font(.headline)
            Text("Hold to choose a profile")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Small

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                glyph(size: 34)
                Spacer()
                transportChip
            }

            Spacer(minLength: 6)

            title(.headline)
            statusLine
                .padding(.top, 3)

            Spacer(minLength: 8)

            toggleButton(fullWidth: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private var mediumView: some View {
        HStack(alignment: .top, spacing: 16) {
            // Identity column
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    glyph(size: 40)
                    Spacer()
                    transportChip
                }

                Spacer(minLength: 8)

                title(.title3.weight(.bold))

                if let endpoint {
                    Text(endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status column
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    statusDot
                    Text(style.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(style.isConnected ? AnyShapeStyle(style.color) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                if style.isConnected, let since = entry.connectedSince {
                    Text(since, style: .timer)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.top, 2)
                } else if style.isTransitioning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(style.color)
                        .padding(.top, 8)
                } else if let host = entry.host {
                    detail("Server", host, mono: true)
                        .padding(.top, 8)
                }

                Spacer(minLength: 8)

                toggleButton(fullWidth: true)
            }
            .frame(width: 128, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Button

    @ViewBuilder
    private func toggleButton(fullWidth: Bool) -> some View {
        if style.isTransitioning, let profileID = entry.profileID {
            // Re-triggers the same intent, which polls for the final state.
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                buttonLabel(fullWidth: fullWidth, systemImage: nil, title: style.title + "…")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(style.color)
        } else if style.isConnected {
            Button(intent: DisconnectVPNWidgetIntent()) {
                buttonLabel(fullWidth: fullWidth, systemImage: "xmark", title: String(localized: "Disconnect"))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.red)
        } else if canConnect, let profileID = entry.profileID {
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                buttonLabel(fullWidth: fullWidth, systemImage: "bolt.fill", title: String(localized: "Connect"))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.green)
        }
    }

    private func buttonLabel(fullWidth: Bool, systemImage: String?, title: String) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .invalidatableContent()
        }
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .padding(.vertical, 3)
    }
}
