//
//  VPNControlWidgetViews.swift
//  SessionActivityWidget
//
//  SwiftUI views for the VPN Control Widget (small and medium families).
//

import SwiftUI
import WidgetKit

struct VPNControlWidgetView: View {
    let entry: VPNControlTimelineEntry

    @Environment(\.widgetFamily) var widgetFamily

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

    // MARK: - Status Helpers

    private var isConnected: Bool { entry.status == "connected" }
    private var isDisconnected: Bool { entry.status == "disconnected" || entry.status.isEmpty }
    private var isTransitioning: Bool {
        entry.status == "connecting" || entry.status == "reconnecting" || entry.status == "disconnecting"
    }

    private var statusColor: Color {
        switch entry.status {
        case "connected": return .green
        case "connecting", "reconnecting": return .yellow
        case "disconnecting": return .orange
        default: return Color(.systemGray)
        }
    }

    private var statusDisplayText: String {
        switch entry.status {
        case "connected": return String(localized: "Connected")
        case "connecting": return String(localized: "Connecting…")
        case "reconnecting": return String(localized: "Reconnecting…")
        case "disconnecting": return String(localized: "Disconnecting…")
        default: return String(localized: "Disconnected")
        }
    }

    private var smallTransitionIndicator: some View {
        ProgressView()
            .controlSize(.mini)
            .tint(.white.opacity(0.7))
            .scaleEffect(0.72)
            .frame(width: 12, height: 12)
    }

    private var mediumTransitionIndicator: some View {
        ProgressView()
            .controlSize(.mini)
            .tint(.white.opacity(0.7))
            .scaleEffect(0.78)
            .frame(width: 16, height: 16)
    }

    // MARK: - Status Orb

    private func statusOrb(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    colors: [statusColor.opacity(0.35), statusColor.opacity(0)],
                    center: .center,
                    startRadius: size * 0.15,
                    endRadius: size * 0.5
                ))
                .frame(width: size, height: size)
            Circle()
                .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: size * 0.55, height: size * 0.55)
            Circle()
                .fill(statusColor)
                .frame(width: size * 0.35, height: size * 0.35)
                .shadow(color: statusColor.opacity(0.6), radius: size * 0.12)
        }
    }

    // MARK: - Unconfigured

    private var unconfiguredView: some View {
        VStack(spacing: 6) {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("VPN Control")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text("Hold to select profile")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Small Widget

    private var smallView: some View {
        VStack(spacing: 0) {
            // Profile name header
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Text(entry.profileName ?? "VPN")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            // Center: status orb + status text
            statusOrb(size: 40)

            if isConnected, let since = entry.connectedSince {
                HStack(spacing: 4) {
                    Text(statusDisplayText)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Text(since, style: .timer)
                        .font(.caption.bold())
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
            } else {
                Text(statusDisplayText)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }

            Spacer(minLength: 2)

            // Full-width button
            smallToggleButton
        }
    }

    // MARK: - Medium Widget

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(entry.profileName ?? "VPN")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            // Content row: orb | info | button
            HStack(spacing: 10) {
                statusOrb(size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(statusDisplayText)
                            .font(.callout.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if isConnected, let since = entry.connectedSince {
                            Text(since, style: .timer)
                                .font(.caption.bold())
                                .monospacedDigit()
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                        }
                    }

                    if let host = entry.host {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                mediumToggleButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Small Toggle Button (full-width)

    @ViewBuilder
    private var smallToggleButton: some View {
        if isTransitioning, let profileID = entry.profileID {
            // Tappable: re-triggers the same intent which polls for final state
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                HStack(spacing: 4) {
                    smallTransitionIndicator
                    Text(statusDisplayText)
                        .font(.caption.bold())
                        .invalidatableContent()
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        } else if isConnected {
            Button(intent: DisconnectVPNWidgetIntent()) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle.fill")
                        .font(.callout)
                    Text("Disconnect")
                        .font(.callout.bold())
                        .invalidatableContent()
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        } else if let profileID = entry.profileID,
                  entry.profileName != nil,
                  entry.host != nil {
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                HStack(spacing: 5) {
                    Image(systemName: "power.circle.fill")
                        .font(.callout)
                    Text("Connect")
                        .font(.callout.bold())
                        .invalidatableContent()
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Medium Toggle Button (vertical icon + text)

    @ViewBuilder
    private var mediumToggleButton: some View {
        if isTransitioning, let profileID = entry.profileID {
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                VStack(spacing: 6) {
                    mediumTransitionIndicator
                    Text(statusDisplayText)
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .invalidatableContent()
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 88)
                .padding(.vertical, 14)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        } else if isConnected {
            Button(intent: DisconnectVPNWidgetIntent()) {
                VStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                    Text("Disconnect")
                        .font(.caption.bold())
                        .invalidatableContent()
                }
                .foregroundStyle(.white)
                .frame(width: 88)
                .padding(.vertical, 14)
                .background(Color.red.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        } else if let profileID = entry.profileID,
                  entry.profileName != nil,
                  entry.host != nil {
            Button(intent: ConnectVPNWidgetIntent(profileID: profileID.uuidString)) {
                VStack(spacing: 6) {
                    Image(systemName: "power.circle.fill")
                        .font(.title2)
                    Text("Connect")
                        .font(.caption.bold())
                        .invalidatableContent()
                }
                .foregroundStyle(.white)
                .frame(width: 88)
                .padding(.vertical, 14)
                .background(Color.green.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }
}
