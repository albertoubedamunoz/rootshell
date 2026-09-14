import Foundation

/// The UIKit document is not a terminal screen. Only its explicitly attributed
/// suffix may be rewritten by direct keyboard assistance. Dictation owns a
/// separate suffix region for the bytes it sent itself. IME retains its own
/// document responsibilities. Eligibility ends at explicit input boundaries or
/// suffix truncation, never merely because typing pauses.
nonisolated struct TerminalCorrectionContext {
    enum Mutation {
        case text(String, eligible: Bool)
        case backspace(eligible: Bool)
        case legacyDocument(String)
        case correction(Replacement)
        case reset
        case invalidate
        case dictationBegan
        case dictationText(String)
        case dictationSettling
        case dictationEnded
        /// Live dictation may deliver with no signal at all: a plain insert,
        /// then a replace of exactly that inserted range. Adopt it.
        case dictationAdopt(NSRange)
    }

    /// Dictation authority is a session id stamped into UIKit positions plus a
    /// suffix region. No clock participates; lifecycle callbacks are async.
    struct DictationSession: Equatable {
        enum Phase: Equatable { case receiving, settling }
        let id: UInt64
        var phase: Phase
        var regionStart: Int
    }

    struct Replacement {
        let payload: Data
        let document: String
        let replayRange: NSRange
        let eligibleUTF16Count: Int
        let generation: UInt64
        let documentGeneration: UInt64
        let dictationID: UInt64?
    }

    private(set) var document = ""
    private(set) var generation: UInt64 = 0
    private(set) var documentGeneration: UInt64 = 0
    private(set) var eligibleUTF16Count = 0
    private(set) var dictation: DictationSession?
    /// Range written by the latest append or correction; any other edit clears it.
    private(set) var recentEditRange: NSRange?
    private var dictationCounter: UInt64 = 0

    var dictationRegion: NSRange? {
        dictation.map { NSRange(location: $0.regionStart, length: document.utf16.count - $0.regionStart) }
    }

    var isReceivingDictation: Bool { dictation?.phase == .receiving }

    /// Adoption has no signal behind it, so the erased tail keeps the
    /// QuickType deletion safeguards. Length and replay stay unbounded:
    /// hypotheses run long and may replay a newline.
    func canAdoptDictation(in range: NSRange) -> Bool {
        guard dictation == nil, let recent = recentEditRange, range.length > 0,
              range.location >= recent.location, NSMaxRange(range) <= NSMaxRange(recent),
              let indices = Self.range(range, in: document) else { return false }
        let erased = document[indices.lowerBound...]
        return erased.allSatisfy({ $0.unicodeScalars.count == 1 }) && Self.isPrintable(String(erased))
    }

    static func range(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let result = Range(range, in: text),
              (result.lowerBound == text.endIndex || text.indices.contains(result.lowerBound)),
              (result.upperBound == text.endIndex || text.indices.contains(result.upperBound)) else { return nil }
        return result
    }

    static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            case .format:
                // Joiners and emoji tag sequences participate in legitimate
                // graphemes. Other invisible formatting controls are unsafe.
                return scalar.value != 0x200C && scalar.value != 0x200D
                    && !(0xE0020...0xE007F).contains(scalar.value)
            default:
                return false
            }
        }
    }

    /// Plain typing ends a settling session; explicit deliveries never do.
    /// Non-printable input is a boundary in either phase.
    func plainTextClosesDictation(_ text: String) -> Bool {
        guard let dictation else { return false }
        if !Self.isPrintable(text) { return true }
        return dictation.phase == .settling && text.count == 1
    }

    @discardableResult
    mutating func apply(_ mutation: Mutation) -> Bool {
        switch mutation {
        case .correction(let replacement):
            return commit(replacement)
        case .invalidate:
            invalidate()
        case .reset:
            resetDocument()
        case .legacyDocument(let text):
            endDictation()
            recentEditRange = nil
            document = text
            documentGeneration &+= 1
            invalidate()
        case .text(let text, let eligible):
            if text == "\r" || text == "\n" {
                resetDocument()
            } else {
                if plainTextClosesDictation(text) { endDictation() }
                append(text, eligible: eligible && dictation == nil)
            }
        case .dictationText(let text):
            if text == "\r" || text == "\n" {
                resetDocument()
            } else {
                if dictation == nil { beginDictation() }
                append(text, eligible: false)
            }
        case .dictationBegan:
            beginDictation()
        case .dictationSettling:
            dictation?.phase = .settling
        case .dictationEnded:
            recentEditRange = nil
            endDictation()
        case .dictationAdopt(let range):
            guard canAdoptDictation(in: range), let recent = recentEditRange else { return false }
            beginDictation(regionStart: recent.location)
        case .backspace(let eligible):
            recentEditRange = nil
            if let last = document.last {
                let removed = String(last).utf16.count
                document.removeLast()
                documentGeneration &+= 1
                if let session = dictation, document.utf16.count < session.regionStart {
                    endDictation()
                }
                if eligible, removed <= eligibleUTF16Count {
                    eligibleUTF16Count -= removed
                    generation &+= 1
                } else {
                    invalidate()
                }
            } else {
                invalidate()
            }
        }
        boundDocument()
        return true
    }

    private mutating func append(_ text: String, eligible: Bool) {
        let previousCount = document.utf16.count
        document += text
        let printable = Self.isPrintable(text)
        recentEditRange = printable ? NSRange(location: previousCount, length: document.utf16.count - previousCount) : nil
        if eligible && printable {
            eligibleUTF16Count += document.utf16.count - previousCount
        } else {
            invalidate()
        }
    }

    private mutating func resetDocument() {
        dictation = nil
        recentEditRange = nil
        document = ""
        documentGeneration &+= 1
        invalidate()
    }

    private mutating func beginDictation(regionStart: Int? = nil) {
        if dictation != nil {
            dictation?.phase = .receiving
            return
        }
        dictationCounter &+= 1
        dictation = DictationSession(id: dictationCounter, phase: .receiving,
                                     regionStart: regionStart ?? document.utf16.count)
        invalidate()
    }

    /// Closing changes document identity so every session-era position fails
    /// closed and the view re-reads the document.
    private mutating func endDictation() {
        guard dictation != nil else { return }
        dictation = nil
        documentGeneration &+= 1
        generation &+= 1
    }

    private mutating func invalidate() {
        guard eligibleUTF16Count > 0 else { return }
        eligibleUTF16Count = 0
        generation &+= 1
    }

    private mutating func boundDocument() {
        if document.utf16.count > 4096 {
            document = Self.suffix(document, maxUTF16: 2048)
            generation &+= 1
            documentGeneration &+= 1
            dictation = nil
            recentEditRange = nil
        }
        let bounded = Self.suffix(document, maxUTF16: min(128, eligibleUTF16Count)).utf16.count
        if bounded != eligibleUTF16Count { generation &+= 1 }
        eligibleUTF16Count = bounded
    }

    private static func suffix(_ text: String, maxUTF16: Int) -> String {
        var start = text.endIndex
        var count = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let units = text[previous..<start].utf16.count
            guard count + units <= maxUTF16 else { break }
            start = previous
            count += units
        }
        return String(text[start...])
    }

    func replacement(in range: NSRange, with text: String, generation expected: UInt64) -> Replacement? {
        guard expected == generation, eligibleUTF16Count > 0,
              let indices = Self.range(range, in: document) else { return nil }
        let erased = String(document[indices.lowerBound...])
        let replay = text + document[indices.upperBound...]
        guard range.location >= document.utf16.count - eligibleUTF16Count,
              erased.count + replay.count <= 64,
              // Remote editors disagree on scalar-vs-grapheme deletion.
              // Only rewrite a suffix where both counts agree. Inserting
              // complex graphemes is fine; erasing them is not portable.
              erased.allSatisfy({ $0.unicodeScalars.count == 1 }),
              Self.isPrintable(erased), Self.isPrintable(replay) else { return nil }
        var payload = Data(repeating: 0x7F, count: erased.count)
        payload.append(contentsOf: replay.utf8)
        let updated = String(document[..<indices.lowerBound]) + replay
        return Replacement(payload: payload, document: updated,
                           replayRange: NSRange(location: range.location, length: replay.utf16.count),
                           eligibleUTF16Count: eligibleUTF16Count - erased.utf16.count + replay.utf16.count,
                           generation: generation, documentGeneration: documentGeneration, dictationID: nil)
    }

    /// Dictation may only erase bytes it sent since the session opened.
    func dictationReplacement(in range: NSRange, with text: String, session id: UInt64) -> Replacement? {
        guard let dictation, dictation.id == id,
              range.location >= dictation.regionStart,
              let indices = Self.range(range, in: document) else { return nil }
        let erased = String(document[indices.lowerBound...])
        let replay = text + document[indices.upperBound...]
        var payload = Data(repeating: 0x7F, count: erased.count)
        payload.append(contentsOf: replay.replacingOccurrences(of: "\n", with: "\r").utf8)
        let updated = String(document[..<indices.lowerBound]) + replay
        return Replacement(payload: payload, document: updated,
                           replayRange: NSRange(location: range.location, length: replay.utf16.count),
                           eligibleUTF16Count: 0,
                           generation: generation, documentGeneration: documentGeneration, dictationID: id)
    }

    @discardableResult
    mutating func commit(_ replacement: Replacement) -> Bool {
        guard replacement.generation == generation,
              replacement.documentGeneration == documentGeneration,
              replacement.dictationID == nil || replacement.dictationID == dictation?.id else { return false }
        document = replacement.document
        documentGeneration &+= 1
        eligibleUTF16Count = replacement.eligibleUTF16Count
        generation &+= 1
        recentEditRange = replacement.replayRange
        // A non-dictation authority rewrote the document.
        if replacement.dictationID == nil { endDictation() }
        boundDocument()
        return true
    }
}
