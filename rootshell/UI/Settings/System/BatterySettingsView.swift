//
//  BatterySettingsView.swift
//  rootshell
//
//  Settings view for the refresh-rate cap, the power-source-adaptive cap,
//  and the automatic battery saver.
//

import SwiftUI

struct BatterySettingsView: View {
    @Bindable private var powerManager = PowerManager.shared

    var body: some View {
        List {
            Section {
                Picker(selection: $powerManager.maxRefreshRate) {
                    ForEach(PowerManager.RefreshRateSetting.allCases, id: \.self) { setting in
                        Text(setting.displayName).tag(setting)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "gauge.with.dots.needle.67percent")
                        Text("Maximum Refresh Rate")
                    }
                    .settingRow(Settings.Power.maxRefreshRate)
                }
                .themedRow()

                if powerManager.maxRefreshRate == .adaptive {
                    Picker(selection: $powerManager.batteryRefreshRate) {
                        ForEach(PowerManager.BatteryRefreshRate.allCases, id: \.self) { setting in
                            Text(setting.displayName).tag(setting)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "battery.50percent")
                            Text("On Battery")
                        }
                        .settingRow(Settings.Power.batteryRefreshRate)
                    }
                    .themedRow()
                }
            } footer: {
                Text("Caps how fast the terminal redraws. Auto uses the display's full rate (up to 120 Hz on ProMotion). Lower rates use less battery during scrolling and heavy output. Adaptive uses the full rate on wall power and the On Battery cap when unplugged.")
            }

            Section {
                SettingToggle(
                    Settings.Power.autoSaver,
                    isOn: $powerManager.autoSaverEnabled,
                    title: "Automatic Battery Saver",
                    icon: "battery.25percent"
                )
                .themedRow()
            } footer: {
                Text("Reduces refresh rate and animation frame rates when Low Power Mode is on or the device is warm.")
            }

            Section("Status") {
                LabeledContent("Current Mode", value: powerManager.tier.displayName)
                    .themedRow()
                LabeledContent(
                    "Power Source",
                    value: powerManager.onExternalPower
                        ? String(localized: "Wall Power", comment: "Device is running on external power")
                        : String(localized: "Battery", comment: "Device is running on battery power")
                )
                .themedRow()
                if powerManager.lowPowerModeActive {
                    LabeledContent("Low Power Mode", value: String(localized: "On"))
                        .themedRow()
                }
                if powerManager.thermalThrottleActive {
                    LabeledContent("Thermal State", value: String(localized: "Elevated"))
                        .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Battery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
