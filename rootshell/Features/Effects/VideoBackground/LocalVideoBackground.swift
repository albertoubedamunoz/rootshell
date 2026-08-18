//
//  LocalVideoBackground.swift
//  rootshell
//
//  Data models for user-imported local video backgrounds
//

import Foundation

/// Metadata for a user-imported video background stored on device.
struct LocalVideoBackground: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let filename: String
    var displayName: String
    let originalFilename: String
    let importedAt: Date
    let fileSize: Int64
    let duration: Double
    var aspectMode: VideoAspectMode
    var aspectAlignment: VideoAspectAlignment
    var seamlessLoop: Bool
    var crossfadeDuration: Double
    var defaultIntensity: Double

    static func defaultDisplayName(from originalFilename: String) -> String {
        let stem = (originalFilename as NSString).deletingPathExtension
        return stem.isEmpty ? "Local Video" : stem
    }
}

/// On-disk index of all imported local video backgrounds.
struct LocalVideoBackgroundStore: Codable {
    var version: Int = 1
    var entries: [String: LocalVideoBackground] = [:]
}
