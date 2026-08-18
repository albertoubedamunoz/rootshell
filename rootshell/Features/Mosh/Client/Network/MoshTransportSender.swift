//
//  OutboundSynchronizer.swift
//  rootshell
//

import Foundation
import OSLog

// Work around a Swift 6.2.4/Xcode 26.3 release-optimizer crash in the
// synthesized class deinit for this generic type by keeping it as a value type.
@MainActor
struct OutboundSynchronizer<State: MoshSyncableState> {

    /// Logger
    private nonisolated static var logger: Logger {
        Logger(subsystem: "com.kk2.rootshell", category: "OutboundSynchronizer")
    }

    private enum Limits {
        static var maxVersionHistorySize: Int { 32 }
        static var pruneKeepRecentCount: Int { 16 }
        static var fullResendByteThreshold: Int { 1000 }
        static var fullResendOverheadTolerance: Int { 100 }
        static var initialMinimumTransmitGapMs: UInt64 { 8 }
    }

    /// Classifies why the synchronizer needs to transmit, used to compute
    /// the appropriate send deadline for each situation.
    private enum TransmitUrgency {
        /// Local state has changed since last transmission
        case newStateReady
        /// Peer hasn't confirmed the most recently sent state
        case retransmitNeeded
        /// Confirmed base differs from current state (awaiting round-trip)
        case awaitingAck
        /// Nothing to send
        case idle
    }

    private let transport: MoshTransport
    private var currentState: State
    private var versionHistory: [VersionedSnapshot<State>]
    private var estimatedPeerIndex: Int

    private var nextHeartbeatDeadline: UInt64
    private var nextTransmitDeadline: UInt64

    private var isShuttingDown = false
    private var shutdownAttemptCount = 0
    private var shutdownStart: UInt64 = 0

    private var peerStateVersion: UInt64 = 0
    private var hasPendingAcknowledgment = false
    private var lastAckSent: UInt64 = 0

    private var minimumTransmitGap: UInt64 = Limits.initialMinimumTransmitGapMs
    private var lastPeerResponseAt: UInt64 = 0

    private var gapTimerStart: UInt64 = UInt64.max

    /// Cached transmit interval for hot path access (avoids async RTT fetch)
    /// Initial value: SRTT=1000 → transmitInterval=250
    private var transmitInterval: UInt64 = ProtocolTiming.maximumTransmitIntervalMs

    init(transport: MoshTransport, initialState: State) {
        self.transport = transport
        self.currentState = initialState.copy()
        let now = ProtocolTiming.monotonicNowMs()
        self.versionHistory = [VersionedSnapshot(capturedAt: now, version: 0, state: initialState.copy())]
        self.estimatedPeerIndex = 0
        self.nextHeartbeatDeadline = now
        self.nextTransmitDeadline = now
    }

    /// Creates synchronizer with resume state
    init(transport: MoshTransport, initialState: State, startingStateNum: UInt64) {
        self.transport = transport
        self.currentState = initialState.copy()
        let now = ProtocolTiming.monotonicNowMs()
        self.versionHistory = [VersionedSnapshot(capturedAt: now, version: startingStateNum, state: initialState.copy())]
        self.estimatedPeerIndex = 0
        self.nextHeartbeatDeadline = now
        self.nextTransmitDeadline = now
    }

    // MARK: - State Access (for resume persistence)

    var currentStateNum: UInt64 {
        versionHistory.last?.version ?? 0
    }

    var assumedReceiverStateNum: UInt64 {
        guard estimatedPeerIndex < versionHistory.count else { return 0 }
        return versionHistory[estimatedPeerIndex].version
    }

    mutating func performCycle() {
        recalculateDeadlines()
        guard transport.canSend else { return }

        let now = ProtocolTiming.monotonicNowMs()
        guard now >= nextHeartbeatDeadline || now >= nextTransmitDeadline else { return }

        let diff = generateOptimalDiff()

        if diff.isEmpty {
            if now >= nextHeartbeatDeadline {
                emitPacket(diff: Data())
            }
            if now >= nextTransmitDeadline {
                nextTransmitDeadline = UInt64.max
            }
            gapTimerStart = UInt64.max
            return
        }

        emitPacket(diff: diff)
        gapTimerStart = UInt64.max
    }

