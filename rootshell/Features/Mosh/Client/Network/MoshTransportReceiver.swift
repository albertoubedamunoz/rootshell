//
//  InboundAssembler.swift
//  rootshell
//

import Foundation
import OSLog

// Work around a Swift 6.2.4/Xcode 26.3 release-optimizer crash in the
// synthesized class deinit for this generic type by keeping it as a value type.
@MainActor
struct InboundAssembler<RemoteState: MoshSyncableState> {

    /// Logger
    private nonisolated static var logger: Logger {
        Logger(subsystem: "com.kk2.rootshell", category: "InboundAssembler")
    }

    private var assembledVersions: [VersionedSnapshot<RemoteState>]
    private var versionIndex: [UInt64: VersionedSnapshot<RemoteState>] = [:]
    private var rateLimitResumeTime: UInt64 = 0
    private var lastRenderedState: RemoteState

    /// Counter for consecutive packets dropped due to missing base state
    private var consecutiveDropCount: Int = 0

    /// Threshold for triggering state desync error
    private let desyncDropLimit = 10

    init(initialRemote: RemoteState) {
        let now = ProtocolTiming.monotonicNowMs()
        let initial = VersionedSnapshot(capturedAt: now, version: 0, state: initialRemote.copy())
        self.assembledVersions = [initial]
        self.versionIndex = [0: initial]
        self.lastRenderedState = initialRemote.copy()
    }

    /// Creates assembler with resume state
    init(initialRemote: RemoteState, startingStateNum: UInt64) {
        let now = ProtocolTiming.monotonicNowMs()
        let initial = VersionedSnapshot(capturedAt: now, version: startingStateNum, state: initialRemote.copy())
        self.assembledVersions = [initial]
        self.versionIndex = [startingStateNum: initial]
        self.lastRenderedState = initialRemote.copy()
    }

    var latestRemoteState: RemoteState {
        assembledVersions.last!.state
    }

    func getLatestRemoteTimestamp() -> UInt64 {
        assembledVersions.last?.capturedAt ?? 0
    }

    var latestRemoteVersion: UInt64 {
        assembledVersions.last?.version ?? 0
    }

    mutating func processPacket<LocalState: MoshSyncableState>(
        _ packet: MoshPacket,
        synchronizer: inout OutboundSynchronizer<LocalState>
    ) throws {
        guard !packet.payload.isEmpty else { return }
        let decompressed = try MoshProtocolCompression.zlibDecompress(packet.payload)
        let inst = try TransportInstruction.deserialize(decompressed)
        if inst.protocolVersion != 2 {
            throw MoshError.invalidPacketFormat(reason: "mosh protocol version mismatch")
        }

        synchronizer.applyPeerAcknowledgment(through: inst.ackNum)

        // O(1) lookup via dictionary
        if versionIndex[inst.newNum] != nil {
            return
        }

        guard let referenceState = versionIndex[inst.oldNum]?.state.copy() else {
            let knownStates = Array(versionIndex.keys)
            Self.logger.warning("Cannot find base state \(inst.oldNum) for instruction (have: \(knownStates))")

            self.consecutiveDropCount += 1

            let ourMaxState = assembledVersions.max(by: { $0.version < $1.version })?.version ?? 0
            if inst.throwawayNum > ourMaxState {
                Self.logger.error("UNRECOVERABLE STATE GAP: server throwawayNum=\(inst.throwawayNum) > our maxState=\(ourMaxState)")
                throw MoshError.stateDesync(
                    reason: "Server has discarded states we need (server oldest: \(inst.throwawayNum), our newest: \(ourMaxState))"
                )
            }

            if self.consecutiveDropCount >= self.desyncDropLimit {
                let droppedCount = self.consecutiveDropCount
                Self.logger.error("STATE DESYNC: dropped \(droppedCount) consecutive packets")
                throw MoshError.stateDesync(
                    reason: "Dropped \(droppedCount) consecutive packets due to missing base state"
                )
            }

            return
        }

        self.consecutiveDropCount = 0

        pruneVersionsBefore(inst.throwawayNum)

        if assembledVersions.count > 1024 {
            let now = ProtocolTiming.monotonicNowMs()
            if now < rateLimitResumeTime {
                return
            } else {
                rateLimitResumeTime = now + 15000
            }
        }

        if !inst.diff.isEmpty {
            referenceState.applyDelta(inst.diff)
        }
        let newSnapshot = VersionedSnapshot(capturedAt: ProtocolTiming.monotonicNowMs(), version: inst.newNum, state: referenceState)

        versionIndex[newSnapshot.version] = newSnapshot

        var inserted = false
        for i in 0..<assembledVersions.count {
            if assembledVersions[i].version > newSnapshot.version {
                assembledVersions.insert(newSnapshot, at: i)
                inserted = true
                break
            }
        }
        if !inserted {
            assembledVersions.append(newSnapshot)
        }

        synchronizer.updatePeerStateVersion(assembledVersions.last!.version)
        synchronizer.recordPeerResponse(at: newSnapshot.capturedAt)
        if !inst.diff.isEmpty {
            synchronizer.markAcknowledgmentPending()
        }
    }

    mutating func consumeAccumulatedDelta() -> Data {
        let diff = assembledVersions.last!.state.encodeDelta(since: lastRenderedState)
        let oldest = assembledVersions.first!.state
        for index in assembledVersions.indices.reversed() {
            assembledVersions[index].state.pruneAcknowledged(oldest)
        }
        lastRenderedState = assembledVersions.last!.state.copy()
        return diff
    }

    private mutating func pruneVersionsBefore(_ throwawayNum: UInt64) {
        for snapshot in assembledVersions where snapshot.version < throwawayNum {
            versionIndex.removeValue(forKey: snapshot.version)
        }
        assembledVersions.removeAll { $0.version < throwawayNum }
        if assembledVersions.isEmpty {
            fatalError("assembledVersions should never be empty")
        }
    }
}
