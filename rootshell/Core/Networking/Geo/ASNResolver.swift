//
//  ASNResolver.swift
//  rootshell
//
//  One-shot ASN/country/CIDR resolver using Team Cymru DNS TXT queries.
//

import Foundation
import Darwin

enum ASNResolver {
    /// Resolve ASN info for an IP address via Team Cymru DNS.
    static func resolve(ip: String) async -> GeoInfo? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveSync(ip: ip))
            }
        }
    }

    /// Synchronous ASN resolution — blocks the calling thread.
    /// Call from a background queue only.
    static func resolveSync(ip: String) -> GeoInfo? {
        var addr4 = in_addr()
        var addr6 = in6_addr()

        if inet_pton(AF_INET, ip, &addr4) == 1 {
            let bytes = withUnsafeBytes(of: &addr4.s_addr) { Array($0) }
            let reversed = bytes.reversed().map { String($0) }.joined(separator: ".")
            let query = "\(reversed).origin.asn.cymru.com"
            return performTXTLookup(query)
        } else if inet_pton(AF_INET6, ip, &addr6) == 1 {
            let reversed = withUnsafeBytes(of: &addr6) { Array($0) }
                .map { byte -> String in
                    let lo = String(format: "%x", byte & 0x0F)
                    let hi = String(format: "%x", (byte >> 4) & 0x0F)
                    return "\(lo).\(hi)"
                }
                .reversed()
                .joined(separator: ".")
            let query = "\(reversed).origin6.asn.cymru.com"
            return performTXTLookup(query)
        } else {
            return nil
        }
    }

    private static func performTXTLookup(_ queryName: String) -> GeoInfo? {
        var answer = [UInt8](repeating: 0, count: 1024)
        // ns_c_in = 1 (Internet class), ns_t_txt = 16 (TXT record type)
        let len = res_9_query(queryName, 1, 16, &answer, Int32(answer.count))
        guard len > 0 else { return nil }

        let responseLen = Int(len)
        guard responseLen <= answer.count, responseLen >= 12 else { return nil }

        let qdcount = Int(answer[4]) << 8 | Int(answer[5])
        let ancount = Int(answer[6]) << 8 | Int(answer[7])
        guard ancount > 0 else { return nil }

        var offset = 12

        // Skip question section
        for _ in 0..<qdcount {
            offset = skipDNSName(answer, offset: offset, length: responseLen)
            guard offset >= 0, offset + 4 <= responseLen else { return nil }
            offset += 4
        }

        // Parse answer records
        for _ in 0..<ancount {
            guard offset < responseLen else { return nil }
            offset = skipDNSName(answer, offset: offset, length: responseLen)
            guard offset >= 0, offset + 10 <= responseLen else { return nil }

            let rtype = Int(answer[offset]) << 8 | Int(answer[offset + 1])
            let rdlength = Int(answer[offset + 8]) << 8 | Int(answer[offset + 9])
            offset += 10

            guard offset + rdlength <= responseLen else { return nil }

            if rtype == 16, rdlength > 1 {
                let txtLen = Int(answer[offset])
                guard txtLen <= rdlength - 1, offset + 1 + txtLen <= responseLen else { return nil }
                let txtData = Array(answer[(offset + 1)..<(offset + 1 + txtLen)])
                if let txt = String(bytes: txtData, encoding: .utf8) {
                    return parseASResponse(txt)
                }
            }

            offset += rdlength
        }

        return nil
    }

    private static func skipDNSName(_ buffer: [UInt8], offset: Int, length: Int) -> Int {
        guard length <= buffer.count, offset >= 0, offset < length else { return -1 }
        var pos = offset
        while pos < length {
            let labelLen = Int(buffer[pos])
            if labelLen == 0 { return pos + 1 }
            if (labelLen & 0xC0) == 0xC0 {
                return (pos + 1 < length) ? (pos + 2) : -1
            }
            guard labelLen <= 63, pos + labelLen + 1 <= length else { return -1 }
            pos += labelLen + 1
        }
        return -1
    }

    /// Parse Team Cymru response: "12345 | 1.2.3.0/24 | US | arin | 2001-01-01"
    private static func parseASResponse(_ txt: String) -> GeoInfo? {
        let parts = txt.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        let asNumber = parts[0].isEmpty ? "?" : "AS\(parts[0])"
        let cidr = parts.count > 1 ? parts[1] : ""
        let country = parts.count > 2 ? parts[2] : ""
        let rir = parts.count > 3 ? parts[3] : ""
        let date = parts.count > 4 ? parts[4] : ""

        return GeoInfo(
            asNumber: asNumber,
            asName: nil,
            asDomain: nil,
            network: cidr,
            cityName: nil,
            countryCode: country,
            countryName: nil,
            continentCode: nil,
            continentName: nil,
            rir: rir,
            allocationDate: date,
            provider: .dns
        )
    }
}
