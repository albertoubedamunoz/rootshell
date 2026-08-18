#if !targetEnvironment(macCatalyst)

import Foundation

/// Per-hop statistics tracking with ring buffer for stripchart display.
struct HopStatistics {
    /// All IPs seen at this TTL (ECMP load balancing)
    var addresses: [String] = []
    /// Resolved hostnames keyed by IP
    var hostnames: [String: String] = [:]
    /// AS info keyed by IP
    var asInfo: [String: GeoInfo] = [:]

    var sent: Int = 0
    var received: Int = 0
    var lastRTT: Double = 0             // milliseconds
    var bestRTT: Double = .infinity
    var worstRTT: Double = 0
    var sumRTT: Double = 0
    var sumRTTSquared: Double = 0       // for stdev: sqrt(sumSq/n - (sum/n)^2)
    var previousRTT: Double?            // for jitter calculation
    var lastJitter: Double = 0          // |current - previous|
    var sumJitter: Double = 0
    var worstJitter: Double = 0
    var interarrivalJitter: Double = 0  // RFC 1889 running estimate

    /// Ring buffer for stripchart display (nil = timeout)
    var samples: [Double?]
    var sampleIndex: Int = 0

    /// Number of log(rtt) samples accumulated for geometric mean
    private var logRTTSum: Double = 0

    init(maxSamples: Int) {
        let safeMaxSamples = max(1, maxSamples)
        self.samples = [Double?](repeating: nil, count: safeMaxSamples)
    }

    // MARK: - Computed Properties

    var lossPercent: Double {
        guard sent > 0 else { return 0 }
        return Double(sent - received) / Double(sent) * 100.0
    }

    var avgRTT: Double {
        guard received > 0 else { return 0 }
        return sumRTT / Double(received)
    }

    var stddev: Double {
        guard received > 1 else { return 0 }
        let avg = avgRTT
        let variance = sumRTTSquared / Double(received) - avg * avg
        return variance > 0 ? sqrt(variance) : 0
    }

    var avgJitter: Double {
        let jitterSamples = received > 1 ? received - 1 : 0
        guard jitterSamples > 0 else { return 0 }
        return sumJitter / Double(jitterSamples)
    }

    var geometricMean: Double {
        guard received > 0 else { return 0 }
        return exp(logRTTSum / Double(received))
    }

    var dropped: Int {
        return max(0, sent - received)
    }

    /// Primary display address (first seen)
    var primaryAddress: String? {
        addresses.first
    }

    /// Primary hostname for display
    var displayName: String? {
        guard let ip = primaryAddress else { return nil }
        return hostnames[ip]
    }

    // MARK: - Mutations

    mutating func recordProbe(rtt: Double, fromAddress: String) {
        received += 1
        lastRTT = rtt
        bestRTT = min(bestRTT, rtt)
        worstRTT = max(worstRTT, rtt)
        sumRTT += rtt
        sumRTTSquared += rtt * rtt

        // Log for geometric mean (guard against log(0))
        if rtt > 0 {
            logRTTSum += log(rtt)
        }

        // Jitter
        if let prev = previousRTT {
            let jitter = abs(rtt - prev)
            lastJitter = jitter
            sumJitter += jitter
            worstJitter = max(worstJitter, jitter)
            // RFC 1889 interarrival jitter: J(i) = J(i-1) + (|D(i-1,i)| - J(i-1))/16
            interarrivalJitter += (jitter - interarrivalJitter) / 16.0
        }
        previousRTT = rtt

        // Ring buffer
        if !samples.isEmpty {
            samples[sampleIndex % samples.count] = rtt
            sampleIndex += 1
        }

        // Track address (ECMP)
        if !addresses.contains(fromAddress) {
            addresses.append(fromAddress)
        }
    }

    mutating func recordTimeout() {
        // Note: sent is already incremented by recordSent() when the probe is dispatched.
        // Do NOT increment sent here — that would double-count.
        if !samples.isEmpty {
            samples[sampleIndex % samples.count] = nil
            sampleIndex += 1
        }
    }

    mutating func recordSent() {
        sent += 1
    }

    mutating func reset() {
        sent = 0
        received = 0
        lastRTT = 0
        bestRTT = .infinity
        worstRTT = 0
        sumRTT = 0
        sumRTTSquared = 0
        previousRTT = nil
        lastJitter = 0
        sumJitter = 0
        worstJitter = 0
        interarrivalJitter = 0
        logRTTSum = 0
        sampleIndex = 0
        for i in samples.indices {
            samples[i] = nil
        }
        // Keep addresses and hostnames
    }
}

/// Complete trace state containing all hops
final class MtrTrace {
    static let maxSamples = 400

    var hops: [HopStatistics]
    var destinationReached: Bool = false
    var destinationTTL: Int?
    /// Highest TTL that received any response
    var effectiveMaxTTL: Int
    /// Configured max TTL
    let configMaxTTL: Int

    init(maxTTL: Int) {
        let safeMaxTTL = max(1, maxTTL)
        self.configMaxTTL = safeMaxTTL
        self.effectiveMaxTTL = safeMaxTTL
        self.hops = (0..<safeMaxTTL).map { _ in HopStatistics(maxSamples: Self.maxSamples) }
    }

    /// Number of displayable hops (up to destination or highest responding hop)
    var displayableHopCount: Int {
        if let destTTL = destinationTTL {
            return destTTL
        }
        // Find highest hop that actually received a response.
        // We can't use `sent > 0` because probes are sent for all TTLs each round,
        // which would always show maxTTL hops.
        // Show up to the highest responding hop + maxUnknown consecutive non-responding hops.
        var highestResponding = 0
        for i in 0..<hops.count {
            if hops[i].received > 0 {
                highestResponding = i + 1
            }
        }
        // If nothing responded yet, show up to the first few hops that have been probed
        if highestResponding == 0 {
            for i in 0..<hops.count {
                if hops[i].sent > 0 {
                    highestResponding = i + 1
                } else {
                    break
                }
            }
        }
        return highestResponding
    }

    func reset(keepAddresses: Bool) {
        for i in hops.indices {
            if keepAddresses {
                hops[i].reset()
            } else {
                hops[i] = HopStatistics(maxSamples: Self.maxSamples)
            }
        }
        destinationReached = false
        destinationTTL = nil
    }
}

#endif // !targetEnvironment(macCatalyst)
