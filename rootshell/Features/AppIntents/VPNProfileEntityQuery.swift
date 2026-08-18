//
//  VPNProfileEntityQuery.swift
//  rootshell
//
//  EntityQuery providing VPN-capable profile lookup for Shortcuts parameter UI.
//

import AppIntents

/// Provides VPN-capable profile lookup for Shortcuts entity parameter resolution.
struct VPNProfileEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [UUID]) async -> [VPNProfileEntity] {
        let idSet = Set(identifiers)
        return loadProfiles().filter { idSet.contains($0.id) }
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

    private func loadProfiles() -> [VPNProfileEntity] {
        VPNSharedProfileStore.readAll()
            .filter(\.isBackgroundStartable)
            .map { profile in
                VPNProfileEntity(
                    id: profile.id,
                    name: profile.name,
                    host: profile.host,
                    username: profile.username,
                    connectionProtocol: profile.transportType == .tssh ? "Roam - tssh" : "SSH"
                )
            }
    }
}
