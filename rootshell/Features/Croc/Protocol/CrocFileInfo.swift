#if !targetEnvironment(macCatalyst)

import Foundation

/// Information about a single file to transfer.
/// JSON field names match Go's single-character keys for wire compatibility.
nonisolated struct CrocFileInfo: Codable, Sendable {
    /// Filename (basename).
    var name: String = ""

    /// Destination folder path (relative, on receiver).
    var folderRemote: String = ""

    /// Source folder path (on sender).
    var folderSource: String = ""

    /// File hash bytes (algorithm determined by SenderInfo.hashAlgorithm).
    var hash: Data?

    /// File size in bytes.
    var size: Int64 = 0

    /// File modification time.
    var modTime: Date?

    /// Whether the file data was compressed before encryption.
    var isCompressed: Bool = false

    /// Whether the file data is encrypted.
    var isEncrypted: Bool = false

    /// Symlink target path (empty if not a symlink).
    var symlink: String = ""

    /// POSIX file mode/permissions.
    var mode: UInt32 = 0

    /// Whether this is a temporary file (e.g., zipped folder).
    var tempFile: Bool = false

    /// Whether this file was ignored by .gitignore.
    var isIgnored: Bool = false

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case folderRemote = "fr"
        case folderSource = "fs"
        case hash = "h"
        case size = "s"
        case modTime = "m"
        case isCompressed = "c"
        case isEncrypted = "e"
        case symlink = "sy"
        case mode = "md"
        case tempFile = "tf"
        case isIgnored = "ig"
    }

    private static let goDateEncoder: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let goDateDecoders: [ISO8601DateFormatter] = {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let withoutFractions = ISO8601DateFormatter()
        withoutFractions.formatOptions = [.withInternetDateTime]

        return [withFractions, withoutFractions]
    }()

    private static func parseGoTimestamp(_ value: String) -> Date? {
        if let direct = goDateDecoders.lazy.compactMap({ $0.date(from: value) }).first {
            return direct
        }

        guard let dotIndex = value.firstIndex(of: ".") else {
            return nil
        }

        let timezoneStart = value[dotIndex...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
        guard let timezoneStart else {
            return nil
        }

        let fractionalDigits = value[value.index(after: dotIndex)..<timezoneStart]
        guard fractionalDigits.count > 3 else {
            return nil
        }

        let trimmedFraction = fractionalDigits.prefix(3)
        let normalized = value[..<value.index(after: dotIndex)] + trimmedFraction + value[timezoneStart...]
        return goDateDecoders[0].date(from: String(normalized))
    }

    init(
        name: String = "",
        folderRemote: String = "",
        folderSource: String = "",
        hash: Data? = nil,
        size: Int64 = 0,
        modTime: Date? = nil,
        isCompressed: Bool = false,
        isEncrypted: Bool = false,
        symlink: String = "",
        mode: UInt32 = 0,
        tempFile: Bool = false,
        isIgnored: Bool = false
    ) {
        self.name = name
        self.folderRemote = folderRemote
        self.folderSource = folderSource
        self.hash = hash
        self.size = size
        self.modTime = modTime
        self.isCompressed = isCompressed
        self.isEncrypted = isEncrypted
        self.symlink = symlink
        self.mode = mode
        self.tempFile = tempFile
        self.isIgnored = isIgnored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        folderRemote = try container.decodeIfPresent(String.self, forKey: .folderRemote) ?? ""
        folderSource = try container.decodeIfPresent(String.self, forKey: .folderSource) ?? ""
        hash = try container.decodeIfPresent(Data.self, forKey: .hash)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        isCompressed = try container.decodeIfPresent(Bool.self, forKey: .isCompressed) ?? false
        isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? false
        symlink = try container.decodeIfPresent(String.self, forKey: .symlink) ?? ""
        mode = try container.decodeIfPresent(UInt32.self, forKey: .mode) ?? 0
        tempFile = try container.decodeIfPresent(Bool.self, forKey: .tempFile) ?? false
        isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false

        if let modTimeString = try container.decodeIfPresent(String.self, forKey: .modTime) {
            guard let parsedDate = Self.parseGoTimestamp(modTimeString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modTime,
                    in: container,
                    debugDescription: "Invalid croc timestamp: \(modTimeString)"
                )
            }
            modTime = parsedDate
        } else if let legacyTimestamp = try container.decodeIfPresent(Double.self, forKey: .modTime) {
            modTime = Date(timeIntervalSinceReferenceDate: legacyTimestamp)
        } else {
            modTime = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(folderRemote, forKey: .folderRemote)
        try container.encode(folderSource, forKey: .folderSource)
        try container.encodeIfPresent(hash, forKey: .hash)
        try container.encode(size, forKey: .size)
        if let modTime {
            try container.encode(Self.goDateEncoder.string(from: modTime), forKey: .modTime)
        }
        try container.encode(isCompressed, forKey: .isCompressed)
        try container.encode(isEncrypted, forKey: .isEncrypted)
        try container.encode(symlink, forKey: .symlink)
        try container.encode(mode, forKey: .mode)
        try container.encode(tempFile, forKey: .tempFile)
        try container.encode(isIgnored, forKey: .isIgnored)
    }
}

