//
//  TSSHTransferInbox.swift
//  rootshell
//
//  Side store for in-flight Continuity transfers being received. Pairs a
//  fresh transfer ticket UUID (carried in `ConnectionConfig.trzszTransfer`)
//  with the heavyweight payload + ack callback the receive coordinator
//  needs to consume when the new TerminalView wires up its session.
//
//  Putting the payload here instead of inside ConnectionConfig keeps the
//  enum cheap (Equatable on a UUID) and avoids embedding hundreds of KB
//  of scrollback into something SwiftUI hashes for view identity.
//

import Foundation
import os.log

@MainActor
final class TrzszTransferInbox {
    static let shared = TrzszTransferInbox()

    private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszTransferInbox"
    )

    /// Per-ticket parking lot. The TerminalView whose connectionConfig is
    /// `.trzszTransfer(ticketId)` calls `consume(ticketId)` once during
    /// setupPTYAndShell. The receive coordinator drives final ack via the
    /// stored `complete` closure.
    private final class Slot {
        let payload: TrzszTransferPayload
        let complete: @MainActor (Result<Void, Error>) -> Void

        /// Optional hook installed by the receiving TerminalView once it
        /// starts the async Attach. Receiver-side Cancel invokes this before
        /// acking failure so a stuck attach can be abandoned locally.
        var cancelAttach: (@MainActor () -> Bool)?

        init(
            payload: TrzszTransferPayload,
            complete: @escaping @MainActor (Result<Void, Error>) -> Void
        ) {
            self.payload = payload
            self.complete = complete
        }
    }

    private var slots: [UUID: Slot] = [:]

    /// Registers a payload + completion callback. Returns the ticket ID to
    /// embed in the receiving TerminalView's ConnectionConfig.
    func deposit(
        payload: TrzszTransferPayload,
        complete: @escaping @MainActor (Result<Void, Error>) -> Void
    ) -> UUID {
        let id = UUID()
        slots[id] = Slot(payload: payload, complete: complete)
        Self.logger.info("Deposited transfer ticket \(id.uuidString.prefix(8), privacy: .public)")
        return id
    }

    /// Removes and returns the payload for the given ticket. Called by the
    /// receiving TerminalView when it constructs the session. The completion
    /// closure remains live in the inbox until `complete(_:result:)` fires.
    func consumePayload(_ id: UUID) -> TrzszTransferPayload? {
        guard let slot = slots[id] else { return nil }
        return slot.payload
    }

    /// Installs a local cancellation hook for the TerminalView attach task.
    /// Returns false if the slot was already completed/cancelled.
    @discardableResult
    func registerCancelHandler(
        _ id: UUID,
        cancel: @escaping @MainActor () -> Bool
    ) -> Bool {
        guard let slot = slots[id] else { return false }
        slot.cancelAttach = cancel
        return true
    }

    /// Resolves the deposit's completion callback. Called by the receiving
    /// TerminalView after the session attaches (or fails). Removes the slot.
    func complete(_ id: UUID, result: Result<Void, Error>) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        Self.logger.info("Completing transfer ticket \(id.uuidString.prefix(8), privacy: .public): success=\(result.isSuccess)")
        slot.complete(result)
    }

    /// Cancel a deposit before the receiver picks it up. Resolves the
    /// callback with a cancellation error so any waiters on the originating
    /// device know not to close the source tab.
    func cancel(_ id: UUID, reason: Error = TrzszTransferError.cancelled) {
        if let cancelAttach = slots[id]?.cancelAttach,
           !cancelAttach() {
            return
        }
        complete(id, result: .failure(reason))
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true } else { return false }
    }
}