    mutating func nextWakeInterval() -> UInt64 {
        recalculateDeadlines()
        if !transport.canSend { return UInt64.max }
        let nextWake = min(nextHeartbeatDeadline, nextTransmitDeadline)
        let now = ProtocolTiming.monotonicNowMs()
        if nextWake > now {
            return nextWake - now
        }
        return 0
    }

    mutating func applyPeerAcknowledgment(through ackVersion: UInt64) {
        guard let index = versionHistory.firstIndex(where: { $0.version == ackVersion }) else { return }
        versionHistory.removeAll { $0.version < ackVersion }
        estimatedPeerIndex = max(0, estimatedPeerIndex - index)
        if estimatedPeerIndex >= versionHistory.count {
            estimatedPeerIndex = max(0, versionHistory.count - 1)
        }
    }

    mutating func updatePeerStateVersion(_ value: UInt64) {
        peerStateVersion = value
    }

    mutating func markAcknowledgmentPending() {
        hasPendingAcknowledgment = true
    }

    /// Requests an immediate ack/keepalive send on the next tick.
    mutating func requestImmediateAck() {
        let now = ProtocolTiming.monotonicNowMs()
        hasPendingAcknowledgment = true
        nextHeartbeatDeadline = now
        if nextTransmitDeadline > now {
            nextTransmitDeadline = now
        }
    }

    mutating func recordPeerResponse(at ts: UInt64) {
        lastPeerResponseAt = ts
    }

    mutating func initiateGracefulClose() {
        if !isShuttingDown {
            shutdownStart = ProtocolTiming.monotonicNowMs()
            isShuttingDown = true
        }
    }

    func getShutdownInProgress() -> Bool { isShuttingDown }
    func getShutdownAcknowledged() -> Bool { versionHistory.first?.version == UInt64.max }
    func getCounterpartyShutdownAcknowledged() -> Bool { lastAckSent == UInt64.max }

    func getSentStateAckedTimestamp() -> UInt64 { versionHistory.first?.capturedAt ?? 0 }
    func getSentStateAcked() -> UInt64 { versionHistory.first?.version ?? 0 }
    func getSentStateLast() -> UInt64 { versionHistory.last?.version ?? 0 }

    mutating func setMinimumTransmitGap(_ delayMs: UInt64) {
        minimumTransmitGap = delayMs
    }

    /// Returns the cached transmit interval (synchronous, for hot path)
    func getTransmitInterval() -> UInt64 {
        return transmitInterval
    }

    /// Fetches RTT and updates the cached transmit interval
    mutating func recalculateTransmitInterval() -> UInt64 {
        let srtt = transport.rttEstimator.estimatedRTT
        var interval = UInt64(ceil(srtt / 2.0))
        interval = max(interval, ProtocolTiming.minimumTransmitIntervalMs)
        interval = min(interval, ProtocolTiming.maximumTransmitIntervalMs)
        transmitInterval = interval
        return interval
    }

    /// Updates the cached transmit interval from an externally-fetched RTT value
    mutating func updateTransmitInterval(fromRTT srtt: Double) {
        var interval = UInt64(ceil(srtt / 2.0))
        interval = max(interval, ProtocolTiming.minimumTransmitIntervalMs)
        interval = min(interval, ProtocolTiming.maximumTransmitIntervalMs)
        transmitInterval = interval
    }

    var hasCloseTimedOut: Bool {
        guard isShuttingDown else { return false }
        return shutdownAttemptCount >= ProtocolTiming.maxCloseAttempts
            || ProtocolTiming.monotonicNowMs() - shutdownStart >= ProtocolTiming.activeRetransmitWindowMs
    }

    func getCurrentState() -> State {
        return currentState
    }

    mutating func setCurrentState(_ state: State) {
        guard !isShuttingDown else { return }
        currentState = state.copy()
        currentState.resetParser()
    }

    // MARK: - Deadline Scheduling

