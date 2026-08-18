//
//  VPNWidgetEntities.swift
//  SessionActivityWidget
//
//  Widget-specific AppEntity and EntityQuery for VPN profiles.
//  Reads profile data from the shared app-group mirror so the widget
//  extension can operate without the main app.
//

import AppIntents

/// Widget-specific entity representing a VPN-capable profile.
/// Distinct from the main app's VPNProfileEntity to avoid pulling in main app dependencies.
struct VPNWidgetProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "VPN Profile",
            numericFormat: "\(placeholder: .int) VPN profiles"
        )
    }

    static var defaultQuery = VPNWidgetProfileEntityQuery()

    var id: UUID
    var name: String
    var host: String
    var username: String

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

/// Reads VPN-capable profiles from the shared app-group mirror.
struct VPNWidgetProfileEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async -> [VPNWidgetProfileEntity] {
        let profiles = loadProfiles()
        let idSet = Set(identifiers)
        return profiles.filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async -> [VPNWidgetProfileEntity] {
        let lower = string.lowercased()
        return loadProfiles().filter {
            $0.name.lowercased().contains(lower) ||
            $0.host.lowercased().contains(lower) ||
            $0.username.lowercased().contains(lower)
        }
    }

    func suggestedEntities() async -> [VPNWidgetProfileEntity] {
        loadProfiles()
    }

    private func loadProfiles() -> [VPNWidgetProfileEntity] {
        VPNSharedProfileStore.readAll()
            .filter(\.isBackgroundStartable)
            .map { profile in
                VPNWidgetProfileEntity(
                    id: profile.id,
                    name: profile.name,
                    host: profile.host,
                    username: profile.username
                )
            }
    }
}
