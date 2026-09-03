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
                .containerBackground(for: .widget) {
                    VPNControlWidgetBackground(status: entry.status)
                }
                .widgetURL(URL(string: "rootshell://vpn/settings"))
        }
        .configurationDisplayName("VPN Control")
        .description("Start and stop your VPN connection.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