    private mutating func recalculateDeadlines() {
        let now = ProtocolTiming.monotonicNowMs()
        let timeout = UInt64(transport.rttEstimator.retransmissionTimeout)
        let interval = self.getTransmitInterval()
        estimatePeerProgress(at: now, retransmitTimeout: timeout)
        normalizeVersionHistory()

        if hasPendingAcknowledgment && nextHeartbeatDeadline > now + ProtocolTiming.acknowledgmentGraceMs {
            nextHeartbeatDeadline = now + ProtocolTiming.acknowledgmentGraceMs
        }

        let urgency = classifyTransmitUrgency(at: now)
        nextTransmitDeadline = computeTransmitDeadline(
            for: urgency, interval: interval, timeout: timeout, now: now
        )

        if isShuttingDown || peerStateVersion == UInt64.max {
            nextHeartbeatDeadline = versionHistory.last!.capturedAt + interval
        }
    }

    /// Determines the synchronization urgency based on how the current local
    /// state relates to the confirmed, estimated-peer, and last-sent states.
    private func classifyTransmitUrgency(at now: UInt64) -> TransmitUrgency {
        let peerRecentlyActive = lastPeerResponseAt + ProtocolTiming.activeRetransmitWindowMs > now

        if currentState != versionHistory.last!.state {
            return .newStateReady
        }
        if currentState != versionHistory[estimatedPeerIndex].state && peerRecentlyActive {
            return .retransmitNeeded
        }
        if currentState != versionHistory.first!.state && peerRecentlyActive {
            return .awaitingAck
        }
        return .idle
    }

    /// Maps a transmit urgency level to the earliest time we should send.
    private mutating func computeTransmitDeadline(
        for urgency: TransmitUrgency,
        interval: UInt64,
        timeout: UInt64,
        now: UInt64
    ) -> UInt64 {
        switch urgency {
        case .newStateReady:
            if gapTimerStart == UInt64.max { gapTimerStart = now }
            return max(gapTimerStart + minimumTransmitGap, versionHistory.last!.capturedAt + interval)

        case .retransmitNeeded:
            var deadline = versionHistory.last!.capturedAt + interval
            if gapTimerStart != UInt64.max {
                deadline = max(deadline, gapTimerStart + minimumTransmitGap)
            }
            return deadline

        case .awaitingAck:
            return versionHistory.last!.capturedAt + timeout + ProtocolTiming.acknowledgmentGraceMs

        case .idle:
            return UInt64.max
        }
    }

    // MARK: - Peer State Estimation

    /// Scans sent snapshots in chronological order, advancing the peer estimate
    /// as long as each snapshot was transmitted recently enough to have plausibly
    /// been delivered. Stops at the first snapshot outside the delivery window.
    private mutating func estimatePeerProgress(at now: UInt64, retransmitTimeout timeout: UInt64) {
        let deliveryWindow = timeout + ProtocolTiming.acknowledgmentGraceMs
        estimatedPeerIndex = 0
        for i in versionHistory.indices.dropFirst() {
            guard now >= versionHistory[i].capturedAt,
                  now - versionHistory[i].capturedAt < deliveryWindow else { break }
            estimatedPeerIndex = i
        }
    }

    private mutating func normalizeVersionHistory() {
        let confirmedBase = versionHistory[0].state
        currentState.pruneAcknowledged(confirmedBase)
        // Prune non-base entries first; the base is a reference type whose
        // identity-equal path clears its contents, so it must go last.
        for i in 1..<versionHistory.count {
            versionHistory[i].state.pruneAcknowledged(confirmedBase)
        }
        versionHistory[0].state.pruneAcknowledged(confirmedBase)
    }

    // MARK: - Diff Generation

    /// Computes the state diff to transmit, selecting between an incremental
    /// diff (from the estimated peer state) and a full resend (from the
    /// confirmed base) based on which produces a smaller payload.
    private mutating func generateOptimalDiff() -> Data {
        let incrementalDiff = currentState.encodeDelta(since: versionHistory[estimatedPeerIndex].state)

        // If already diffing from the confirmed base, there's no alternative
        guard estimatedPeerIndex > 0 else { return incrementalDiff }

        // Evaluate whether a full resend from the confirmed base would be
        // more efficient than the incremental diff
        let fullResendDiff = currentState.encodeDelta(since: versionHistory.first!.state)
        if shouldPreferFullResend(fullResendSize: fullResendDiff.count, incrementalSize: incrementalDiff.count) {
            estimatedPeerIndex = 0
            return fullResendDiff
        }
        return incrementalDiff
    }

