//
//  MoshRTTEstimator.swift
//  rootshell
//
//  Round-trip time estimation for mosh protocol
//

import Foundation

/// Estimates round-trip time for mosh connections
///
/// Uses exponentially weighted moving average (EWMA) similar to TCP RTT estimation.
/// The RTT is used for:
/// - Determining when to show predictions (adaptive mode)
/// - Detecting connection problems
/// - Scheduling heartbeat packets
///
/// Note: This is @MainActor instead of an actor to avoid context switch overhead.
/// All callers are already on MainActor (MoshTransport, OutboundSynchronizer, MoshStateSync).
@MainActor
final class MoshRTTEstimator {

    // MARK: - State

    /// Smoothed RTT estimate (SRTT) in milliseconds
    private var smoothedRTT: Double = 0

    /// RTT variance estimate (RTTVAR) in milliseconds
    private var rttVariance: Double = 0

    /// Whether we have any RTT samples yet
    private var hasEstimate: Bool = false

    /// Last sent timestamp (for calculating RTT)
    private var lastSentTimestamp: UInt16 = 0

    /// Time when last packet was sent
    private var lastSentTime: Date?

    // MARK: - Constants

    /// Alpha for EWMA (weight of new sample) - matches TCP
    private let alpha: Double = 0.125  // 1/8

    /// Beta for variance calculation - matches TCP
    private let beta: Double = 0.25  // 1/4

    /// Initial RTT estimate if no samples (ms) - SRTT(1000)
    private let initialRTT: Double = 1000.0

    /// Initial variance estimate (ms) - RTTVAR(500)
    private let initialVariance: Double = 500.0

    // MARK: - Initialization

    /// Creates a new RTT estimator
    init() {}

    // MARK: - Timestamp Tracking

    /// Records that a packet was sent with the given timestamp
    /// - Parameter timestamp: The 16-bit timestamp sent in the packet
    func recordSent(timestamp: UInt16) {
        lastSentTimestamp = timestamp
        lastSentTime = Date()
    }

    /// Records a received reply timestamp and updates RTT estimate
    /// - Parameters:
    ///   - replyTimestamp: The echoed timestamp from the remote side
    ///   - receiveTimestamp: The local timestamp when the packet was received (captured before async hops)
    /// - Returns: The calculated RTT in milliseconds, or nil if invalid
    @discardableResult
    func recordReply(replyTimestamp: UInt16, receiveTimestamp: UInt16) -> Double? {
        // Calculate RTT from reply timestamp
        // The reply timestamp echoes our sent timestamp
        // We need to handle wraparound (16-bit timestamps wrap at 65536ms)
        // IMPORTANT: Use the pre-captured receiveTimestamp, not MoshTimestamp.now,
        // to avoid inflated RTT due to async scheduling delays
        var rttMs = Int(receiveTimestamp) - Int(replyTimestamp)

        // Handle wraparound
        if rttMs < 0 {
            rttMs += 65536
        }

        // Sanity check - RTT shouldn't be more than 5 seconds
        // This ignores implausible values like server being Ctrl-Z suspended
        guard rttMs >= 0 && rttMs < 5000 else {
            return nil
        }

        return updateEstimate(sample: Double(rttMs))
    }

    // MARK: - RTT Calculation

    /// Updates the RTT estimate with a new sample
    /// Uses TCP-style EWMA calculation from RFC 6298
    private func updateEstimate(sample: Double) -> Double {
        if !hasEstimate {
            // First sample - initialize
            smoothedRTT = sample
            rttVariance = sample / 2
            hasEstimate = true
        } else {
            // Update using EWMA
            let error = sample - smoothedRTT
            smoothedRTT = smoothedRTT + alpha * error
            rttVariance = rttVariance + beta * (abs(error) - rttVariance)
        }

        return sample
    }

    // MARK: - Public Accessors

    /// Returns the current smoothed RTT estimate in milliseconds
    var estimatedRTT: Double {
        hasEstimate ? smoothedRTT : initialRTT
    }

    /// Returns the RTT variance estimate in milliseconds
    var variance: Double {
        hasEstimate ? rttVariance : initialVariance
    }

    /// Returns the retransmission timeout (RTO) in milliseconds
    /// RTO = SRTT + 4 * RTTVAR (TCP formula)
    var retransmissionTimeout: Double {
        let rto = estimatedRTT + 4 * variance
        // Clamp to reasonable range
        return max(200, min(rto, 10000))
    }

    /// Returns the current latency as an integer for display
    var latencyMs: Int? {
        hasEstimate ? Int(smoothedRTT) : nil
    }
}
