//
//  MoshFragment.swift
//  rootshell
//
//  Mosh packet fragmentation for large messages
//

import Foundation

/// Handles fragmentation and reassembly of large mosh packets
///
/// Mosh uses UDP which has MTU limitations. Large packets are fragmented
/// for transmission and reassembled on receipt.
///
/// Fragment header format (10 bytes):
/// - 8 bytes: Fragment ID (big-endian uint64)
/// - 2 bytes: Combined field (big-endian):
///   - Bit 15: Final fragment flag (1 = this is the last fragment)
///   - Bits 0-14: Fragment number (0-based)
struct MoshFragment: Sendable {

    /// Maximum payload size per fragment (typical MTU - headers)
    nonisolated static let maxPayloadSize = 1280

    /// Fragment ID for reassembly (64-bit)
    let fragmentId: UInt64

    /// Fragment number (0-based, up to 32767)
    let fragmentNum: UInt16

    /// Whether this is the final fragment
    let isFinal: Bool

    /// Fragment payload
    let payload: Data

    // MARK: - Fragmentation

    /// Fragments a large payload into multiple fragments
    /// - Parameter data: The data to fragment
    /// - Returns: Array of fragments
    /// - Throws: MoshError.payloadTooLarge if data exceeds maximum fragmentable size
    nonisolated static func fragment(_ data: Data) throws -> [MoshFragment] {
        let fragmentId = UInt64.random(in: 0..<UInt64.max)

        // If data fits in one fragment, no fragmentation needed
        if data.count <= maxPayloadSize {
            return [MoshFragment(
                fragmentId: fragmentId,
                fragmentNum: 0,
                isFinal: true,
                payload: data
            )]
        }

        var fragments: [MoshFragment] = []

        // Calculate number of fragments needed
        let count = (data.count + maxPayloadSize - 1) / maxPayloadSize
        guard count <= 32768 else {
            // Maximum is 32768 fragments (15 bits)
            throw MoshError.payloadTooLarge(size: data.count, maxSize: 32768 * maxPayloadSize)
        }

        var offset = 0
        var fragmentNum: UInt16 = 0

        while offset < data.count {
            let end = min(offset + maxPayloadSize, data.count)
            let payload = data[offset..<end]
            let isFinal = (end == data.count)

            fragments.append(MoshFragment(
                fragmentId: fragmentId,
                fragmentNum: fragmentNum,
                isFinal: isFinal,
                payload: Data(payload)
            ))

            offset = end
            fragmentNum += 1
        }

        return fragments
    }

    // MARK: - Fragment Header

    /// Header size in bytes (8-byte ID + 2-byte combined field)
    nonisolated static let headerSize = 10

    /// Serializes the fragment with header
    nonisolated var serialized: Data {
        var data = Data()

        // Fragment ID (8 bytes, big-endian)
        var id = fragmentId.bigEndian
        withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }

        // Combined field (2 bytes, big-endian)
        // Bit 15 = final flag, bits 0-14 = fragment number
        var combined: UInt16 = fragmentNum & 0x7FFF  // Low 15 bits
        if isFinal {
            combined |= 0x8000  // Set high bit
        }
        var combinedBE = combined.bigEndian
        withUnsafeBytes(of: &combinedBE) { data.append(contentsOf: $0) }

        // Payload
        data.append(payload)
        return data
    }

    /// Parses a fragment from serialized data
    /// - Parameter data: The serialized fragment
    /// - Returns: Parsed fragment
    /// - Throws: MoshError.fragmentReassemblyFailed if parsing fails
    nonisolated static func parse(_ data: Data) throws -> MoshFragment {
        guard data.count >= headerSize else {
            throw MoshError.fragmentReassemblyFailed(
                reason: "Fragment too short: \(data.count) bytes"
            )
        }

        // Parse fragment ID (8 bytes, big-endian)
        let fragmentId = data.withUnsafeBytes { ptr -> UInt64 in
            var result: UInt64 = 0
            for i in 0..<8 {
                result = (result << 8) | UInt64(ptr[i])
            }
            return result
        }

        // Parse combined field (2 bytes, big-endian)
        let combined = UInt16(data[8]) << 8 | UInt16(data[9])
        let isFinal = (combined & 0x8000) != 0
        let fragmentNum = combined & 0x7FFF

        let payload = data.count > headerSize ? Data(data.suffix(from: headerSize)) : Data()

        return MoshFragment(
            fragmentId: fragmentId,
            fragmentNum: fragmentNum,
            isFinal: isFinal,
            payload: payload
        )
    }

    /// Whether this is a single (non-fragmented) packet
    nonisolated var isSingle: Bool {
        fragmentNum == 0 && isFinal
    }
}

// MARK: - Fragment Assembler

/// Assembles fragments into complete messages
/// Note: @MainActor instead of actor to avoid context switch overhead.
/// Only called from MoshTransport which is @MainActor.
@MainActor
final class MoshFragmentAssembler {

    /// Pending fragments by fragment ID
    private var pending: [UInt64: [UInt16: MoshFragment]] = [:]

    /// Track which fragment sets have received their final fragment
    private var finalReceived: [UInt64: UInt16] = [:]

    /// Timeout for incomplete fragments (seconds)
    private let timeout: TimeInterval = 10.0

    /// Timestamps for fragment sets
    private var timestamps: [UInt64: Date] = [:]

    // MARK: - Reassembly

    /// Adds a fragment and returns the complete message if all fragments received
    /// - Parameter fragment: The received fragment
    /// - Returns: The complete message if all fragments are present, nil otherwise
    func add(_ fragment: MoshFragment) -> Data? {
        // Clean up expired fragment sets
        cleanupExpired()

        // Single fragment - return immediately
        if fragment.isSingle {
            return fragment.payload
        }

        let id = fragment.fragmentId

        // Initialize fragment set if needed
        if pending[id] == nil {
            pending[id] = [:]
            timestamps[id] = Date()
        }

        // Add fragment
        pending[id]?[fragment.fragmentNum] = fragment

        // Track final fragment to know total count
        if fragment.isFinal {
            finalReceived[id] = fragment.fragmentNum
        }

        // Check if complete (need final fragment info and all fragments 0..finalNum)
        guard let finalNum = finalReceived[id],
              let fragments = pending[id],
              fragments.count == Int(finalNum) + 1 else {
            return nil
        }

        // Reassemble in order
        var assembled = Data()
        for i: UInt16 in 0...finalNum {
            guard let frag = fragments[i] else {
                // Missing fragment - shouldn't happen but be safe
                return nil
            }
            assembled.append(frag.payload)
        }

        // Clear pending
        pending.removeValue(forKey: id)
        timestamps.removeValue(forKey: id)
        finalReceived.removeValue(forKey: id)

        return assembled
    }

    /// Removes expired fragment sets
    private func cleanupExpired() {
        let now = Date()
        // Collect expired keys first, then remove (avoids mutating during iteration)
        var expiredIds: [UInt64] = []
        for (id, timestamp) in timestamps {
            if now.timeIntervalSince(timestamp) > timeout {
                expiredIds.append(id)
            }
        }
        for id in expiredIds {
            pending.removeValue(forKey: id)
            timestamps.removeValue(forKey: id)
            finalReceived.removeValue(forKey: id)
        }
    }

    /// Clears all pending fragments
    func clear() {
        pending.removeAll()
        timestamps.removeAll()
        finalReceived.removeAll()
    }

    /// Number of pending fragment sets
    var pendingCount: Int {
        pending.count
    }
}