    /// Heuristic: prefer the full resend if it's no larger, or if both are
    /// small enough that the overhead is negligible.
    private func shouldPreferFullResend(fullResendSize: Int, incrementalSize: Int) -> Bool {
        fullResendSize <= incrementalSize
            || (fullResendSize < Limits.fullResendByteThreshold
                && fullResendSize - incrementalSize < Limits.fullResendOverheadTolerance)
    }

    // MARK: - Packet Emission

    /// Sends a single packet containing the given diff (empty for heartbeat/ack).
    /// Handles version assignment, snapshot recording, and deadline reset.
    private mutating func emitPacket(diff: Data) {
        let now = ProtocolTiming.monotonicNowMs()
        let isDelta = !diff.isEmpty
        let newVersion = resolveNextVersion(isDelta: isDelta)

        // For a retransmission of an unchanged state, just refresh the timestamp.
        // Otherwise record a new snapshot in the version history.
        if isDelta && newVersion == versionHistory.last!.version {
            versionHistory[versionHistory.count - 1].capturedAt = now
        } else {
            appendSnapshot(capturedAt: now, version: newVersion, state: currentState)
        }

        serializeAndTransmit(delta: diff, version: newVersion)

        if isDelta {
            estimatedPeerIndex = max(0, versionHistory.count - 1)
        }

        nextHeartbeatDeadline = now + ProtocolTiming.heartbeatIntervalMs
        nextTransmitDeadline = UInt64.max
    }

    /// Determines the version number for the next outgoing packet.
    private func resolveNextVersion(isDelta: Bool) -> UInt64 {
        if isShuttingDown || versionHistory.last!.version == UInt64.max {
            return UInt64.max
        }
        // When retransmitting an unchanged state, reuse the existing version
        if isDelta && currentState == versionHistory.last!.state {
            return versionHistory.last!.version
        }
        return versionHistory.last!.version + 1
    }

    // MARK: - Version History Management

    private mutating func appendSnapshot(capturedAt: UInt64, version: UInt64, state: State) {
        versionHistory.append(VersionedSnapshot(capturedAt: capturedAt, version: version, state: state.copy()))
        pruneVersionHistory()
    }

    /// Keeps the version history bounded by evicting the oldest entry outside
    /// the recent transmission window while preserving the confirmed base.
    private mutating func pruneVersionHistory() {
        while versionHistory.count > Limits.maxVersionHistorySize {
            let recentWindowStart = versionHistory.count - Limits.pruneKeepRecentCount
            let evictionIndex = max(recentWindowStart, 1)
            guard evictionIndex < versionHistory.count else { break }
            versionHistory.remove(at: evictionIndex)
        }
    }

    // MARK: - Wire Serialization

    private func generatePadding() -> Data {
        let len = Int.random(in: 0...ProtocolTiming.maxPaddingBytes)
        if len == 0 { return Data() }
        var bytes = [UInt8]()
        bytes.reserveCapacity(len)
        for _ in 0..<len { bytes.append(UInt8.random(in: 0...UInt8.max)) }
        return Data(bytes)
    }

    private mutating func serializeAndTransmit(delta: Data, version: UInt64) {
        var inst = TransportInstruction()
        inst.protocolVersion = 2
        inst.oldNum = versionHistory[estimatedPeerIndex].version
        inst.newNum = version
        inst.ackNum = peerStateVersion
        inst.throwawayNum = versionHistory.first!.version
        inst.diff = delta
        inst.chaff = generatePadding()

        if version == UInt64.max { shutdownAttemptCount += 1 }

        if let serialized = try? inst.serialize() {
            if let compressed = try? MoshProtocolCompression.zlibCompress(serialized) {
                try? transport.send(compressed)
                lastAckSent = peerStateVersion
            }
        }
        hasPendingAcknowledgment = false
    }
}
