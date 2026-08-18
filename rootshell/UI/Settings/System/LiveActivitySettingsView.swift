//
//  LiveActivitySettingsView.swift
//  rootshell
//
//  Settings view for Live Activity configuration
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import SwiftUI

struct LiveActivitySettingsView: View {
    var liveActivityManager = LiveActivityManager.shared
    @ObservedObject var wifiInfoService = WiFiInfoService.shared

    private func sessionFilterDescription(for filter: LiveActivitySessionFilter) -> String {
        switch filter {
        case .all:
            return String(localized: "Shows all sessions including Roam and local tasks on the Lock Screen", comment: "Live Activity filter description: all sessions")
        case .diary:
            return String(localized: "Shows SSH, K8s, Console, and local tasks on the Lock Screen", comment: "Live Activity filter description: diary sessions")
        case .vpnOnly:
            return String(localized: "Shows only VPN data on the Lock Screen, no session info", comment: "Live Activity filter description: VPN only")
        case .infoOnly:
            return String(localized: "Keeps the activity always on so you can track WiFi and network info without a terminal session", comment: "Live Activity filter description: info only")
        }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Bindable(liveActivityManager).isEnabled) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "record.circle")
                        Text("Live Activity")
                    }
                }
                .themedRow()
            }

            if liveActivityManager.isEnabled {
                Section {
                    Picker(selection: Bindable(liveActivityManager).sessionFilter) {
                        ForEach(LiveActivitySessionFilter.allCases, id: \.self) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "line.3.horizontal.decrease.circle")
                            Text("Session Filter")
                        }
                    }
                    .themedRow()
                } footer: {
                    Text(sessionFilterDescription(for: liveActivityManager.sessionFilter))
                }

                Section {
                    Toggle(isOn: Bindable(liveActivityManager).isWiFiInfoEnabled) {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "wifi")
                            VStack(alignment: .leading) {
                                Text("WiFi Info")
                                Text("Show SSID and access point on Lock Screen")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .themedRow()
                    .onChange(of: liveActivityManager.isWiFiInfoEnabled) { _, enabled in
                        if enabled {
                            if !wifiInfoService.shouldShowWiFiInfo && wifiInfoService.canRequestPermission {
                                Task { await wifiInfoService.requestPermissionAndFetch() }
                            }
                        }
                    }

                    if liveActivityManager.isWiFiInfoEnabled && !wifiInfoService.shouldShowWiFiInfo
                        && !wifiInfoService.canRequestPermission {
                        Text("WiFi info requires location permission. Enable in Settings > Privacy > Location Services.")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .themedRow()
                    }

                    Toggle(isOn: Bindable(liveActivityManager).isNetworkInfoEnabled) {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "network")
                            VStack(alignment: .leading) {
                                Text("Network Info")
                                Text("Show public IP and ISP on Lock Screen")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .themedRow()
                } footer: {
                    if liveActivityManager.sessionFilter == .infoOnly
                        && !liveActivityManager.isWiFiInfoEnabled
                        && !liveActivityManager.isNetworkInfoEnabled {
                        Text("Info Only mode requires at least WiFi Info or Network Info to be enabled.")
                            .foregroundColor(.orange)
                    } else if !LocationDiaryManager.shared.isTrackingActive
                        && (liveActivityManager.isWiFiInfoEnabled || liveActivityManager.isNetworkInfoEnabled) {
                        Text("Background updates require Location Diary to be active. Without it, data only refreshes while the app is in the foreground.")
                            .foregroundColor(.orange)
                    }
                }

                if liveActivityManager.isActivityActive {
                    Section {
                        let count = liveActivityManager.displayedSessionCount
                        Text("Showing \(count) active session\(count == 1 ? "" : "s") on Lock Screen")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
