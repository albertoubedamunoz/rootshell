#if !targetEnvironment(macCatalyst)

import Foundation

/// Message type identifiers matching Go's `message.Type` constants.
enum CrocMessageType: String, Codable, Sendable {
    case pake = "pake"
    case externalIP = "externalip"
    case finished = "finished"
    case error = "error"
    case closeRecipient = "close-recipient"
    case closeSender = "close-sender"
    case recipientReady = "recipientready"
    case fileInfo = "fileinfo"
}

/// Wire message structure matching Go's `message.Message`.
/// JSON field names use single-character keys for wire compatibility.
nonisolated struct CrocMessage: Codable, Sendable {
    var type: CrocMessageType?
    var message: String?
    var bytes: Data?
    var bytes2: Data?
    var num: Int?

    enum CodingKeys: String, CodingKey {
        case type = "t"
        case message = "m"
        case bytes = "b"
        case bytes2 = "b2"
        case num = "n"
    }

    /// Encode this message for transmission: JSON → compress → encrypt.
    /// If key is nil, the message is sent unencrypted (only valid for PAKE messages).
    func encode(key: Data?) throws -> Data {
        let jsonData = try JSONEncoder().encode(self)
        let compressed = CrocCompression.compress(jsonData)
        if let key {
            return try CrocEncryption.encrypt(compressed, key: key)
        }
        return compressed
    }

    /// Decode a received message: decrypt → decompress → JSON.
    /// If key is nil, the message is treated as unencrypted.
    static func decode(data: Data, key: Data?) throws -> CrocMessage {
        var payload = data
        if let key {
            payload = try CrocEncryption.decrypt(payload, key: key)
        }
        let decompressed = CrocCompression.decompress(payload)
        return try JSONDecoder().decode(CrocMessage.self, from: decompressed)
    }
}

#endif
