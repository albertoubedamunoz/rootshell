//
//  VPNProfileEntity.swift
//  rootshell
//
//  AppEntity exposing VPN-capable ConnectionProfiles to Shortcuts.
//

import AppIntents

/// Shortcuts-visible entity representing a VPN-capable connection profile.
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

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if username.isEmpty || host.isEmpty {
            subtitle = host
        } else {
            subtitle = "\(username)@\(host)"
        }

        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "network.badge.shield.half.filled")
        )
    }
}

extension ConnectionProfile {
    /// Converts this profile into a VPN Shortcuts entity.
    func toVPNEntity() -> VPNProfileEntity {
        VPNProfileEntity(
            id: id,
            name: name,
            host: sshConfig.host,
            username: sshConfig.username,
            connectionProtocol: connectionProtocol.displayName
        )
    }
}
