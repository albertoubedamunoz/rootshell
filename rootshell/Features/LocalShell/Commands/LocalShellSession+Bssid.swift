#if !targetEnvironment(macCatalyst)

import CoreLocation
import Foundation
import NetworkExtension
import UIKit

// MARK: - Location Auth Helper

/// Retains a CLLocationManager with delegate for the duration of a BSSID lookup.
/// NEHotspotNetwork.fetchCurrent requires an active CLLocationManager instance
/// with precise location authorization to return results (unless VPN is configured).
final class LocationAuthHelper: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Request authorization if not yet determined. Returns the resulting status.
    func requestAuthorizationIfNeeded() async -> CLAuthorizationStatus {
        guard manager.authorizationStatus == .notDetermined else {
            return manager.authorizationStatus
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            // The delegate fires once on assignment (before requestAuthorizationIfNeeded
            // is called), so continuation may be nil — that's fine, just ignore it.
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: manager.authorizationStatus)
            }
        }
    }
}

// MARK: - BSSID Command

extension LocalShellSession {
    /// Handle the bssid command
    func handleBssidCommand(_ command: String) {
        let args = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1)
            .dropFirst()
            .first
            .map(String.init)

        if args == "-h" || args == "--help" {
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displayBssidHelp()
            return
        }

        let verbose = args == "-v"

        Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false

            // Touch the network monitor early so it has time to receive its
            // initial NWPath update before we need connectionType for error
            // messaging.  Without this, the singleton may still report
            // .unknown when we reach the error path on first invocation.
            _ = NetworkReachabilityMonitor.shared

            // Helper must stay alive for the duration — CLLocationManager must be
            // retained when fetchCurrent is called.
            let helper = LocationAuthHelper()

            let status = await helper.requestAuthorizationIfNeeded()

            if status == .denied || status == .restricted {
                self.lastCommandSucceeded = false
                self.scriptCommandExitCode = 1
                self.onOutput?(self.normalizeLineEndings(
                    "bssid: location permission required for WiFi info\n" +
                    "       Grant location access in Settings > Privacy > Location Services\n"
                ))
                self.displayPrompt()
                return
            }

            let hasPrecise = helper.accuracyAuthorization == .fullAccuracy
            if !hasPrecise {
                self.lastCommandSucceeded = false
                self.scriptCommandExitCode = 1
                self.onOutput?(self.normalizeLineEndings(
                    "bssid: precise location required for WiFi info\n" +
                    "       Enable in Settings > Privacy > Location Services > Rootshell\n" +
                    "       Note: VPN users are not affected (VPN satisfies the requirement)\n"
                ))
                self.displayPrompt()
                return
            }

            if verbose {
                let statusName: String = switch status {
                case .authorizedWhenInUse: "authorizedWhenInUse"
                case .authorizedAlways: "authorizedAlways"
                case .denied: "denied"
                case .restricted: "restricted"
                case .notDetermined: "notDetermined"
                @unknown default: "unknown"
                }
                let accuracyName = hasPrecise ? "fullAccuracy" : "reducedAccuracy"
                let netType = NetworkReachabilityMonitor.shared.connectionType.description
                self.onOutput?(self.normalizeLineEndings(
                    "WiFi info debug:\n" +
                    "  Location auth:  \(statusName)\n" +
                    "  Precise loc:    \(accuracyName)\n" +
                    "  Network path:   \(netType)\n" +
                    "  Note: Precise location required unless VPN is configured\n\n"
                ))
            }

            let network = await withCheckedContinuation { (cont: CheckedContinuation<NEHotspotNetwork?, Never>) in
                NEHotspotNetwork.fetchCurrent { network in
                    cont.resume(returning: network)
                }
            }

