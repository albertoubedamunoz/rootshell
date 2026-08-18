#if !targetEnvironment(macCatalyst)

import CoreLocation
import Darwin
import Foundation
import NetworkExtension
import OSLog
import UIKit

// MARK: - ios_system entry point

/// Entry point for `bssid` when invoked via ios_system.
/// Displays BSSID, SSID, vendor, and AP info for the current WiFi connection.
@_cdecl("bssid_main")
func bssid_main(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    return bssidIOSSystemEntry(argc: argc, argv: argv)
}

// MARK: - Implementation

private let logger = Logger(subsystem: "com.kk2.rootshell", category: "bssid-bridge")

private func outputStreamForCurrentThread() -> UnsafeMutablePointer<FILE>? {
    if let stream = ios_get_thread_stdout() {
        return stream
    }
    if let stream = ios_get_thread_stderr() {
        return stream
    }
    return Darwin.stdout
}

private func writeToCurrentThreadOutput(_ text: String) {
    guard let stream = outputStreamForCurrentThread() else {
        logger.error("No output stream available for bssid ios_system bridge")
        return
    }
    fputs(text, stream)
    fflush(stream)
}

private func bssidIOSSystemEntry(
    argc: Int32,
    argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    // Parse arguments
    let args = extractBssidArgs(argc: argc, argv: argv)
    let argSet = Set(args.map { $0.lowercased() })

    if argSet.contains("-h") || argSet.contains("--help") {
        writeToCurrentThreadOutput(bssidHelpText)
        return 0
    }

    let verbose = argSet.contains("-v")

    // Create a pipe for bridging MainActor output → this thread's stdout
    var pipeFds: [Int32] = [0, 0]
    guard pipe(&pipeFds) == 0 else {
        writeToCurrentThreadOutput("bssid: failed to create pipe\n")
        return 1
    }
    let pipeReadFd = pipeFds[0]
    let pipeWriteFd = pipeFds[1]

    guard let threadStdout = outputStreamForCurrentThread() else {
        close(pipeReadFd)
        close(pipeWriteFd)
        logger.error("No output stream available after pipe setup")
        return 1
    }

    _ = fcntl(pipeWriteFd, F_SETNOSIGPIPE, 1)

    let writeQueue = DispatchQueue(label: "com.rootshell.bssid-bridge.write")
    let writeFd = pipeWriteFd

    nonisolated(unsafe) var exitStatus: Int32 = 0
    nonisolated(unsafe) var writeClosed = false

    Task { @MainActor in
        let writeText: @Sendable (String) -> Void = { text in
            guard let data = text.data(using: .utf8) else { return }
            writeQueue.async {
                guard !writeClosed else { return }
                data.withUnsafeBytes { buf in
                    guard let ptr = buf.baseAddress else { return }
                    var remaining = buf.count
                    var offset = 0
                    while remaining > 0 {
                        let written = write(writeFd, ptr + offset, remaining)
                        if written < 0 {
                            if errno == EINTR { continue }
                            writeClosed = true
                            break
                        }
                        if written == 0 { break }
                        offset += written
                        remaining -= written
                    }
                }
            }
        }

        let success = await performBssidLookup(verbose: verbose, output: writeText)

        writeQueue.async {
            exitStatus = success ? 0 : 1
            guard !writeClosed else { return }
            writeClosed = true
            close(writeFd)
        }
    }

    // Read loop: pipe read-end → ios_get_thread_stdout()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
        close(pipeReadFd)
    }

    while true {
        let bytesRead = read(pipeReadFd, buffer, bufferSize)
        if bytesRead > 0 {
            fwrite(buffer, 1, bytesRead, threadStdout)
            fflush(threadStdout)
        } else if bytesRead == 0 {
            break
        } else {
            if errno == EINTR { continue }
            break
        }
    }

    return exitStatus
}

// MARK: - BSSID lookup

