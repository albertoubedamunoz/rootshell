//
//  PushSharedState.swift
//  RootshellPushKit
//
//  App-group files shared with the extension: recent decrypted events (for
//  notification arbitration) and the device-side acceptance policy
//  (current device id + revoked senders), since the relay keeps no state.
//

import Foundation

public struct PushEventRecord: Codable, Sendable, Equatable {
    public var eid: String
    public var receivedAt: Date
    public var status: String?
    public var agent: String?
    public var thread: String?
    public var route: PushRoute?

    public init(eid: String, receivedAt: Date = Date(), status: String?, agent: String?, thread: String?, route: PushRoute?) {
        self.eid = eid; self.receivedAt = receivedAt; self.status = status; self.agent = agent; self.thread = thread; self.route = route
    }

    public init(header: PushHeader, eid: String) {
        self.init(eid: eid, status: header.status, agent: header.agent, thread: header.thread, route: header.route)
    }
}

/// What the device accepts. Pushes stamped with another device id (a prior
/// registration) or a revoked sender id are dropped before display.
public struct PushAcceptancePolicy: Codable, Sendable, Equatable {
    public var deviceID: String?
    public var revokedSenderIDs: Set<String>

    public init(deviceID: String?, revokedSenderIDs: Set<String> = []) {
        self.deviceID = deviceID; self.revokedSenderIDs = revokedSenderIDs
    }

    public func accepts(_ envelope: PushEnvelope) -> Bool {
        if let did = envelope.did, let mine = deviceID, did != mine { return false }
        if let sid = envelope.sid, revokedSenderIDs.contains(sid) { return false }
        return true
    }
}

public struct PushSharedState: Sendable {
    public static let maxRecords = 200
    public static let retention: TimeInterval = 48 * 3600

    let eventsURL: URL?
    let policyURL: URL?

    public init(appGroup: String = PushConfiguration.appGroup) {
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        eventsURL = container?.appendingPathComponent("push-events.json")
        policyURL = container?.appendingPathComponent("push-policy.json")
    }

    public func load() -> [PushEventRecord] {
        guard let eventsURL, let data = try? Data(contentsOf: eventsURL),
              let records = try? JSONDecoder().decode([PushEventRecord].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return records.filter { $0.receivedAt > cutoff }
    }

    public func append(_ record: PushEventRecord) {
        guard let eventsURL else { return }
        var records = load().filter { $0.eid != record.eid }
        records.append(record)
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: eventsURL, options: .atomic)
        }
    }

    public func loadPolicy() -> PushAcceptancePolicy {
        guard let policyURL, let data = try? Data(contentsOf: policyURL),
              let policy = try? JSONDecoder().decode(PushAcceptancePolicy.self, from: data) else {
            return PushAcceptancePolicy(deviceID: nil)
        }
        return policy
    }

    public func save(_ policy: PushAcceptancePolicy) {
        guard let policyURL, let data = try? JSONEncoder().encode(policy) else { return }
        try? data.write(to: policyURL, options: .atomic)
    }

    public func clear() {
        if let eventsURL { try? FileManager.default.removeItem(at: eventsURL) }
        if let policyURL { try? FileManager.default.removeItem(at: policyURL) }
    }
}
