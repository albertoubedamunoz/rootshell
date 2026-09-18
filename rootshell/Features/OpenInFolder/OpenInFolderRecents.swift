//
//  OpenInFolderRecents.swift
//  rootshell
//

import Foundation

/// Most-recent-first folders per target key.
nonisolated struct OpenInFolderRecents: Codable, Equatable, Sendable {
    static let capacity = 30

    private(set) var paths: [String: [String]] = [:]

    func paths(for target: String) -> [String] {
        paths[target] ?? []
    }

    mutating func record(_ path: String, target: String, capacity: Int = capacity) {
        var list = paths[target] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > capacity { list.removeLast(list.count - capacity) }
        paths[target] = list
    }

    mutating func remove(_ path: String, target: String) {
        guard var list = paths[target] else { return }
        list.removeAll { $0 == path }
        if list.isEmpty { paths.removeValue(forKey: target) } else { paths[target] = list }
    }

    /// A corrupt or missing blob is an empty history, never a crash.
    static func decode(_ data: Data?) -> OpenInFolderRecents {
        guard let data, let decoded = try? JSONDecoder().decode(OpenInFolderRecents.self, from: data) else {
            return OpenInFolderRecents()
        }
        return decoded
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