            if let network {
                let normalizedBSSID = MACAddress.canonicalString(for: network.bssid) ?? network.bssid.uppercased()
                WiFiAPCacheManager.shared.refreshIfStale()
                let matchedAP = WiFiAPCacheManager.shared.findAccessPoint(forBSSID: normalizedBSSID)
                let vendor = OUILookup.resolveVendor(bssid: normalizedBSSID, matchedAP: matchedAP)

                var output = "SSID:   \(network.ssid)\n" +
                             "BSSID:  \(normalizedBSSID)\n"

                // Use manual AP's stored vendor name if available, else OUI lookup.
                // Key off the matched AP's MAC (the storage key), not the observed
                // BSSID, which may differ due to LA-bit or prefix/suffix matching.
                let displayVendorName: String
                if let apMAC = matchedAP?.mac,
                   matchedAP?.providerID == ManualAPManager.manualProviderID,
                   let manualVendor = ManualAPManager.shared.vendorName(forMAC: apMAC),
                   !manualVendor.isEmpty {
                    displayVendorName = manualVendor
                } else if let vendor {
                    displayVendorName = vendor.name
                } else {
                    displayVendorName = "Unknown"
                }
                output += "Vendor: \(displayVendorName)\n"

                self.onOutput?(self.normalizeLineEndings(output))

                if let matchedAP {
                    var apLine = "AP:     \(matchedAP.name)"
                    if let model = matchedAP.shortname ?? matchedAP.model {
                        apLine += " (\(model))"
                    }
                    if let siteName = matchedAP.siteName {
                        apLine += " @ \(siteName)"
                    }
                    apLine += "\n"
                    self.onOutput?(self.normalizeLineEndings(apLine))
                }

                // Band info from radio cache
                let radio = WiFiAPRadioCacheManager.shared.findRadio(forBSSID: normalizedBSSID)
                if let radio {
                    var bandLine = "Band:   \(radio.band.rawValue)"
                    if let standard = radio.standard {
                        bandLine += " (\(standard))"
                    }
                    bandLine += "\n"
                    self.onOutput?(self.normalizeLineEndings(bandLine))
                }

                // Determine favicon website: manual AP's custom domain takes priority.
                // Use the matched AP's MAC as the lookup key (same reason as above).
                let faviconWebsite: String?
                if let apMAC = matchedAP?.mac,
                   matchedAP?.providerID == ManualAPManager.manualProviderID,
                   let customDomain = ManualAPManager.shared.vendorDomain(forMAC: apMAC) {
                    faviconWebsite = "https://\(customDomain)"
                } else {
                    faviconWebsite = vendor?.website
                }

                // Emit vendor website with inline favicon if available
                if let website = faviconWebsite {
                    let domain = FaviconFetcher.extractDomain(from: website)
                    let pngData: Data? = if let domain {
                        await FaviconManager.shared.favicon(for: domain)
                    } else {
                        nil
                    }

                    // Emit indent, then inline favicon, then URL — all on one line
                    self.onOutput?("        ")
                    if let pngData {
                        let sink = self.onOutput
                        let outputSink: @Sendable (String) -> Void = { text in
                            sink?(text)
                        }
                        Self.emitKittyGraphics(pngData: pngData, cols: 2, rows: 1, output: outputSink)
                        self.onOutput?(" ")
                    }
                    self.onOutput?(self.normalizeLineEndings("\(website)\n"))
                }

                UIPasteboard.general.string = normalizedBSSID
                self.onOutput?(self.normalizeLineEndings("(copied to clipboard)\n"))
                succeeded = true
            } else {
                let connType = NetworkReachabilityMonitor.shared.connectionType
                if connType != .wifi && connType != .unknown {
                    self.onOutput?(self.normalizeLineEndings("bssid: not connected to WiFi\n"))
                } else {
                    self.onOutput?(self.normalizeLineEndings("bssid: unable to read WiFi info\n"))
                }
            }

            self.lastCommandSucceeded = succeeded
            self.scriptCommandExitCode = succeeded ? 0 : 1
            self.displayPrompt()
        }
    }

    /// Display bssid usage help
    func displayBssidHelp() {
        let helpText = """
usage: bssid [-v]

Display the BSSID (MAC address), SSID, and vendor of the currently connected
WiFi access point. The BSSID is normalized to a zero-padded format and copied
to the clipboard.

Vendor identification uses the IEEE OUI registry (39K entries) to map the
BSSID prefix to the manufacturer. Locally-administered/derived AP BSSIDs are
matched back to the base vendor when possible. Website URLs are shown for known
vendors.

If a WiFi AP provider account is configured (Settings > Connections > WiFi AP
Providers), the friendly AP name and model are shown by matching normalized and
derived BSSID forms against cached access point data. Manual AP associations
configured in Settings are also supported.

Requires location permission to access WiFi information. If no VPN profile
is configured, precise location must be enabled.

Options:
  -v    Show diagnostic info (location auth, accuracy, network type)

"""
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onOutput?(self.normalizeLineEndings(helpText))
            self.displayPrompt()
        }
    }
}

#endif
