//
//  SettingsMergeResolver.swift
//  rootshell
//
//  Pure per-key last-writer-wins with clock-skew tolerance and a
//  deterministic tie-break so every device converges on the same value.
//

import Foundation

nonisolated enum SettingsMergeResolver {
    struct Local: Sendable {
        let value: CodableValue?
        /// Nil when the value predates the sidecar.
        let modifiedAt: Date?
        let deviceID: String?
    }

    struct Remote: Sendable {
        let value: CodableValue?
        let modifiedAt: Date
        let deviceID: String
    }

    enum Decision: Sendable, Equatable {
        case applyRemote
        case keepLocal
        case keepLocalAndPush
        case noop
    }

    static let skewTolerance: TimeInterval = 120

    static func resolve(local: Local, remote: Remote, alreadyPushed: Bool) -> Decision {
        if local.value == remote.value { return .noop }
        guard let localDate = local.modifiedAt else { return .applyRemote }
        if remote.modifiedAt > localDate + skewTolerance { return .applyRemote }
        if localDate > remote.modifiedAt + skewTolerance { return alreadyPushed ? .keepLocal : .keepLocalAndPush }
        // Near-simultaneous: lowest device ID wins on every device.
        let localDevice = local.deviceID ?? ""
        if remote.deviceID < localDevice { return .applyRemote }
        return alreadyPushed ? .keepLocal : .keepLocalAndPush
    }
}
