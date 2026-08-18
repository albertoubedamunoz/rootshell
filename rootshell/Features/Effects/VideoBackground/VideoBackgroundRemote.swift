//
//  VideoBackgroundRemote.swift
//  rootshell
//
//  Data models for remote video background system
//

import Foundation

// MARK: - Remote Index Response

/// Response from remote index.json
struct VideoBackgroundIndex: Codable, Sendable {
    let version: Int
    let backgrounds: [RemoteVideoBackground]
}

// MARK: - Remote Video Metadata

/// Metadata for a remote video background
struct RemoteVideoBackground: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let filename: String
    let displayName: String
    let description: String
    let aspectRatio: AspectRatioConfig
    let resolution: ResolutionConfig
    let duration: Double
    let loop: LoopConfig
    let defaultIntensity: Double
    let previewIcon: String
    let category: String
    let thumbnail: String

    struct AspectRatioConfig: Codable, Sendable, Hashable {
        let mode: String
        let alignment: String
    }

    struct ResolutionConfig: Codable, Sendable, Hashable {
        let width: Int
        let height: Int
    }

    struct LoopConfig: Codable, Sendable, Hashable {
        let seamless: Bool
        let crossfadeDuration: Double
    }

    /// URL for the video file
    func videoURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(filename)
    }

    /// URL for the thumbnail image
    func thumbnailURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(thumbnail)
    }
}

// MARK: - Download State

/// Download state for a video background
enum VideoDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case paused(progress: Double)
    case completed
    case failed(error: String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var progress: Double? {
        switch self {
        case .downloading(let progress), .paused(let progress):
            return progress
        default:
            return nil
        }
    }
}

// MARK: - Cache Metadata

/// Metadata about a downloaded video stored in cache
struct VideoBackgroundCacheEntry: Codable, Sendable {
    let id: String
    let filename: String
    let downloadedAt: Date
    let fileSize: Int64
    let metadata: RemoteVideoBackground
}

/// Index of all cached videos
struct VideoBackgroundCacheIndex: Codable {
    var version: Int = 1
    var entries: [String: VideoBackgroundCacheEntry] = [:]
    var lastIndexFetch: Date?
}
