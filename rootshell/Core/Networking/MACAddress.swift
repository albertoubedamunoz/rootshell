import Foundation

/// Canonicalizes MAC/BSSID strings from APIs that may omit zero-padding or use
/// different separators.
nonisolated struct MACAddress: Hashable, Sendable {
    private static let hexCharacterSet = CharacterSet(charactersIn: "0123456789ABCDEFabcdef")

    let octets: [UInt8]

    init?(_ rawValue: String) {
        let separatorCharacterSet = CharacterSet(charactersIn: ":-.")
        let groups: [String]

        if rawValue.rangeOfCharacter(from: separatorCharacterSet) != nil {
            groups = rawValue.components(separatedBy: separatorCharacterSet)
        } else {
            groups = [rawValue]
        }

        var parsedOctets: [UInt8] = []
        for group in groups where !group.isEmpty {
            var groupHex = ""
            for scalar in group.unicodeScalars where Self.hexCharacterSet.contains(scalar) {
                groupHex.unicodeScalars.append(scalar)
            }
            guard !groupHex.isEmpty else { return nil }
            groupHex = groupHex.uppercased()
            if !groupHex.count.isMultiple(of: 2) {
                groupHex = "0" + groupHex
            }

            var index = groupHex.startIndex
            while index < groupHex.endIndex {
                let nextIndex = groupHex.index(index, offsetBy: 2)
                let byteString = String(groupHex[index..<nextIndex])
                guard let byte = UInt8(byteString, radix: 16) else { return nil }
                parsedOctets.append(byte)
                index = nextIndex
            }
        }

        guard parsedOctets.count == 6 else { return nil }
        octets = parsedOctets
    }

    private init(octets: [UInt8]) {
        self.octets = octets
    }

    var canonicalString: String {
        octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    var hexString: String {
        octets.map { String(format: "%02X", $0) }.joined()
    }

    var isLocallyAdministered: Bool {
        guard let firstOctet = octets.first else { return false }
        return (firstOctet & 0x02) != 0
    }

    func prefix(octetCount: Int) -> String? {
        guard octetCount > 0, octets.count >= octetCount else { return nil }
        return octets.prefix(octetCount)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    func suffix(octetCount: Int) -> String? {
        guard octetCount > 0, octets.count >= octetCount else { return nil }
        return octets.suffix(octetCount)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }

    func clearingLocallyAdministeredBit() -> MACAddress {
        guard isLocallyAdministered else { return self }

        var clearedOctets = octets
        clearedOctets[0] &= 0xFD
        return MACAddress(octets: clearedOctets)
    }

    static func canonicalString(for rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        return MACAddress(rawValue)?.canonicalString
    }
}
