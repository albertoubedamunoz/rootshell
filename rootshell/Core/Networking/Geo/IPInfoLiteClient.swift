//
//  IPInfoLiteClient.swift
//  rootshell
//
//  HTTP client for IPInfo Lite API.
//

import Foundation

enum IPInfoLiteClient {
    private nonisolated static let token: String? = {
        guard let obfuscatedToken = bundledHexValue(for: "RootshellIPInfoTokenXOR"),
              let xorKey = bundledHexValue(for: "RootshellIPInfoTokenKey"),
              !obfuscatedToken.isEmpty,
              obfuscatedToken.count == xorKey.count,
              let token = String(
                  bytes: zip(obfuscatedToken, xorKey).map { $0 ^ $1 },
                  encoding: .utf8
              ),
              !token.isEmpty else {
            return nil
        }

        return token
    }()

    nonisolated static var isConfigured: Bool {
        token != nil
    }

    static func resolve(ip: String) async throws -> GeoInfo {
        guard let token else {
            throw URLError(.userAuthenticationRequired)
        }

        let urlString = "https://api.ipinfo.io/lite/\(ip)?token=\(token)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(IPInfoLiteResponse.self, from: data)
        return decoded.toGeoInfo()
    }

    private nonisolated static func bundledHexValue(for key: String) -> [UInt8]? {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.hasPrefix("$("),
              value.count.isMultiple(of: 2) else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex

        while index < value.endIndex {
            let nextIndex = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }
}

// MARK: - Response Model

/// Maps to actual IPInfo Lite JSON response:
/// {"ip":"8.8.8.8","asn":"AS15169","as_name":"Google LLC","as_domain":"google.com",
///  "country_code":"US","country":"United States","continent_code":"NA","continent":"North America"}
private struct IPInfoLiteResponse: Decodable {
    let ip: String?
    let asn: String?
    let as_name: String?
    let as_domain: String?
    let country_code: String?
    let country: String?
    let continent_code: String?
    let continent: String?

    func toGeoInfo() -> GeoInfo {
        let asNumber: String
        if let asn, !asn.isEmpty {
            asNumber = asn.hasPrefix("AS") ? asn : "AS\(asn)"
        } else {
            asNumber = "?"
        }

        return GeoInfo(
            asNumber: asNumber,
            asName: as_name,
            asDomain: as_domain,
            network: "",
            cityName: nil,
            countryCode: country_code ?? "",
            countryName: country,
            continentCode: continent_code,
            continentName: continent,
            rir: "",
            allocationDate: "",
            provider: .ipinfo
        )
    }
}
