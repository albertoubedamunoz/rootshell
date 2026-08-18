import Foundation

/// Parses `iwconfig` output from Ubiquiti APs into radio interface data.
///
/// iwconfig output has one block per interface, with the interface name at column 0
/// and continuation lines indented with whitespace.
enum IWConfigParser {

    /// An intermediate parsed interface before being tied to a specific AP
    struct ParsedInterface: Sendable {
        let interfaceName: String
        let essid: String
        let frequencyGHz: Double
        let band: WiFiBand
        let bssid: String
        let standard: String?
        let bitRate: String?
        let txPower: String?
    }

    /// Parse raw iwconfig output into radio interfaces for a given AP
    static func parse(
        _ output: String,
        accessPointID: String,
        accessPointMAC: String
    ) -> [WiFiAPRadio] {
        let interfaces = parseInterfaces(output)
        return interfaces.map { iface in
            WiFiAPRadio(
                accessPointID: accessPointID,
                accessPointMAC: accessPointMAC,
                interfaceName: iface.interfaceName,
                essid: iface.essid,
                frequencyGHz: iface.frequencyGHz,
                band: iface.band,
                bssid: iface.bssid,
                standard: iface.standard,
                bitRate: iface.bitRate,
                txPower: iface.txPower
            )
        }
    }

    /// Parse raw iwconfig output into intermediate interface structs
    static func parseInterfaces(_ output: String) -> [ParsedInterface] {
        let blocks = splitIntoBlocks(output)
        return blocks.compactMap { parseBlock($0) }
    }

    // MARK: - Private

    /// Split iwconfig output into per-interface blocks.
    /// Each block starts with a line that has no leading whitespace.
    private static func splitIntoBlocks(_ output: String) -> [(name: String, text: String)] {
        var blocks: [(name: String, text: String)] = []
        var currentName: String?
        var currentLines: [String] = []

        for line in output.components(separatedBy: "\n") {
            // Interface header lines start at column 0 (no leading whitespace)
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                // Save previous block
                if let name = currentName {
                    blocks.append((name, currentLines.joined(separator: "\n")))
                }
                // Extract interface name (first word)
                let name = String(line.prefix(while: { !$0.isWhitespace }))
                currentName = name
                currentLines = [line]
            } else if currentName != nil {
                currentLines.append(line)
            }
        }

        // Don't forget last block
        if let name = currentName {
            blocks.append((name, currentLines.joined(separator: "\n")))
        }

        return blocks
    }

    /// Parse a single interface block into a ParsedInterface, or nil if not a valid wireless interface
    private static func parseBlock(_ block: (name: String, text: String)) -> ParsedInterface? {
        let text = block.text

        // Skip interfaces with "no wireless extensions"
        if text.contains("no wireless extensions") {
            return nil
        }

        // Extract ESSID — required
        guard let essid = extractESSID(from: text), !essid.isEmpty else {
            return nil
        }

        // Extract frequency — required
        guard let frequency = extractFrequency(from: text) else {
            return nil
        }

        // Extract Access Point (BSSID) — required
        guard let rawBSSID = extractAccessPoint(from: text),
              let mac = MACAddress(rawBSSID) else {
            return nil
        }

        let standard = extractStandard(from: text)
        let bitRate = extractBitRate(from: text)
        let txPower = extractTxPower(from: text)

        return ParsedInterface(
            interfaceName: block.name,
            essid: essid,
            frequencyGHz: frequency,
            band: WiFiBand.from(frequencyGHz: frequency),
            bssid: mac.canonicalString,
            standard: standard,
            bitRate: bitRate,
            txPower: txPower
        )
    }

    // MARK: - Regex Extractors

    private static func extractESSID(from text: String) -> String? {
        guard let match = text.firstMatch(of: /ESSID:"([^"]*)"/) else { return nil }
        return String(match.1)
    }

    private static func extractFrequency(from text: String) -> Double? {
        guard let match = text.firstMatch(of: /Frequency:(\d+\.?\d*)\s*GHz/) else { return nil }
        return Double(match.1)
    }

    private static func extractAccessPoint(from text: String) -> String? {
        guard let match = text.firstMatch(of: /Access Point:\s*([0-9A-Fa-f:]{17})/) else { return nil }
        return String(match.1)
    }

    private static func extractStandard(from text: String) -> String? {
        guard let match = text.firstMatch(of: /IEEE\s+(802\.11\S+)/) else { return nil }
        return String(match.1)
    }

    private static func extractBitRate(from text: String) -> String? {
        guard let match = text.firstMatch(of: /Bit Rate[=:](\S+\s*[MGT]b\/s)/) else { return nil }
        return String(match.1)
    }

    private static func extractTxPower(from text: String) -> String? {
        guard let match = text.firstMatch(of: /Tx-Power[=:](\d+\s*dBm)/) else { return nil }
        return String(match.1)
    }
}
