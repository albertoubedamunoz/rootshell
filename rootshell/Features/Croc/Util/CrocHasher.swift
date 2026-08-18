#if !targetEnvironment(macCatalyst)

import CryptoKit
import Foundation

/// File hashing supporting multiple algorithms.
/// Port of Go's `utils.HashFile()`.
nonisolated enum CrocHasher {

    /// Hash a file using the specified algorithm.
    static func hashFile(at path: String, algorithm: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        // Handle symlinks: hash the link target string
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            let digest = SHA256.hash(data: Data(target.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return Data(hex.utf8)
        }

        switch algorithm.lowercased() {
        case "xxhash":
            return try xxHashFile(url)
        case "md5":
            return try md5HashFile(url)
        case "imohash":
            return try imoHashFile(url)
        case "highway":
            return try highwayHashFile(url)
        default:
            throw CrocError.protocolError("unsupported hash algorithm: \(algorithm)")
        }
    }

    // MARK: - XXHash64

    /// Pure Swift XXHash64 implementation.
    /// Produces identical output to Go's `cespare/xxhash/v2`.
    private static func xxHashFile(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let hash = data.withUnsafeBytes { rawBuffer in
            croc_xxhash64(rawBuffer.baseAddress, rawBuffer.count)
        }
        var hashBytes = hash.bigEndian
        return Data(bytes: &hashBytes, count: 8)
    }

    // MARK: - MD5

    private static func md5HashFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = Insecure.MD5()
        while true {
            let chunk = handle.readData(ofLength: 32768)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        return Data(hasher.finalize())
    }

    // MARK: - IMOHash (murmur3-based approximate hash)

    /// Port of Go's `kalafut/imohash` — murmur3-128 hash with file sampling.
    /// Go uses: `imohash.NewCustom(16*16*8*1024, 128*1024).SumFile()`
    /// sampleSize = 16*16*8*1024 = 2097152 (2 MB), sampleThreshold = 128*1024 (128 KB)
    ///
    /// Algorithm: murmur3-128 of sampled data, then overwrite first bytes with file size as uvarint.
    private static func imoHashFile(_ url: URL) throws -> Data {
        let sampleSize = 16 * 16 * 8 * 1024  // 2097152 — matches Go's croc config
        let sampleThreshold = 128 * 1024      // 131072

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = Int64((attrs[.size] as? UInt64) ?? 0)

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = Murmur3_128()

        if sampleSize < 1 || fileSize < Int64(sampleThreshold) || fileSize < Int64(4 * sampleSize) {
            // Small file: hash entire contents
            while true {
                let chunk = handle.readData(ofLength: 65536)
                if chunk.isEmpty { break }
                hasher.update(chunk)
            }
        } else {
            // Large file: sample beginning, middle, end
            let beginning = handle.readData(ofLength: sampleSize)
            hasher.update(beginning)

            handle.seek(toFileOffset: UInt64(fileSize) / 2)
            let middle = handle.readData(ofLength: sampleSize)
            hasher.update(middle)

            handle.seek(toFileOffset: UInt64(fileSize) - UInt64(sampleSize))
            let end = handle.readData(ofLength: sampleSize)
            hasher.update(end)
        }

        var hash = hasher.finalize()  // 16 bytes

        // Overwrite first bytes with file size as uvarint (matching Go's binary.PutUvarint)
        var sizeBytes = [UInt8]()
        var n = UInt64(fileSize)
        while n >= 0x80 {
            sizeBytes.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        sizeBytes.append(UInt8(n))
        for (i, b) in sizeBytes.enumerated() where i < hash.count {
            hash[i] = b
        }

        return hash
    }

    // MARK: - HighwayHash (native port)

    /// Port of Go's `minio/highwayhash` — HighwayHash-256 keyed hash.
    /// Uses the same fixed key as Go's croc: "1553c5383fb0b86578c3310da665b4f6e0521acf22eb58a99532ffed02a6b115"
    private static func highwayHashFile(_ url: URL) throws -> Data {
        let keyHex = "1553c5383fb0b86578c3310da665b4f6e0521acf22eb58a99532ffed02a6b115"
        guard let key = hexToData(keyHex), key.count == 32 else {
            throw CrocError.protocolError("invalid highway hash key")
        }

        var hh = HighwayHashState(key: key)

        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            hh.update(chunk)
        }

        return hh.finalize256()
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var chars = hex.makeIterator()
        while let c1 = chars.next(), let c2 = chars.next() {
            guard let byte = UInt8(String([c1, c2]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }
}

#endif
