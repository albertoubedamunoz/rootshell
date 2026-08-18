//
//  VPNControlWidget.swift
//  SessionActivityWidget
//
//  Home Screen widget for VPN start/stop controls with profile selection.
//

import SwiftUI
import WidgetKit

struct VPNControlWidget: Widget {
    let kind = "VPNControlWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VPNProfileSelectionIntent.self,
            provider: VPNControlTimelineProvider()
        ) { entry in
            VPNControlWidgetView(entry: entry)
                .environment(\.colorScheme, .dark)
                .containerBackground(for: .widget) {
                    statusGradient(for: entry.status)
                }
                .widgetURL(URL(string: "rootshell://vpn/settings"))
        }
        .configurationDisplayName("VPN Control")
        .description("Start and stop your VPN connection.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    private func statusGradient(for status: String) -> some View {
        let colors: [Color] = switch status {
        case "connected":
            [Color(red: 0.04, green: 0.16, blue: 0.06), Color(red: 0.02, green: 0.10, blue: 0.04)]
        case "connecting", "reconnecting":
            [Color(red: 0.18, green: 0.15, blue: 0.02), Color(red: 0.12, green: 0.09, blue: 0.01)]
        case "disconnecting":
            [Color(red: 0.18, green: 0.09, blue: 0.02), Color(red: 0.12, green: 0.06, blue: 0.01)]
        default:
            [Color(red: 0.10, green: 0.10, blue: 0.12), Color(red: 0.07, green: 0.07, blue: 0.09)]
        }
        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
