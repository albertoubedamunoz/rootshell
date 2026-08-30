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

    public init(enabled: Bool = true, deviceID: String?, revokedSenderIDs: Set<String> = []) {
        self.enabled = enabled; self.deviceID = deviceID; self.revokedSenderIDs = revokedSenderIDs
    }

    // Older policy files lack the newer keys; missing fields must not turn
    // a restrictive policy permissive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        revokedSenderIDs = try c.decodeIfPresent(Set<String>.self, forKey: .revokedSenderIDs) ?? []
    }

    /// The extension cannot drop a notification, only blank it, so this is
    /// deliberately limited to identity checks; what a sender pushes is shown.
    public func accepts(_ envelope: PushEnvelope) -> Bool {
        guard enabled else { return false }
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
    let claimsURL: URL?

    public init(appGroup: String = PushConfiguration.appGroup) {
        self.init(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup))
    }

    public init(container: URL?) {
        eventsURL = container?.appendingPathComponent("push-events.json")
        policyURL = container?.appendingPathComponent("push-policy.json")
        claimsURL = container?.appendingPathComponent("push-claims", isDirectory: true)
    }

    public func load() -> [PushEventRecord] {
        guard let eventsURL, let data = try? Data(contentsOf: eventsURL),
              let records = try? JSONDecoder().decode([PushEventRecord].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        return records.filter { $0.receivedAt > cutoff }
    }

    /// Records `record` unless its event id was already seen. The claim is an
    /// exclusive-create marker file, atomic across the app and the extension
    /// without file coordination (which can block the extension while the app
    /// is suspended). Returns false only for a confirmed duplicate; storage
    /// failures never suppress a notification.
    public func claim(_ record: PushEventRecord) -> Bool {
        guard let eventsURL, let claimsURL, PushProtocol.isValidEventID(record.eid) else { return true }
        try? FileManager.default.createDirectory(at: claimsURL, withIntermediateDirectories: true)
        pruneClaims()
        let fd = open(claimsURL.appendingPathComponent(record.eid).path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd < 0 {
            return errno != EEXIST
        }
        close(fd)

        var records = load()
        records.removeAll { $0.eid == record.eid }
        records.append(record)
        if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: eventsURL, options: .atomic)
        }
        return true
    }

    /// Undoes a claim whose notification could not be scheduled, so a retry
    /// of the same event is not mistaken for a replay.
    public func release(eid: String) {
        guard let eventsURL, let claimsURL else { return }
        try? FileManager.default.removeItem(at: claimsURL.appendingPathComponent(eid))
        let records = load().filter { $0.eid != eid }
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: eventsURL, options: .atomic)
        }
    }

    private func pruneClaims() {
        guard let claimsURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: claimsURL, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
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
        if let claimsURL { try? FileManager.default.removeItem(at: claimsURL) }
    }
}
