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
    public var enabled: Bool
    public var deviceID: String?
    public var revokedSenderIDs: Set<String>
    /// Raw value of the app's AgentNotificationPolicy, so the extension
    /// applies the same filter as the foreground router.
    public var agentPolicy: String

    public init(enabled: Bool = true, deviceID: String?, revokedSenderIDs: Set<String> = [], agentPolicy: String = "blockedOnly") {
        self.enabled = enabled; self.deviceID = deviceID; self.revokedSenderIDs = revokedSenderIDs; self.agentPolicy = agentPolicy
    }

    // Older policy files lack the newer keys; missing fields must not turn
    // a restrictive policy permissive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        revokedSenderIDs = try c.decodeIfPresent(Set<String>.self, forKey: .revokedSenderIDs) ?? []
        agentPolicy = try c.decodeIfPresent(String.self, forKey: .agentPolicy) ?? "blockedOnly"
    }

    public func accepts(_ envelope: PushEnvelope) -> Bool {
        guard enabled else { return false }
        if let did = envelope.did, let mine = deviceID, did != mine { return false }
        if let sid = envelope.sid, revokedSenderIDs.contains(sid) { return false }
        return true
    }

    /// Whether an agent event with this status should be shown.
    public func allowsAgentStatus(_ status: String?) -> Bool {
        switch agentPolicy {
        case "off": return false
        case "blockedOnly": return status == "blocked"
        case "blockedAndDone": return status == "blocked" || status == "done" || status == "failed"
        default: return true
        }
    }
}

public struct PushSharedState: Sendable {
    public static let maxRecords = 200
    public static let retention: TimeInterval = 48 * 3600

    let eventsURL: URL?
    let policyURL: URL?

    public init(appGroup: String = PushConfiguration.appGroup) {
        self.init(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))
    }

    public init(container: URL?) {
        eventsURL = container?.appendingPathComponent("push-events.json")
        policyURL = container?.appendingPathComponent("push-policy.json")
    }

    public func load() -> [PushEventRecord] {
        guard let eventsURL, let data = try? Data(contentsOf: eventsURL),
              let records = try? JSONDecoder().decode([PushEventRecord].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return records.filter { $0.receivedAt > cutoff }
    }

    /// Records `record` unless its event id was already seen. The check and
    /// the write happen under file coordination so the app and the extension
    /// cannot both claim a replayed push. Returns false only for a confirmed
    /// duplicate; storage failures never suppress a notification.
    public func claim(_ record: PushEventRecord) -> Bool {
        guard let eventsURL else { return true }
        var duplicate = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: eventsURL, options: [], error: &coordinationError) { url in
            var records = load()
            if records.contains(where: { $0.eid == record.eid }) {
                duplicate = true
                return
            }
            records.append(record)
            if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return !duplicate
    }

    /// Undoes a claim whose notification could not be scheduled, so a retry
    /// of the same event is not mistaken for a replay.
    public func release(eid: String) {
        guard let eventsURL else { return }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: eventsURL, options: [], error: &coordinationError) { url in
            let records = load().filter { $0.eid != eid }
            if let data = try? JSONEncoder().encode(records) {
                try? data.write(to: url, options: .atomic)
            }
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
