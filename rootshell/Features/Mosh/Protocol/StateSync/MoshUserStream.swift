//
//  MoshUserStream.swift
//  rootshell
//
//  Client → Server user input stream for mosh
//

import Foundation

/// Manages client → server state (user input)
///
/// Tracks:
/// - Keystrokes and resize events (as a stream of actions)
/// - Sent state numbers and timestamps
/// - Assumed receiver state for diffing
///
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshStateSync which is @MainActor.
@MainActor
final class MoshUserStream {

    // MARK: - Types

    enum UserEvent: Sendable {
        case userByte(UInt8)
        case resize(width: UInt32, height: UInt32)
    }

    struct SentState: Sendable {
        let num: UInt64
        let actionIndex: Int
        let timestampMs: UInt64
    }

    // MARK: - State

    private var actions: [UserEvent] = []
    private var baseActionIndex: Int = 0
    private var totalActionCount: Int = 0

    private var sentStates: [SentState] = [
        SentState(num: 0, actionIndex: 0, timestampMs: ProtocolTiming.monotonicNowMs())
    ]
    private var assumedReceiverIndex: Int = 0
    private var currentStateNum: UInt64 = 0

    // MARK: - Initialization

    init() {}

    // MARK: - Input Handling

    func addKeystroke(_ data: Data) {
        for byte in data {
            actions.append(.userByte(byte))
            totalActionCount += 1
        }
    }

    func addResize(width: UInt32, height: UInt32) {
        actions.append(.resize(width: width, height: height))
        totalActionCount += 1
    }

    // MARK: - State Queries

    var hasNewActions: Bool {
        totalActionCount > (sentStates.last?.actionIndex ?? 0)
    }

    var currentActionIndex: Int {
        totalActionCount
    }

    var assumedReceiverActionIndex: Int {
        sentStates[assumedReceiverIndex].actionIndex
    }

    var assumedReceiverStateNum: UInt64 {
        sentStates[assumedReceiverIndex].num
    }

    var oldestStateNum: UInt64 {
        sentStates.first?.num ?? 0
    }

    var oldestActionIndex: Int {
        sentStates.first?.actionIndex ?? 0
    }

    var lastSentTimestampMs: UInt64 {
        sentStates.last?.timestampMs ?? 0
    }

    var isAssumedReceiverAtOldest: Bool {
        assumedReceiverIndex == 0
    }

    // MARK: - Diff Generation

    func diffFromAssumedReceiver() throws -> Data {
        try serializeDiff(fromActionIndex: assumedReceiverActionIndex)
    }

    func diff(fromActionIndex: Int) throws -> Data {
        try serializeDiff(fromActionIndex: fromActionIndex)
    }

    private func serializeDiff(fromActionIndex: Int) throws -> Data {
        guard fromActionIndex <= totalActionCount else { return Data() }
        let start = fromActionIndex - baseActionIndex
        guard start >= 0 else { return Data() }
        guard start <= actions.count else { return Data() }

        var message = UserMessage()
        var keystrokeBuffer = Data()

        func flushKeystroke() {
            guard !keystrokeBuffer.isEmpty else { return }
            message.instructions.append(.keystroke(keystrokeBuffer))
            keystrokeBuffer.removeAll(keepingCapacity: true)
        }

        for action in actions[start..<actions.count] {
            switch action {
            case .userByte(let byte):
                keystrokeBuffer.append(byte)
            case .resize(let width, let height):
                flushKeystroke()
                message.instructions.append(.resize(width: width, height: height))
            }
        }

        flushKeystroke()
        return try message.serialize()
    }

    // MARK: - Sent State Management

    func recordSentState(nowMs: UInt64) -> SentState {
        currentStateNum += 1
        let state = SentState(
            num: currentStateNum,
            actionIndex: totalActionCount,
            timestampMs: nowMs
        )
        sentStates.append(state)
        return state
    }

    func assumeReceiverHasLatest() {
        assumedReceiverIndex = max(0, sentStates.count - 1)
    }

    func setAssumedReceiverToOldest() {
        assumedReceiverIndex = 0
    }

    func updateAssumedReceiverState(nowMs: UInt64, timeoutMs: UInt64) {
        assumedReceiverIndex = 0

        for index in 1..<sentStates.count {
            let state = sentStates[index]
            if nowMs >= state.timestampMs,
               nowMs - state.timestampMs < timeoutMs + ProtocolTiming.acknowledgmentGraceMs {
                assumedReceiverIndex = index
            } else {
                break
            }
        }
    }

    func processAck(_ ackNum: UInt64) {
        guard let ackIndex = sentStates.firstIndex(where: { $0.num == ackNum }) else {
            return
        }

        if ackIndex > 0 {
            sentStates.removeFirst(ackIndex)
            assumedReceiverIndex = max(0, assumedReceiverIndex - ackIndex)
        }

        let ackedActionIndex = sentStates.first?.actionIndex ?? 0
        dropActionsBefore(ackedActionIndex)
    }

    private func dropActionsBefore(_ absoluteIndex: Int) {
        let dropCount = min(actions.count, max(0, absoluteIndex - baseActionIndex))
        guard dropCount > 0 else { return }
        actions.removeFirst(dropCount)
        baseActionIndex += dropCount
    }

    // MARK: - Reset

    func reset() {
        actions.removeAll()
        baseActionIndex = 0
        totalActionCount = 0
        sentStates = [
            SentState(num: 0, actionIndex: 0, timestampMs: ProtocolTiming.monotonicNowMs())
        ]
        assumedReceiverIndex = 0
        currentStateNum = 0
    }
}
