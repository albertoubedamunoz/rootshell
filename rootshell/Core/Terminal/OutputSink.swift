import Foundation

/// Stateful lone-LF → CRLF normalizer for terminal-bound interpreter output.
/// Idempotent on CRLF input; tracks a trailing CR across chunks. One instance
/// per interpreter output stream.
nonisolated final class LFNormalizer: @unchecked Sendable {
    private let lock = UnfairLock()
    private var previousEndedWithCR = false

    func normalize(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            out.reserveCapacity(data.count + (data.count / 16))
            var prevCR = previousEndedWithCR
            for byte in data {
                if byte == 0x0A { // LF
                    if !prevCR { out.append(0x0D) }
                    out.append(0x0A)
                    prevCR = false
                    continue
                }
                out.append(byte)
                prevCR = (byte == 0x0D)
            }
            previousEndedWithCR = prevCR
            return out.count == data.count ? data : out
        }
    }
}

/// Incremental UTF-8 decoder for streamed byte chunks: decodes the longest
/// valid prefix of each chunk and carries an incomplete trailing sequence
/// (≤3 bytes) into the next call. `flush()` emits any dangling bytes as U+FFFD.
nonisolated final class StreamingUTF8Decoder: @unchecked Sendable {
    private let lock = UnfairLock()
    private var pending = Data()

    func decode(_ chunk: Data) -> String {
        lock.withLock {
            let bytes = [UInt8](pending) + [UInt8](chunk)
            pending.removeAll(keepingCapacity: true)

            // Scan back over a possibly-incomplete trailing sequence: at most
            // 3 continuation bytes plus one lead byte.
            var cut = bytes.count
            var scanned = 0
            while cut > 0, scanned < 4 {
                let byte = bytes[cut - 1]
                if byte & 0b1100_0000 == 0b1000_0000 {
                    // continuation byte — keep scanning for the lead
                    cut -= 1
                    scanned += 1
                    continue
                }
                if byte & 0b1000_0000 == 0 {
                    cut = bytes.count // ASCII tail: everything is complete
                    break
                }
                // Lead byte: sequence is complete only if its length fits
                let needed: Int
                if byte & 0b1110_0000 == 0b1100_0000 { needed = 2 }
                else if byte & 0b1111_0000 == 0b1110_0000 { needed = 3 }
                else if byte & 0b1111_1000 == 0b1111_0000 { needed = 4 }
                else { cut = bytes.count; break } // invalid lead; decoder replaces it
                if bytes.count - (cut - 1) < needed {
                    cut -= 1 // incomplete sequence — defer it
                } else {
                    cut = bytes.count // complete sequence at the end
                }
                break
            }

            guard cut > 0 else {
                pending = Data(bytes)
                return ""
            }
            if cut < bytes.count {
                pending = Data(bytes[cut...])
            }
            return String(decoding: bytes[0..<cut], as: UTF8.self)
        }
    }

    /// Emit any dangling partial sequence (invalid bytes become U+FFFD).
    func flush() -> String {
        lock.withLock {
            defer { pending.removeAll(keepingCapacity: false) }
            guard !pending.isEmpty else { return "" }
            return String(decoding: pending, as: UTF8.self)
        }
    }
}

/// Thread-safe output sink for emitting session output from background threads.
nonisolated final class OutputSink: @unchecked Sendable {
    private let lock = UnfairLock()
    private nonisolated(unsafe) var onOutput: (@Sendable (String) -> Void)?
    private nonisolated(unsafe) var onOutputData: (@Sendable (Data) -> Void)?

    nonisolated func update(onOutput: (@Sendable (String) -> Void)?, onOutputData: (@Sendable (Data) -> Void)?) {
        lock.withLock {
            self.onOutput = onOutput
            self.onOutputData = onOutputData
        }
    }

    nonisolated func emit(_ data: Data) {
        let callbacks = lock.withLock { (onOutputData, onOutput) }
        if let onOutputData = callbacks.0 {
            onOutputData(data)
        } else if let onOutput = callbacks.1 {
            onOutput(String(decoding: data, as: UTF8.self))
        }
    }

    nonisolated func emitString(_ output: String) {
        let callbacks = lock.withLock { (onOutputData, onOutput) }
        if let onOutput = callbacks.1 {
            onOutput(output)
        } else if let onOutputData = callbacks.0 {
            onOutputData(Data(output.utf8))
        }
    }
}
