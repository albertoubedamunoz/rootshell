//
//  MoshTimestampEcho.swift
//  rootshell
//
//  The timestamp each outgoing packet echoes back to the peer. The peer
//  measures RTT from it and paces its frames at clamp(SRTT/2, 20, 250) ms, so
//  an inflated echo slows every screen update it sends us.
//

/// Echoes the peer's latest timestamp once, advanced by how long it was held,
/// so local processing and acknowledgment delays are excluded from the peer's RTT.
/// Stale timestamps are discarded.
/// Shared by the app and its standalone test target.
nonisolated struct MoshTimestampEcho {
    /// "No timestamp reply" on the wire.
    static let none = UInt16.max

    /// Timestamps held for this long or longer are too stale to echo.
    static let maxHoldMs: UInt64 = 1000

    private var saved: UInt16?
    private var savedAtMs: UInt64 = 0

    /// Records the peer's timestamp from a received packet.
    mutating func save(_ timestamp: UInt16, receivedAtMs: UInt64) {
        guard timestamp != Self.none else { return }
        saved = timestamp
        savedAtMs = receivedAtMs
    }

    /// The reply timestamp for the next outgoing packet. Consumes the saved
    /// timestamp, so later packets carry `none` until the peer sends another.
    mutating func takeReply(nowMs: UInt64) -> UInt16 {
        guard let timestamp = saved else { return Self.none }
        saved = nil
        let heldMs = nowMs >= savedAtMs ? nowMs - savedAtMs : 0
        guard heldMs < Self.maxHoldMs else { return Self.none }
        return timestamp &+ UInt16(heldMs)
    }
}
