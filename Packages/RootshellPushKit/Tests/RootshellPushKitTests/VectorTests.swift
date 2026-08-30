import Foundation
import XCTest
@testable import RootshellPushKit

/// Cross-implementation vectors produced by `go test ./envelope -update`.
struct Vectors: Decodable {
    struct Case: Decodable {
        let name: String
        let eid: String
        let header: PushHeader
        let envelope: PushEnvelope
    }
    let seed: Data
    let public_key: Data
    let info: String
    let cases: [Case]
    let pairing: String

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: repoRoot.appendingPathComponent("push/envelope/testdata/vectors.json")))
    }
}

final class VectorTests: XCTestCase {
    func testPublicKeyDerivationMatchesGo() throws {
        let v = try Vectors.load()
        let sk = try XWing.PrivateKey(seed: v.seed)
        XCTAssertEqual(sk.publicKey.rawRepresentation, v.public_key)
        XCTAssertEqual(v.info, String(decoding: PushProtocol.info, as: UTF8.self))
    }

    func testOpenGoEnvelopes() throws {
        let v = try Vectors.load()
        let sk = try XWing.PrivateKey(seed: v.seed)
        for c in v.cases {
            XCTAssertEqual(try c.envelope.open(with: sk), c.header, c.name)
        }
    }

    func testOpenRejectsTampering() throws {
        let v = try Vectors.load()
        let sk = try XWing.PrivateKey(seed: v.seed)
        var env = v.cases[0].envelope
        env.eid = "other"
        XCTAssertThrowsError(try env.open(with: sk))
        env = v.cases[0].envelope
        var ct = Data(base64URL: env.ct)!
        ct[0] ^= 1
        env.ct = ct.base64URLEncodedString()
        XCTAssertThrowsError(try env.open(with: sk))
        XCTAssertThrowsError(try v.cases[0].envelope.open(with: try XWing.PrivateKey()))
    }

    func testPairingBundle() throws {
        let v = try Vectors.load()
        let p = try PairingBundle(encoded: v.pairing)
        XCTAssertEqual(p.publicKey, v.public_key)
        XCTAssertEqual(p.senderCred, "rsc1.test")
        XCTAssertEqual(try PairingBundle(encoded: p.encoded()), p)
        XCTAssertThrowsError(try PairingBundle(server: "https://x", label: nil, senderCred: "rss_old", publicKey: p.publicKey).encoded())
    }

    func testAcceptancePolicy() {
        let env = PushEnvelope(v: 1, enc: "", ct: "", eid: "e", sid: "snd_1", did: "dev_1")
        XCTAssertTrue(PushAcceptancePolicy(deviceID: "dev_1").accepts(env))
        XCTAssertTrue(PushAcceptancePolicy(deviceID: nil).accepts(env))
        XCTAssertFalse(PushAcceptancePolicy(deviceID: "dev_2").accepts(env))
        XCTAssertFalse(PushAcceptancePolicy(deviceID: "dev_1", revokedSenderIDs: ["snd_1"]).accepts(env))
        XCTAssertFalse(PushAcceptancePolicy(enabled: false, deviceID: "dev_1").accepts(env))
        let blockedOnly = PushAcceptancePolicy(deviceID: "dev_1", agentPolicy: "blockedOnly")
        XCTAssertTrue(blockedOnly.allowsAgentStatus("blocked"))
        XCTAssertFalse(blockedOnly.allowsAgentStatus("done"))
        XCTAssertTrue(PushAcceptancePolicy(deviceID: "dev_1", agentPolicy: "blockedAndDone").allowsAgentStatus("done"))
        XCTAssertFalse(PushAcceptancePolicy(deviceID: "dev_1", agentPolicy: "off").allowsAgentStatus("blocked"))
    }

    func testClaimRejectsDuplicateEventIDs() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = PushSharedState(container: dir)
        let record = PushEventRecord(eid: "e1", status: nil, agent: nil, thread: nil, route: nil)
        XCTAssertTrue(state.claim(record))
        XCTAssertFalse(state.claim(record))
        XCTAssertTrue(state.claim(PushEventRecord(eid: "e2", status: nil, agent: nil, thread: nil, route: nil)))
        XCTAssertEqual(state.load().map(\.eid), ["e1", "e2"])
        state.release(eid: "e1")
        XCTAssertTrue(state.claim(record))
        // No container at all: never suppresses.
        XCTAssertTrue(PushSharedState(container: nil).claim(record))
    }

    func testPolicyDecodesOlderFiles() throws {
        let old = Data(#"{"deviceID":"dev_1","revokedSenderIDs":["snd_9"]}"#.utf8)
        let policy = try JSONDecoder().decode(PushAcceptancePolicy.self, from: old)
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.deviceID, "dev_1")
        XCTAssertEqual(policy.revokedSenderIDs, ["snd_9"])
        XCTAssertEqual(policy.agentPolicy, "blockedOnly")
    }

    func testSwiftSealRoundTrip() throws {
        let sk = try XWing.PrivateKey()
        let header = PushHeader(kind: "agent", agent: "codex", status: "blocked", title: "Codex · app", body: "Needs approval",
                                route: PushRoute(pane: UUID().uuidString, tmuxPane: "%4",
                                                 tmuxServer: "dev:/tmp/tmux-1000/default,42,1700000000"))
        let env = try PushEnvelope.seal(header, eid: "evt-swift-1", to: sk.publicKey)
        try env.validate()
        XCTAssertEqual(try env.open(with: sk), header)
        XCTAssertLessThan(try JSONEncoder().encode(env).count, 4096 - 300)
    }

    /// Writes Swift-produced envelopes for the Go side (`go test ./envelope -run TestSwiftVectors`).
    /// Set PUSH_WRITE_SWIFT_VECTORS=1.
    func testWriteSwiftVectorsForGo() throws {
        guard ProcessInfo.processInfo.environment["PUSH_WRITE_SWIFT_VECTORS"] == "1" else { return }
        let v = try Vectors.load()
        let pk = try XWing.PublicKey(rawRepresentation: v.public_key)
        var out: [[String: Any]] = []
        for c in v.cases {
            let env = try PushEnvelope.seal(c.header, eid: c.eid, to: pk)
            out.append(["name": c.name, "eid": c.eid, "envelope": ["v": env.v, "enc": env.enc, "ct": env.ct, "eid": env.eid]])
        }
        try JSONSerialization.data(withJSONObject: ["cases": out], options: [.prettyPrinted, .sortedKeys])
            .write(to: Vectors.repoRoot.appendingPathComponent("push/envelope/testdata/swift-vectors.json"))
    }
}
