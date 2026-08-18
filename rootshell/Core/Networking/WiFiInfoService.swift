import Combine
import CoreLocation
import Foundation
import os

#if !targetEnvironment(macCatalyst)
import NetworkExtension
#endif

/// Service that fetches current WiFi network info (SSID, BSSID, vendor, matched AP).
/// On iOS, uses NEHotspotNetwork (requires precise location permission).
/// On Mac Catalyst, uses CoreWLAN via a native macOS plugin bundle.
@MainActor
final class WiFiInfoService: ObservableObject {
    static let shared = WiFiInfoService()

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell", category: "WiFiInfoService"
    )

    // MARK: - Published State

    @Published private(set) var ssid: String?
    @Published private(set) var bssid: String?
    @Published private(set) var vendorName: String?
    @Published private(set) var vendorWebsite: String?
    @Published private(set) var isRandomizedMAC = false
    @Published private(set) var matchedAP: WiFiAccessPoint?
    @Published private(set) var currentBand: WiFiBand?
    @Published private(set) var matchedRadio: WiFiAPRadio?

    @Published private(set) var isFetching = false
    @Published private(set) var fetchError: String?

    /// Whether WiFi data was successfully fetched and is available to display.
    var hasWiFiData: Bool {
        ssid != nil
    }

    #if !targetEnvironment(macCatalyst)
    // iOS-only: location authorization state for NEHotspotNetwork
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var hasPreciseLocation = false

    /// True when location is authorized and precise — required for NEHotspotNetwork.
    var shouldShowWiFiInfo: Bool {
        #if os(visionOS)
        return false
        #else
        let authorized = authorizationStatus == .authorizedWhenInUse ||
                         authorizationStatus == .authorizedAlways
        return authorized && hasPreciseLocation
        #endif
    }

    /// Whether to show the "Enable WiFi Info" opt-in button.
    var canRequestPermission: Bool {
        authorizationStatus == .notDetermined
    }
    #endif

    // MARK: - Private

    /// Set by refreshVendorAndAP() so the next pollForChanges() re-runs
    /// populateVendorAndAP() even when the SSID/BSSID haven't changed.
    private var needsVendorRefresh = false

    #if targetEnvironment(macCatalyst)
    private var coreWLANPlugin: CoreWLANPluginProtocol?
    private var pluginLoadAttempted = false
    #else
    private let locationDelegate = LocationDelegate()
    #endif

    private init() {
        #if !targetEnvironment(macCatalyst)
        locationDelegate.service = self
        authorizationStatus = locationDelegate.manager.authorizationStatus
        hasPreciseLocation = locationDelegate.manager.accuracyAuthorization == .fullAccuracy
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Request when-in-use location authorization, then fetch WiFi info.
    func requestPermissionAndFetch() async {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<CLAuthorizationStatus, Never>) in
            locationDelegate.authContinuation = cont
            locationDelegate.manager.requestWhenInUseAuthorization()
        }
        updateAuthorization(
            status: status,
            precise: locationDelegate.manager.accuracyAuthorization == .fullAccuracy
        )
        await fetch()
    }
    #endif

    // MARK: - Fetch

    func fetch() async {
        isFetching = true
        fetchError = nil

        #if targetEnvironment(macCatalyst)
        await fetchViaCoreWLANPlugin()
        #else
        await fetchViaNEHotspotNetwork()
        #endif

        isFetching = false
    }

    /// Silent poll that only updates published properties when values change.
    /// Does not toggle isFetching, so the UI won't flicker.
    func pollForChanges() async {
        #if targetEnvironment(macCatalyst)
        guard let plugin = loadCoreWLANPlugin(),
              let wifiInfo = plugin.currentWiFiInfo(),
              let fetchedSSID = wifiInfo["ssid"] else {
            if ssid != nil { clearResults() }
            return
        }
        let fetchedBSSID = MACAddress.canonicalString(for: wifiInfo["bssid"])
        #else
        guard shouldShowWiFiInfo else {
            if ssid != nil { clearResults() }
            return
        }
        let network = await fetchCurrentHotspotWithTimeout(seconds: 2)
        guard let network else {
            if ssid != nil { clearResults() }
            return
        }
        let fetchedSSID = network.ssid
        let fetchedBSSID = MACAddress.canonicalString(for: network.bssid)
        #endif

        let networkChanged = fetchedBSSID != bssid || fetchedSSID != ssid

        if networkChanged {
            ssid = fetchedSSID
            bssid = fetchedBSSID
        }

        // AP metadata can arrive after the SSID/BSSID snapshot via provider
        // syncs, manual entries, or radio scans. Re-resolve while display
        // enrichment is incomplete so Live Activity does not get stuck showing
        // only SSID/band until the device roams to a different BSSID.
        let needsDisplayEnrichment = matchedAP == nil || currentBand == nil || vendorName == nil
        guard networkChanged || needsVendorRefresh || needsDisplayEnrichment else { return }
        needsVendorRefresh = false
        populateVendorAndAP()
    }

    // MARK: - Mac Catalyst (CoreWLAN Plugin)

    #if targetEnvironment(macCatalyst)
    private func fetchViaCoreWLANPlugin() async {
        guard let plugin = loadCoreWLANPlugin() else {
            clearResults()
            fetchError = "WiFi info unavailable"
            return
        }

        guard let wifiInfo = plugin.currentWiFiInfo(),
              let fetchedSSID = wifiInfo["ssid"] else {
            clearResults()
            // nil means not on WiFi or location not granted — don't set error,
            // the section just won't appear
            return
        }

        ssid = fetchedSSID
        bssid = MACAddress.canonicalString(for: wifiInfo["bssid"])
        populateVendorAndAP()

        Self.logger.debug("WiFi info fetched via CoreWLAN: SSID=\(fetchedSSID, privacy: .public)")
    }

    private func loadCoreWLANPlugin() -> CoreWLANPluginProtocol? {
        if pluginLoadAttempted { return coreWLANPlugin }
        pluginLoadAttempted = true

        guard let pluginsURL = Bundle.main.builtInPlugInsURL else {
            Self.logger.error("CoreWLAN plugin: builtInPlugInsURL is nil")
            return nil
        }

        let bundleURL = pluginsURL.appendingPathComponent("CoreWLANPlugin.bundle")
        guard let bundle = Bundle(url: bundleURL) else {
            let path = bundleURL.path
            Self.logger.error("CoreWLAN plugin: could not create Bundle at \(path)")
            return nil
        }

        do {
            try bundle.loadAndReturnError()
        } catch {
            Self.logger.error("CoreWLAN plugin: failed to load: \(error)")
            return nil
        }

        guard let principalClass = bundle.principalClass as? NSObject.Type else {
            Self.logger.error("CoreWLAN plugin: principalClass is nil or not NSObject")
            return nil
        }

        guard let instance = principalClass.init() as? CoreWLANPluginProtocol else {
            Self.logger.error("CoreWLAN plugin: does not conform to CoreWLANPluginProtocol")
            return nil
        }

        coreWLANPlugin = instance
        Self.logger.info("CoreWLAN plugin loaded successfully")
        return instance
    }
    #endif

    // MARK: - iOS / visionOS (NEHotspotNetwork)

    #if !targetEnvironment(macCatalyst)
    private func fetchViaNEHotspotNetwork() async {
        authorizationStatus = locationDelegate.manager.authorizationStatus
        hasPreciseLocation = locationDelegate.manager.accuracyAuthorization == .fullAccuracy

        guard shouldShowWiFiInfo else {
            clearResults()
            return
        }

        let network = await fetchCurrentHotspotWithTimeout(seconds: 2)

        guard let network else {
            clearResults()
            // Don't set fetchError — if no network, the section just won't appear
            return
        }

        ssid = network.ssid
        bssid = MACAddress.canonicalString(for: network.bssid)
        populateVendorAndAP()

        Self.logger.debug("WiFi info fetched: SSID=\(network.ssid, privacy: .public)")
    }

    /// Wraps `NEHotspotNetwork.fetchCurrent` with a hard timeout. The system
    /// callback can hang (seen during foreground resume when Wi-Fi entitlement
    /// or precise-location state is not yet settled), and a plain
    /// `withCheckedContinuation` gives it no deadline. Races the callback
    /// against a `DispatchQueue.asyncAfter` on a shared resolved flag so
    /// whichever arrives first resumes the continuation; the loser no-ops.
    /// If the hotspot callback fires after the timeout, its result is
    /// dropped — that is acceptable, the next poll cycle picks up the SSID.
    // TODO: consolidate with the `withTimeout` helpers in
    // `Kubernetes/KubernetesExecClient.swift` and `Console/ConsoleClient.swift`.
    private func fetchCurrentHotspotWithTimeout(seconds: Double) async -> NEHotspotNetwork? {
        await withCheckedContinuation { (cont: CheckedContinuation<NEHotspotNetwork?, Never>) in
            let resolved = OSAllocatedUnfairLock<Bool>(initialState: false)

            NEHotspotNetwork.fetchCurrent { network in
                let wasFirst = resolved.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if wasFirst {
                    cont.resume(returning: network)
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                let wasFirst = resolved.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if wasFirst {
                    Self.logger.warning("NEHotspotNetwork.fetchCurrent timed out after \(seconds)s")
                    cont.resume(returning: nil)
                }
            }
        }
    }
    #endif

    // MARK: - Shared Helpers

    private func populateVendorAndAP() {
        guard let bssidValue = bssid else { return }

        WiFiAPCacheManager.shared.refreshIfStale()
        let matchedAccessPoint = WiFiAPCacheManager.shared.findAccessPoint(forBSSID: bssidValue)
        matchedAP = matchedAccessPoint

        let radio = WiFiAPRadioCacheManager.shared.findRadio(forBSSID: bssidValue)
        matchedRadio = radio
        currentBand = radio?.band

        // Always try vendor lookup — enterprise APs routinely set the
        // locally-administered (LA) bit on virtual BSSIDs for multi-SSID.
        // The LA bit on a BSSID does NOT mean "randomized" (that concept
        // applies to client device MACs, not access points).
        if let vendor = OUILookup.resolveVendor(bssid: bssidValue, matchedAP: matchedAccessPoint) {
            vendorName = vendor.name
            vendorWebsite = vendor.website
        } else {
            vendorName = "Unknown"
            vendorWebsite = nil
        }
        // Override vendor info with manual AP's stored data.
        // Use the matched AP's MAC (the storage key), not the observed BSSID,
        // because the matcher may have resolved through LA-bit or prefix/suffix
        // similarity (ranks 1-4) where the BSSID differs from the stored MAC.
        if let apMAC = matchedAccessPoint?.mac,
           matchedAccessPoint?.providerID == ManualAPManager.manualProviderID {
            if let manualVendor = ManualAPManager.shared.vendorName(forMAC: apMAC),
               !manualVendor.isEmpty {
                vendorName = manualVendor
            }
            if let customDomain = ManualAPManager.shared.vendorDomain(forMAC: apMAC) {
                vendorWebsite = "https://\(customDomain)"
            }
        }

        isRandomizedMAC = matchedAccessPoint == nil && OUILookup.isRandomizedMAC(bssidValue)
    }

    /// Re-resolve vendor/AP data for the current BSSID without requiring a
    /// network change. Call after manual AP entries are added/edited/deleted
    /// so that matchedAP, vendorName, and vendorWebsite update immediately.
    /// Also sets needsVendorRefresh so the next pollForChanges() re-resolves
    /// even though the SSID/BSSID haven't changed (covers Live Activity polling).
    func refreshVendorAndAP() {
        needsVendorRefresh = true
        populateVendorAndAP()
    }

    fileprivate func updateAuthorization(status: CLAuthorizationStatus, precise: Bool) {
        #if !targetEnvironment(macCatalyst)
        authorizationStatus = status
        hasPreciseLocation = precise
        #endif
    }

    private func clearResults() {
        ssid = nil
        bssid = nil
        vendorName = nil
        vendorWebsite = nil
        isRandomizedMAC = false
        matchedAP = nil
        currentBand = nil
        matchedRadio = nil
    }
}

// MARK: - CLLocationManager Delegate (iOS only)

#if !targetEnvironment(macCatalyst)
/// Delegate that forwards authorization changes back to WiFiInfoService.
private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    weak var service: WiFiInfoService?
    var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume(returning: manager.authorizationStatus)
            }
            self.service?.updateAuthorization(
                status: manager.authorizationStatus,
                precise: manager.accuracyAuthorization == .fullAccuracy
            )
        }
    }
}
#endif
