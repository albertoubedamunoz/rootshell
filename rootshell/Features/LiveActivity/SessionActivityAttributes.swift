//
//  SessionActivityAttributes.swift
//  rootshell
//
//  ActivityAttributes model for the Live Activity showing active non-resilient sessions.
//  Shared between the main app and the SessionActivityWidget extension.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

struct SessionActivityAttributes: ActivityAttributes {
    /// Static context — empty since all data is dynamic
    struct ContentState: Codable, Hashable {
        /// Total non-resilient session count
        var sessionCount: Int

        /// Per-type breakdown
        var sshCount: Int
        var k8sCount: Int
        var consoleCount: Int

        /// Host names for display (up to 3)
        var hostNames: [String]

        /// Local shells with active long-running tasks (vim, helix, sftp, etc.)
        var localTaskCount: Int = 0

        /// Roam sessions (Mosh, trzsz) — resilient UDP connections
        var roamCount: Int = 0

        /// Host names for roam sessions (up to 3)
        var roamHostNames: [String] = []

        /// Timestamp for elapsed timer display
        var lastUpdated: Date

        // MARK: - VPN State (nil = no VPN active)

        var vpnProfileName: String?
        var vpnHost: String?
        var vpnBytesIn: Int64?
        var vpnBytesOut: Int64?
        var vpnActiveConnections: Int?
        var vpnConnectedSince: Date?
        var vpnStatus: String?  // "connected", "connecting", "reconnecting"

        // MARK: - WiFi State (nil = disabled or unavailable)

        var wifiSSID: String?
        var wifiAPName: String?         // matched AP name or vendor name
        var wifiAPDetail: String?       // AP model shortname or site name
        var wifiBand: String?           // "6 GHz", "5 GHz", "2.4 GHz"

        // MARK: - Network/ISP State (nil = disabled or unavailable)

        var networkPublicIP: String?    // primary public IPv4
        var networkASName: String?      // ISP/AS org name (e.g. "Comcast Cable")
        var networkCountryFlag: String? // "US 🇺🇸"
        var networkType: String?        // "WiFi", "Cellular", etc.

        // MARK: - App Icon

        /// User-selected app icon variant (raw value of `AppIconVariant`).
        /// Empty string = primary icon. Default preserves source compatibility
        /// with existing call sites that don't set this field.
        var appIconVariant: String = ""

        /// Asset name for the widget's composed display PNG matching
        /// `appIconVariant`. Mirrors `AppIconManager.AppIconVariant.previewAssetName`.
        /// The widget's asset catalog carries copies of these imagesets so
        /// the widget doesn't depend on the main-app bundle.
        var appIconDisplayAssetName: String {
            switch appIconVariant {
            case "AppIconBlack":         return "AppIconBlackPreview"
            case "AppIconCRT":           return "AppIconCRTPreview"
            case "AppIconNoBorder":      return "AppIconNoBorderPreview"
            case "AppIconUnderscore":    return "AppIconUnderscorePreview"
            case "AppIconSixColors":     return "AppIconSixColorsPreview"
            case "AppIconSixColorsDark": return "AppIconSixColorsDarkPreview"
            case "AppIconOrig":          return "AppIconOrigPreview"
            case "AppIconRadicalSolarizedDark",
                 "AppIconRadicalSolarizedLight",
                 "AppIconRadicalDracula",
                 "AppIconRadicalNord",
                 "AppIconRadicalGruvboxDark",
                 "AppIconRadicalTokyoNight",
                 "AppIconRadicalCatppuccin",
                 "AppIconRadicalBases",
                 "AppIconRadicalMonoLight",
                 "AppIconRadicalMonokai",
                 "AppIconRadicalMonoDark",
                 "AppIconRadicalRosePine":
                return appIconVariant
            default:                     return "AppIconPreview"
            }
        }
    }
}
#endif