@MainActor
private func performBssidLookup(
    verbose: Bool,
    output: @escaping @Sendable (String) -> Void
) async -> Bool {
    // Touch the network monitor early so it has time to receive its initial
    // NWPath update before we need connectionType for error messaging.
    _ = NetworkReachabilityMonitor.shared

    // Helper must stay alive for the duration — CLLocationManager must be
    // retained when fetchCurrent is called.
    let helper = LocationAuthHelper()

    let status = await helper.requestAuthorizationIfNeeded()

    if status == .denied || status == .restricted {
        output("bssid: location permission required for WiFi info\n")
        output("       Grant location access in Settings > Privacy > Location Services\n")
        return false
    }

    let hasPrecise = helper.accuracyAuthorization == .fullAccuracy
    if !hasPrecise {
        output("bssid: precise location required for WiFi info\n")
        output("       Enable in Settings > Privacy > Location Services > Rootshell\n")
        output("       Note: VPN users are not affected (VPN satisfies the requirement)\n")
        return false
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
        output("WiFi info debug:\n")
        output("  Location auth:  \(statusName)\n")
        output("  Precise loc:    \(accuracyName)\n")
        output("  Network path:   \(netType)\n")
        output("  Note: Precise location required unless VPN is configured\n\n")
    }

    let network = await withCheckedContinuation { (cont: CheckedContinuation<NEHotspotNetwork?, Never>) in
        NEHotspotNetwork.fetchCurrent { network in
            cont.resume(returning: network)
        }
    }

    guard let network else {
        let connType = NetworkReachabilityMonitor.shared.connectionType
        if connType != .wifi && connType != .unknown {
            output("bssid: not connected to WiFi\n")
        } else {
            output("bssid: unable to read WiFi info\n")
        }
        return false
    }

    let normalizedBSSID = MACAddress.canonicalString(for: network.bssid) ?? network.bssid.uppercased()
    WiFiAPCacheManager.shared.refreshIfStale()
    let matchedAP = WiFiAPCacheManager.shared.findAccessPoint(forBSSID: normalizedBSSID)
    let vendor = OUILookup.resolveVendor(bssid: normalizedBSSID, matchedAP: matchedAP)

    output("SSID:   \(network.ssid)\n")
    output("BSSID:  \(normalizedBSSID)\n")

    // Use manual AP's stored vendor name if available, else OUI lookup.
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
    output("Vendor: \(displayVendorName)\n")

    if let matchedAP {
        var apLine = "AP:     \(matchedAP.name)"
        if let model = matchedAP.shortname ?? matchedAP.model {
            apLine += " (\(model))"
        }
        if let siteName = matchedAP.siteName {
            apLine += " @ \(siteName)"
        }
        apLine += "\n"
        output(apLine)
    }

    // Band info from radio cache
    let radio = WiFiAPRadioCacheManager.shared.findRadio(forBSSID: normalizedBSSID)
    if let radio {
        var bandLine = "Band:   \(radio.band.rawValue)"
        if let standard = radio.standard {
            bandLine += " (\(standard))"
        }
        bandLine += "\n"
        output(bandLine)
    }

    // Determine favicon website: manual AP's custom domain takes priority.
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

        output("        ")
        if let pngData {
            LocalShellSession.emitKittyGraphics(pngData: pngData, cols: 2, rows: 1, output: output)
            output(" ")
        }
        output("\(website)\n")
    }

    UIPasteboard.general.string = normalizedBSSID
    output("(copied to clipboard)\n")
    return true
}

// MARK: - Helpers

private func extractBssidArgs(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> [String] {
    let safeArgc = max(0, Int(argc))
    guard safeArgc > 1, let argv else { return [] }

    var args: [String] = []
    args.reserveCapacity(safeArgc - 1)

    for i in 1..<safeArgc {
        if let arg = argv[i], let decoded = String(validatingUTF8: arg) {
            args.append(decoded)
        }
    }

    return args
}

private let bssidHelpText = """
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

#endif // !targetEnvironment(macCatalyst)
