//
//  VPNProfileEntityQuery.swift
//  rootshell
//
//  EntityQuery providing VPN profile and Tailscale lookup for Shortcuts parameter UI.
//

import AppIntents

/// Provides VPN profile and Tailscale lookup for Shortcuts entity parameter resolution.
struct VPNProfileEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [UUID]) async -> [VPNProfileEntity] {
        let idSet = Set(identifiers)
        return loadProfiles(includingSignedOutTailnet: true).filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async -> [VPNProfileEntity] {
        let lower = string.lowercased()
        return loadProfiles().filter {
            $0.name.lowercased().contains(lower) ||
            $0.host.lowercased().contains(lower) ||
            $0.username.lowercased().contains(lower)
        }
    }

    func suggestedEntities() async -> [VPNProfileEntity] {
        loadProfiles()
    }

    private func loadProfiles(includingSignedOutTailnet: Bool = false) -> [VPNProfileEntity] {
        VPNSharedProfileStore.startableProfiles(includingSignedOutTailnet: includingSignedOutTailnet).map { profile in
            VPNProfileEntity(
                id: profile.id,
                name: profile.name,
                host: profile.host,
                username: profile.username,
                connectionProtocol: protocolName(profile.transportType),
                subtitle: profile.pickerSubtitle
            )
        }
    }

    private func protocolName(_ transport: VPNSharedTransportType) -> String {
        switch transport {
        case .ssh: "SSH"
        case .tssh: "Roam - tssh"
        case .direct: "Direct"
        case .tailscale: "Tailscale"
        }
    }
}
