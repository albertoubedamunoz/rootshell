import Dispatch

enum ProtocolTiming {
    /// Floor for adaptive transmit interval (RTT/2, clamped)
    nonisolated static let minimumTransmitIntervalMs: UInt64 = 20
    /// Ceiling for adaptive transmit interval
    nonisolated static let maximumTransmitIntervalMs: UInt64 = 250
    /// Interval between keepalive packets when idle
    nonisolated static let heartbeatIntervalMs: UInt64 = 3000
    /// Grace period before ack is considered overdue
    nonisolated static let acknowledgmentGraceMs: UInt64 = 100
    /// Default minimum gap between consecutive transmissions
    nonisolated static let defaultMinimumTransmitGapMs: UInt64 = 1
    /// Window during which unacked state is retransmitted
    nonisolated static let activeRetransmitWindowMs: UInt64 = 10_000
    /// Maximum random padding bytes for traffic analysis resistance
    nonisolated static let maxPaddingBytes: Int = 16
    /// Maximum graceful close attempts before timeout
    nonisolated static let maxCloseAttempts: Int = 16

    /// Tick interval when session is throttled (unfocused tab)
    /// 5 seconds - reduces CPU from ~4 ticks/sec to ~0.2 ticks/sec (95% reduction)
    nonisolated static let throttledCycleIntervalMs: UInt64 = 5000

    nonisolated static func monotonicNowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}
