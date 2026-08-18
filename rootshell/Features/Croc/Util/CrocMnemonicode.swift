#if !targetEnvironment(macCatalyst)

import Foundation

/// Mnemonicode encoding and random name generation.
/// Port of Go's `mnemonicode` package and `utils.GetRandomName()`.
///
/// Copyright (c) 2000 Oren Tirosh <oren@hishome.net> — MIT License
nonisolated enum CrocMnemonicode {

    private static let base: UInt32 = 1626
    private static let nbPinNumbers = 4
    private static let nbBytesWords = 4

    /// Number of words required to encode `length` bytes.
    static func wordsRequired(_ length: Int) -> Int {
        return ((length + 1) * 3) / 4
    }

    /// Encode bytes into mnemonic words.
    /// Every 4 bytes → 3 words. Extra bytes get 1-3 additional words.
    static func encodeWordList(_ src: Data) -> [String] {
        var result: [String] = []
        let words = CrocWordList.words
        var offset = 0

        // Process 4-byte chunks → 3 words each
        while offset + 4 <= src.count {
            var x: UInt32 = UInt32(src[offset])
            x |= UInt32(src[offset + 1]) << 8
            x |= UInt32(src[offset + 2]) << 16
            x |= UInt32(src[offset + 3]) << 24
            offset += 4

            let i0 = Int(x % base)
            let i1 = Int((x / base) % base)
            let i2 = Int((x / base / base) % base)
            result.append(words[i0])
            result.append(words[i1])
            result.append(words[i2])
        }

        // Handle remaining bytes
        let remaining = src.count - offset
        if remaining > 0 {
            var x: UInt32 = 0
            for i in stride(from: remaining - 1, through: 0, by: -1) {
                x <<= 8
                x |= UInt32(src[offset + i])
            }
            result.append(words[Int(x % base)])
            if remaining >= 2 {
                result.append(words[Int((x / base) % base)])
            }
            if remaining == 3 {
                result.append(words[Int(base) + Int((x / base / base) % 7)])
            }
        }

        return result
    }

    /// Generate a random 4-digit PIN.
    static func generateRandomPin() -> String {
        var pin = ""
        for _ in 0..<nbPinNumbers {
            pin += String(randomDigitForGoParity())
        }
        return pin
    }

    /// Go uses `rand.Int(rand.Reader, 9)`, which yields digits 0...8.
    private static func randomDigitForGoParity() -> UInt8 {
        while true {
            var randomByte: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &randomByte)
            if randomByte < 252 {
                return randomByte % 9
            }
        }
    }

    /// Generate a random code phrase: PIN + mnemonic words.
    /// Example: "1234-ocean-table-violin"
    static func getRandomName() -> String {
        var randomBytes = Data(count: nbBytesWords)
        randomBytes.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, nbBytesWords, ptr.baseAddress!)
        }
        let words = encodeWordList(randomBytes)
        return generateRandomPin() + "-" + words.joined(separator: "-")
    }
}

#endif