/// Metadata sent by the sender describing the transfer.
nonisolated struct CrocSenderInfo: Codable, Sendable {
    var filesToTransfer: [CrocFileInfo]
    var emptyFoldersToTransfer: [CrocFileInfo]
    var totalNumberFolders: Int
    var machineID: String
    var ask: Bool
    var sendingText: Bool
    var noCompress: Bool
    var hashAlgorithm: String

    enum CodingKeys: String, CodingKey {
        case filesToTransfer = "FilesToTransfer"
        case emptyFoldersToTransfer = "EmptyFoldersToTransfer"
        case totalNumberFolders = "TotalNumberFolders"
        case machineID = "MachineID"
        case ask = "Ask"
        case sendingText = "SendingText"
        case noCompress = "NoCompress"
        case hashAlgorithm = "HashAlgorithm"
    }

    init(
        filesToTransfer: [CrocFileInfo],
        emptyFoldersToTransfer: [CrocFileInfo],
        totalNumberFolders: Int,
        machineID: String,
        ask: Bool,
        sendingText: Bool,
        noCompress: Bool,
        hashAlgorithm: String
    ) {
        self.filesToTransfer = filesToTransfer
        self.emptyFoldersToTransfer = emptyFoldersToTransfer
        self.totalNumberFolders = totalNumberFolders
        self.machineID = machineID
        self.ask = ask
        self.sendingText = sendingText
        self.noCompress = noCompress
        self.hashAlgorithm = hashAlgorithm
    }

    /// Custom decoder: Go encodes nil slices as JSON `null`, which Swift's
    /// auto-synthesized Codable rejects for non-optional `[T]` fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filesToTransfer = try c.decodeIfPresent([CrocFileInfo].self, forKey: .filesToTransfer) ?? []
        emptyFoldersToTransfer = try c.decodeIfPresent([CrocFileInfo].self, forKey: .emptyFoldersToTransfer) ?? []
        totalNumberFolders = try c.decodeIfPresent(Int.self, forKey: .totalNumberFolders) ?? 0
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
        ask = try c.decodeIfPresent(Bool.self, forKey: .ask) ?? false
        sendingText = try c.decodeIfPresent(Bool.self, forKey: .sendingText) ?? false
        noCompress = try c.decodeIfPresent(Bool.self, forKey: .noCompress) ?? false
        hashAlgorithm = try c.decodeIfPresent(String.self, forKey: .hashAlgorithm) ?? "xxhash"
    }
}

/// Request from the receiver specifying which chunks are needed.
nonisolated struct CrocRemoteFileRequest: Codable, Sendable {
    var currentFileChunkRanges: [Int64]
    var filesToTransferCurrentNum: Int
    var machineID: String

    enum CodingKeys: String, CodingKey {
        case currentFileChunkRanges = "CurrentFileChunkRanges"
        case filesToTransferCurrentNum = "FilesToTransferCurrentNum"
        case machineID = "MachineID"
    }

    init(currentFileChunkRanges: [Int64], filesToTransferCurrentNum: Int, machineID: String) {
        self.currentFileChunkRanges = currentFileChunkRanges
        self.filesToTransferCurrentNum = filesToTransferCurrentNum
        self.machineID = machineID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentFileChunkRanges = try c.decodeIfPresent([Int64].self, forKey: .currentFileChunkRanges) ?? []
        filesToTransferCurrentNum = try c.decodeIfPresent(Int.self, forKey: .filesToTransferCurrentNum) ?? 0
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
    }
}

/// Simple message used during PAKE IP exchange.
nonisolated struct CrocSimpleMessage: Codable, Sendable {
    var bytes: Data?
    var kind: String

    enum CodingKeys: String, CodingKey {
        case bytes = "Bytes"
        case kind = "Kind"
    }
}

#endif
