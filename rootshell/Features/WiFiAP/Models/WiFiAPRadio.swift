import Foundation

/// A single radio interface on a WiFi access point, discovered via SSH + iwconfig
struct WiFiAPRadio: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(accessPointID)|\(interfaceName)" }

    /// Links to WiFiAccessPoint.id
    let accessPointID: String

    /// Parent AP's chassis MAC (uppercase colon-separated)
    let accessPointMAC: String

    /// Interface name from iwconfig (e.g. "wifi0ap0", "wifi1ap3")
    let interfaceName: String

    /// ESSID being broadcast (e.g. "kk2")
    let essid: String

    /// Operating frequency in GHz (e.g. 2.437, 5.26, 6.135)
    let frequencyGHz: Double

    /// Derived from frequencyGHz
    let band: WiFiBand

    /// Broadcast BSSID — canonical colon-separated MAC
    let bssid: String

    /// IEEE standard (e.g. "802.11beg", "802.11bea")
    let standard: String?

    /// Current bit rate (e.g. "344.2 Mb/s")
    let bitRate: String?

    /// Transmit power (e.g. "6 dBm")
    let txPower: String?
}
