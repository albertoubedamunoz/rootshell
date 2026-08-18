import CoreWLAN
import Foundation
import os

final class CoreWLANProvider: NSObject, CoreWLANPluginProtocol {

    private static let logger = Logger(
        subsystem: "com.rootshell", category: "CoreWLANPlugin"
    )

    func currentWiFiInfo() -> [String: String]? {
        guard let interface = CWWiFiClient.shared().interface() else {
            Self.logger.warning("CoreWLAN: No default WiFi interface found")
            return nil
        }

        guard let ssid = interface.ssid() else {
            Self.logger.info("CoreWLAN: SSID is nil (location permission may be required)")
            return nil
        }

        var result: [String: String] = ["ssid": ssid]

        if let bssid = interface.bssid() {
            result["bssid"] = bssid
        }

        Self.logger.debug("CoreWLAN: WiFi info fetched: SSID=\(ssid, privacy: .public)")
        return result
    }
}
