//
//  VPNProfileEntity.swift
//  rootshell
//
//  AppEntity exposing VPN-capable ConnectionProfiles and Tailscale to Shortcuts.
//

import AppIntents

/// Shortcuts-visible entity representing a VPN-capable connection profile or Tailscale.
struct VPNProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "VPN Profile",
            numericFormat: "\(placeholder: .int) VPN profiles"
        )
    }

    static var defaultQuery = VPNProfileEntityQuery()

    var id: UUID
    var name: String
    var host: String
    var username: String
    var connectionProtocol: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "network.badge.shield.half.filled")
        )
    }
}
