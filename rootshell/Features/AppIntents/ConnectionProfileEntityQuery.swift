//
//  ConnectionProfileEntityQuery.swift
//  rootshell
//
//  EntityQuery providing profile lookup for Shortcuts parameter UI.
//

import AppIntents

/// Provides profile lookup for Shortcuts entity parameter resolution. The
/// EnumerableEntityQuery conformance also gives Shortcuts the automatic
/// "Find Connection Profiles" action with sort and filter support.
struct ConnectionProfileEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    func allEntities() async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.profiles.map { $0.toEntity() }
        }
    }

    func entities(for identifiers: [UUID]) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            identifiers.compactMap { id in
                ConnectionProfileManager.shared.profile(for: id)?.toEntity()
            }
        }
    }

    func entities(matching string: String) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.profiles(matching: string)
                .map { $0.toEntity() }
        }
    }

    func suggestedEntities() async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.getSuggestions(matching: "", limit: 20)
                .map { $0.toEntity() }
        }
    }
}
