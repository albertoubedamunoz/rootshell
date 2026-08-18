//
//  MoshTerminalState.swift
//  rootshell
//
//  Server → Client terminal state for mosh
//

import Foundation
import OSLog

/// Manages server → client terminal state
///
/// Tracks:
/// - Server state numbers
/// - Terminal output from server
/// - Echo acknowledgments for predictions
///
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshStateSync which is @MainActor.
@MainActor
final class MoshTerminalState {

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshTerminalState"
    )

    // MARK: - State

    /// Current server state number
    private var currentStateNum: UInt64 = 0

    /// Client's acknowledged server state number
    private var ackedStateNum: UInt64 = 0

    /// Last received echo acknowledgment
    private var lastEchoAck: UInt64 = 0

    /// Terminal dimensions
    private var terminalWidth: UInt32 = 80
    private var terminalHeight: UInt32 = 24

    // MARK: - Callbacks

    /// Callback for terminal output
    private var onOutput: ((Data) -> Void)?

    /// Callback for resize notifications
    private var onResize: ((UInt32, UInt32) -> Void)?

    /// Callback for echo acknowledgments
    private var onEchoAck: ((UInt64) -> Void)?

    /// Callback for server shutdown signal
    private var onShutdown: (() -> Void)?

    /// Whether server has signaled shutdown
    private var isShutdown: Bool = false

    // MARK: - Initialization

    init() {}

    // MARK: - Callback Setters

    /// Sets the output callback
    func setOnOutput(_ callback: @escaping (Data) -> Void) {
        onOutput = callback
    }

    /// Sets the resize callback
    func setOnResize(_ callback: @escaping (UInt32, UInt32) -> Void) {
        onResize = callback
    }

    /// Sets the echo ack callback
    func setOnEchoAck(_ callback: @escaping (UInt64) -> Void) {
        onEchoAck = callback
    }

    /// Sets the shutdown callback
    func setOnShutdown(_ callback: @escaping () -> Void) {
        onShutdown = callback
    }

    // MARK: - Instruction Processing

    /// Shutdown signal constant (UInt64.max = -1 in mosh protocol)
    private static let shutdownSignal: UInt64 = UInt64.max

    /// Processes a received transport instruction from server
    /// - Parameter instruction: The received instruction
    /// - Returns: The state number to acknowledge
    func processInstruction(_ instruction: TransportInstruction) throws -> UInt64 {
        // Check for shutdown signal (newNum == -1 in mosh protocol)
        if instruction.newNum == Self.shutdownSignal {
            Self.logger.info("MoshTerminalState: Server sent shutdown signal")

            // Still process any final output in the diff
            if !instruction.diff.isEmpty {
                let hostMessage = try HostMessage.deserialize(instruction.diff)
                try processHostMessage(hostMessage)
            }

            // Signal shutdown (only once)
            if !isShutdown {
                isShutdown = true
                onShutdown?()
            }

            // Return the shutdown signal as ack
            return Self.shutdownSignal
        }

        let expectedStateNum = currentStateNum

        // Drop duplicate or old states
        guard instruction.newNum > expectedStateNum else {
            return expectedStateNum
        }

        // Enforce strict in-order updates
        guard instruction.oldNum == expectedStateNum else {
            let expected = expectedStateNum
            Self.logger.warning("Out-of-order packet: oldNum=\(instruction.oldNum), expected=\(expected)")
            return expectedStateNum
        }

        // Parse host message from diff (diff is raw protobuf, not separately compressed)
        // Note: The ENTIRE TransportInstruction is zlib-compressed at the transport layer,
        // but the diff field itself is raw serialized HostMessage protobuf.
        if !instruction.diff.isEmpty {
            let hostMessage = try HostMessage.deserialize(instruction.diff)
            try processHostMessage(hostMessage)
        }

        // Update state number
        currentStateNum = instruction.newNum

        return currentStateNum
    }

    /// Processes a host message
    private func processHostMessage(_ message: HostMessage) throws {
        for instruction in message.instructions {
            switch instruction {
            case .hostBytes(let bytes):
                onOutput?(bytes.data)

            case .resize(let width, let height):
                terminalWidth = width
                terminalHeight = height
                onResize?(width, height)

            case .echoAck(let ack):
                lastEchoAck = ack.echoNum
                onEchoAck?(ack.echoNum)
            }
        }
    }

    // MARK: - Acknowledgment

    /// Returns the current state number to acknowledge
    var stateNumToAck: UInt64 {
        currentStateNum
    }

    /// Marks the current state as acknowledged by client
    func markAcknowledged() {
        ackedStateNum = currentStateNum
    }

    // MARK: - State Queries

    /// Returns the current server state number
    var stateNum: UInt64 {
        currentStateNum
    }

    /// Returns the terminal dimensions
    var dimensions: (width: UInt32, height: UInt32) {
        (terminalWidth, terminalHeight)
    }

    /// Returns the last echo acknowledgment
    var echoAckNum: UInt64 {
        lastEchoAck
    }

    /// Whether the server has sent a shutdown signal
    var hasReceivedShutdown: Bool {
        isShutdown
    }

    /// Resets the terminal state
    func reset() {
        currentStateNum = 0
        ackedStateNum = 0
        lastEchoAck = 0
        isShutdown = false
    }
}
