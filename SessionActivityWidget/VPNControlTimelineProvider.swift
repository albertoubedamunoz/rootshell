//
//  VPNControlTimelineProvider.swift
//  SessionActivityWidget
//
//  Timeline provider for the VPN Control Widget. Reads VPNWidgetState
//  from the app group to determine current VPN status.
//

import WidgetKit

struct VPNControlTimelineEntry: TimelineEntry {
    let date: Date
    let profileID: UUID?
    let profileName: String?
    let status: String          // "disconnected", "connecting", "connected", "disconnecting", "reconnecting"
    let host: String?
    let connectedSince: Date?
    let isConfigured: Bool      // Whether user has selected a profile in widget config
}

/// Timeline provider that reads VPN state exclusively from the shared app group file.
///
/// The widget extension does NOT have the NetworkExtension entitlement, so
/// NETunnelProviderManager.loadAllFromPreferences() returns empty here.
/// All status information comes from VPNWidgetState written by the main app,
/// VPN tunnel extension, and widget intents.
struct VPNControlTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = VPNControlTimelineEntry
    typealias Intent = VPNProfileSelectionIntent

    func placeholder(in context: Context) -> VPNControlTimelineEntry {
        VPNControlTimelineEntry(
            date: Date(),
            profileID: nil,
            profileName: "VPN",
            status: "disconnected",
            host: nil,
            connectedSince: nil,
            isConfigured: true
        )
    }

    func snapshot(for configuration: VPNProfileSelectionIntent, in context: Context) async -> VPNControlTimelineEntry {
        buildEntry(for: configuration)
    }

    func timeline(for configuration: VPNProfileSelectionIntent, in context: Context) async -> Timeline<VPNControlTimelineEntry> {
        let entry = buildEntry(for: configuration)

        switch entry.status {
        case "connecting", "reconnecting", "disconnecting":
            // Transitioning: the AppIntent polls inline and writes the final
            // state before returning, so the NEXT timeline rebuild (triggered
            // by the intent completing) should show the final state.
            // This .atEnd timeline is a safety net for edge cases where the
            // inline poll times out (slow connections). The transitioning
            // button in the widget also triggers a budget-free intent tap.
            let offsets: [TimeInterval] = [0, 3, 6, 10, 15]
            let entries = offsets.map { offset in
                VPNControlTimelineEntry(
                    date: Date().addingTimeInterval(offset),
                    profileID: entry.profileID,
                    profileName: entry.profileName,
                    status: entry.status,
                    host: entry.host,
                    connectedSince: entry.connectedSince,
                    isConfigured: entry.isConfigured
                )
            }
            return Timeline(entries: entries, policy: .atEnd)
        case "connected":
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(5 * 60)))
        default:
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        }
    }

    private func buildEntry(for configuration: VPNProfileSelectionIntent) -> VPNControlTimelineEntry {
        let configuredProfileID = configuration.profile?.id
        let isConfigured = configuredProfileID != nil

        let widgetState = VPNWidgetState.read()

        let effectiveStatus: String
        let effectiveHost: String?
        let effectiveConnectedSince: Date?

        if configuredProfileID != nil,
           widgetState?.profileID == configuredProfileID,
           let state = widgetState {
            effectiveStatus = resolvedStatus(from: state)
            effectiveHost = state.host ?? configuration.profile?.host
            effectiveConnectedSince = (effectiveStatus == "connected") ? state.connectedSince : nil
        } else {
            effectiveStatus = "disconnected"
            effectiveHost = configuration.profile?.host
            effectiveConnectedSince = nil
        }

        return VPNControlTimelineEntry(
            date: Date(),
            profileID: configuredProfileID,
            profileName: configuration.profile?.name,
            status: effectiveStatus,
            host: effectiveHost,
            connectedSince: effectiveConnectedSince,
            isConfigured: isConfigured
        )
    }

    /// Derive the widget display status from the shared state file.
    /// The file is the sole source of truth since the widget extension
    /// cannot access NetworkExtension APIs.
    private func resolvedStatus(from state: VPNWidgetState) -> String {
        let age = Date().timeIntervalSince(state.lastUpdated)

        switch state.status {
        case "connected":
            // Trust "connected" if recent; treat as stale after 10 minutes
            // (extension or app should refresh it via stats polling).
            return age < 600 ? "connected" : "disconnected"
        case "connecting", "reconnecting":
            // The intent polls for up to 5s and writes the final state.
            // If still "connecting" after 30s, assume it failed.
            return age < 30 ? state.status : "disconnected"
        case "disconnecting":
            // The intent polls for up to 3s and writes "disconnected".
            // If still "disconnecting" after 10s, assume it completed.
            return age < 10 ? "disconnecting" : "disconnected"
        default:
            return state.status
        }
    }
}
