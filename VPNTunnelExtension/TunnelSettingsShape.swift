//
//  TunnelSettingsShape.swift
//  VPNTunnelExtension
//
//  The inputs to the tunnel's network settings, kept so they can be
//  re-applied (e.g. adding an IPv6 route when HTTP capture starts).
//

import Foundation
import NetworkExtension

nonisolated struct TunnelSettingsShape: @unchecked Sendable {
    var serverIP: String
    var excludedRoutes: [NEIPv4Route]
    var dnsServers: [String]
    var mtu: Int
    var includeIPv6: Bool

    static let ipv4Address = "10.0.0.2"
    static let ipv6Address = "fd72:7368:6361:7074::2"

    func makeSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverIP)

        let ipv4 = NEIPv4Settings(addresses: [Self.ipv4Address], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if !excludedRoutes.isEmpty {
            ipv4.excludedRoutes = excludedRoutes
        }
        settings.ipv4Settings = ipv4

        if includeIPv6 {
            let ipv6 = NEIPv6Settings(addresses: [Self.ipv6Address], networkPrefixLengths: [NSNumber(value: 64)])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = ipv6
        }

        if !dnsServers.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        }
        settings.mtu = NSNumber(value: mtu)
        return settings
    }
}
