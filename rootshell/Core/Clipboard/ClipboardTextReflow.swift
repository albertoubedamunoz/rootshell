//
//  ClipboardTextReflow.swift
//  rootshell
//
//  Paragraph-aware reflow for the clipboard manager's Lines transforms.
//  `unwrap` removes the fixed line breaks inside a paragraph so the text
//  flows again; `wrap` re-fills each paragraph to a column budget measured
//  in terminal display cells. Both leave document structure alone: blank
//  lines, lists, block quotes, fenced and indented code, headings, rules
//  and tables survive the round trip.
//
//  nonisolated because the transforms run off the main actor.
//

import Foundation

nonisolated enum ClipboardTextReflow {

    // MARK: - Public API

    /// Joins the hard-wrapped lines of each paragraph into one long line.
    /// Throws `CancellationError` if the calling task is cancelled mid-run.
    static func unwrap(_ text: String) throws -> String {
        try process(text, columns: nil)
    }

    /// Unwraps first, then re-fills each paragraph to `columns` display cells.
    /// Throws `CancellationError` if the calling task is cancelled mid-run.
    static func wrap(_ text: String, columns: Int) throws -> String {
        try process(text, columns: max(1, columns))
    }

    /// How often the O(n) loops below poll for cancellation. Entries run to a
    /// megabyte, so a run has to be abandonable partway rather than only having
    /// its result discarded. The whole-string preamble (CRLF probe, line split,
    /// per-line trim) runs before the first poll, which at the 1 MiB entry cap
    /// bounds cancellation latency at roughly 30ms even for a single-line entry.
    private static let cancellationCheckInterval = 512

    // MARK: - Pipeline

    /// A run of source lines that share one handling rule.
    private enum Block {
        /// Run of blank lines, emitted verbatim (paragraph separators).
        case blank(count: Int)
        /// Never joined, never wrapped: code, tables, headings, rules.
        case verbatim([String])
        /// A paragraph or list item. `segments` are the runs between explicit
        /// (markdown hard) breaks; each is joined into a single logical line.
        /// The two prefixes always have the same display width, so one column
        /// budget covers every output line of the block.
        case prose(firstPrefix: String, contPrefix: String, segments: [ProseSegment])
    }

    /// One run of source lines inside a paragraph, up to an explicit break.
    private struct ProseSegment {
        var lines: [String] = []
        /// The markdown hard-break marker that ended this segment (two spaces),
        /// re-attached on render so the break keeps its meaning.
        var hardBreakSuffix = ""
    }

    private static func process(_ text: String, columns: Int?) throws -> String {
        guard !text.isEmpty else { return text }

        let usesCRLF = text.contains("\r\n")
        var working = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        let hadTrailingNewline = working.hasSuffix("\n")
        if hadTrailingNewline { working.removeLast() }

        let blocks = try parse(working.components(separatedBy: "\n"))
        var output = try render(blocks, columns: columns).joined(separator: "\n")

        if hadTrailingNewline { output += "\n" }
        if usesCRLF { output = output.replacingOccurrences(of: "\n", with: "\r\n") }
        return output
    }

    // MARK: - Parsing

    private static func parse(_ lines: [String]) throws -> [Block] {
        var blocks: [Block] = []
        var blankRun = 0
        var verbatimRun: [String] = []
        var fence: (marker: Character, length: Int, quoteDepth: Int)?

        var hasProse = false
        var proseFirstPrefix = ""
        var proseContPrefix = ""
        var proseQuotePrefix = ""
        var proseSegments: [ProseSegment] = []

        // Pipe tables are found up front: the pipe-less form ("Name | Value"
        // over "--- | ---") is only recognisable from the delimiter row, which
        // the single forward pass below reaches after the header line.
        let tableIndices = try tableLineIndices(lines)

        func flushBlank() {
            guard blankRun > 0 else { return }
            blocks.append(.blank(count: blankRun))
            blankRun = 0
        }

        func flushVerbatim() {
            guard !verbatimRun.isEmpty else { return }
            blocks.append(.verbatim(verbatimRun))
            verbatimRun = []
        }

        func closeProse() {
            guard hasProse else { return }
            let segments = proseSegments.filter { !$0.lines.isEmpty }
            if !segments.isEmpty {
                blocks.append(.prose(
                    firstPrefix: proseFirstPrefix,
                    contPrefix: proseContPrefix,
                    segments: segments
                ))
            }
            hasProse = false
            proseSegments = []
        }

        for (index, raw) in lines.enumerated() {
            if index.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

            // The block-quote prefix comes off before anything is classified:
            // a quoted fence, table or heading ("> ```swift") is that
            // structure, not prose, and joining it would corrupt the block.
            let parts = splitLinePrefixes(line)
            let quotePrefix = parts.quote
            let prefix = parts.indent + parts.quote + parts.innerIndent
            // Indentation that counts when classifying content: outside a quote
            // that is the line's own indent, inside one it is the indent after
            // the marker. It has to survive into `unquoted`, since the fence
            // and indented-code rules are both defined in terms of it.
            let contentIndent = quotePrefix.isEmpty ? parts.indent : parts.innerIndent
            let unquoted = contentIndent + parts.body

            // Inside a fence everything is verbatim until the closing marker.
            // The fence belongs to the block quote it was opened in, so the
            // comparison is by quote depth: a deeper or equal line is content
            // (a `> ```` line inside a top-level fence is just text), while a
            // shallower one means the containing quote has ended and the fence
            // with it, rather than swallowing the rest of the entry. Depth, not
            // the literal prefix, because a blank line inside a quoted fence is
            // written ">" and its content lines "> ".
            let depth = quoteDepth(quotePrefix)
            if let open = fence {
                if depth >= open.quoteDepth {
                    verbatimRun.append(line)
                    if depth == open.quoteDepth,
                       isFenceClose(unquoted, marker: open.marker, length: open.length) {
                        fence = nil
                    }
                    continue
                }
                fence = nil
            }

            if let opener = fenceOpener(unquoted) {
                closeProse()
                flushBlank()
                fence = (opener.marker, opener.length, depth)
                verbatimRun.append(line)
                continue
            }

            if quotePrefix.isEmpty, parts.body.isEmpty {
                closeProse()
                flushVerbatim()
                blankRun += 1
                continue
            }

            // Every content line ends any pending blank run.
            flushBlank()

            // A bare "> " is a separator inside the quote, not content.
            if parts.body.isEmpty {
                closeProse()
                verbatimRun.append(line)
                continue
            }

            var rest = parts.body

            // Indented code: 4+ columns of indent (inside the quote, if any)
            // with no paragraph open to continue. The open-paragraph check
            // comes first because list continuation lines are indented too.
            if !hasProse, indentWidth(contentIndent) >= 4 {
                verbatimRun.append(line)
                continue
            }

            // Table rows, ATX headings, thematic breaks and setext underlines
            // pass through untouched (and close the paragraph above them, so an
            // underline stays attached to its heading text).
            if rest.hasPrefix("|") || tableIndices.contains(index) || rest.hasPrefix("#") || isRule(rest) {
                closeProse()
                verbatimRun.append(line)
                continue
            }

            flushVerbatim()

            // Entering or leaving a quote (or changing its depth) starts a new
            // paragraph: the prefix is part of every output line.
            if hasProse, quotePrefix != proseQuotePrefix {
                closeProse()
            }

            if let marker = listMarker(rest) {
                closeProse()
                proseFirstPrefix = prefix + marker
                // Hanging indent: continuation lines align under the item text.
                proseContPrefix = prefix + String(repeating: " ", count: DisplayWidth.width(of: marker))
                proseQuotePrefix = quotePrefix
                proseSegments = [ProseSegment()]
                hasProse = true
                rest = String(rest.dropFirst(marker.count))
            } else if !hasProse {
                proseFirstPrefix = prefix
                proseContPrefix = prefix
                proseQuotePrefix = quotePrefix
                proseSegments = [ProseSegment()]
                hasProse = true
            }

            // A markdown hard break (two trailing spaces, or a trailing
            // backslash) ends the logical line but keeps the paragraph open.
            // Both markers are carried through: the two spaces are re-attached
            // on render (without them the break degrades to a soft one), and
            // the backslash simply survives the trim, so a shell continuation
            // sitting in a paragraph is not broken.
            let spaceHardBreak = rest.hasSuffix("  ")
            let hardBreak = spaceHardBreak || rest.hasSuffix("\\")
            let content = rest.trimmingCharacters(in: .whitespaces)
            if !content.isEmpty, !proseSegments.isEmpty {
                proseSegments[proseSegments.count - 1].lines.append(content)
            }
            if hardBreak {
                if spaceHardBreak, !proseSegments.isEmpty {
                    proseSegments[proseSegments.count - 1].hardBreakSuffix = "  "
                }
                proseSegments.append(ProseSegment())
            }
        }

        closeProse()
        flushVerbatim()
        flushBlank()
        return blocks
    }

    // MARK: - Rendering

    private static func render(_ blocks: [Block], columns: Int?) throws -> [String] {
        var output: [String] = []
        for (index, block) in blocks.enumerated() {
            if index.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            switch block {
            case .blank(let count):
                output.append(contentsOf: Array(repeating: "", count: count))

            case .verbatim(let lines):
                output.append(contentsOf: lines)

            case .prose(let firstPrefix, let contPrefix, let segments):
                // Both prefixes share a display width by construction, so one
                // budget is right for every line of the block.
                let budget = columns.map { max(1, $0 - DisplayWidth.width(of: firstPrefix)) }
                var isFirst = true
                for segment in segments {
                    let joined = try joinSegment(segment.lines)
                    guard !joined.isEmpty else { continue }
                    var pieces = try budget.map { try fill(joined, width: $0) } ?? [joined]
                    if !segment.hardBreakSuffix.isEmpty, !pieces.isEmpty {
                        // The marker is part of the line, so it has to fit
                        // inside the budget too. Only the final line can
                        // overflow, and re-filling just that line at the
                        // reduced width leaves the earlier ones alone.
                        let suffixWidth = DisplayWidth.width(of: segment.hardBreakSuffix)
                        if let budget, let last = pieces.last,
                           DisplayWidth.width(of: last) + suffixWidth > budget {
                            pieces.removeLast()
                            pieces.append(contentsOf: try fill(last, width: max(1, budget - suffixWidth)))
                        }
                        pieces[pieces.count - 1] += segment.hardBreakSuffix
                    }
                    for piece in pieces {
                        output.append((isFirst ? firstPrefix : contPrefix) + piece)
                        isFirst = false
                    }
                }
            }
        }
        return output
    }

    /// Joins the source lines of one paragraph segment with single spaces,
    /// closing up hyphenated breaks and never inserting a space between two
    /// CJK characters (that text has no inter-word spaces to restore).
    /// Polls for cancellation: on the unwrap path this is the only per-source-
    /// line loop after parsing, since nothing calls `fill` to poll on its behalf.
    private static func joinSegment(_ parts: [String]) throws -> String {
        var result = ""
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if index.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            guard !result.isEmpty else {
                result = part
                continue
            }
            let last = result.last
            let next = part.first
            if let last, let next {
                if isHyphenBreak(result, next: next) || (isCJK(last) && isCJK(next)) {
                    result += part
                    continue
                }
            }
            result += " " + part
        }
        return result
    }

    /// A line break falling on a hyphen ("run-" + "ning", "client-" + "side").
    /// The two halves are closed up so no space is injected mid-word, but the
    /// hyphen is KEPT: discretionary PDF hyphenation and a real compound-word
    /// hyphen are indistinguishable here, and dropping it would silently
    /// rewrite "client-side" as "clientside". Requires an alphanumeric on both
    /// sides, so "pass --" + "flag" and "wait -" + "then" still take a space.
    private static func isHyphenBreak(_ accumulated: String, next: Character) -> Bool {
        guard accumulated.hasSuffix("-"), !accumulated.hasSuffix("--") else { return false }
        guard let before = accumulated.dropLast().last,
              before.isLetter || before.isNumber else { return false }
        return next.isLetter || next.isNumber
    }

    // MARK: - Wrapping

    /// One unbreakable unit of a wrapped line: a word, or a single CJK
    /// character (CJK paragraphs have no spaces to break at).
    private struct WrapUnit {
        let text: String
        let width: Int
        /// The exact whitespace this unit followed. Replayed when the unit
        /// stays on the current line, dropped when it starts a new one, so
        /// wrapping never rewrites intra-line spacing or turns a tab into a
        /// space (`printf 'a  b'` survives a wrap that does not split it).
        let separator: String
    }

    /// Greedy fill to `width` display cells.
    private static func fill(_ text: String, width: Int) throws -> [String] {
        var lines: [String] = []
        var line = ""
        var lineWidth = 0

        for (index, unit) in try wrapUnits(text).enumerated() {
            if index.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            let separatorWidth = line.isEmpty ? 0 : advanceWidth(of: unit.separator, from: lineWidth)
            if lineWidth + separatorWidth + unit.width <= width {
                if !line.isEmpty {
                    line += unit.separator
                    lineWidth += separatorWidth
                }
                line += unit.text
                lineWidth += unit.width
                continue
            }

            if !line.isEmpty {
                lines.append(line)
                line = ""
                lineWidth = 0
            }

            if unit.width <= width {
                line = unit.text
                lineWidth = unit.width
                continue
            }

            // Hard-split a unit too wide for a line of its own, in one forward
            // pass: a megabyte-long base64 blob is a single unit, so anything
            // that rescans the remainder per emitted line is quadratic. Slicing
            // is per grapheme, so a wide character that would overflow by a
            // cell moves to the next line rather than being split. An empty
            // piece always accepts a character, which guarantees progress even
            // when the budget is narrower than one grapheme.
            var piece = ""
            var pieceWidth = 0
            for character in unit.text {
                let characterWidth = DisplayWidth.width(of: character)
                if !piece.isEmpty, pieceWidth + characterWidth > width {
                    // The whole megabyte blob is one unit, so the loop above
                    // never polls during a split. Poll per emitted line here.
                    if lines.count.isMultiple(of: cancellationCheckInterval) {
                        try Task.checkCancellation()
                    }
                    lines.append(piece)
                    piece = ""
                    pieceWidth = 0
                }
                piece.append(character)
                pieceWidth += characterWidth
            }
            line = piece
            lineWidth = pieceWidth
        }

        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [""] : lines
    }

    /// Display cells a whitespace run occupies starting at `column`, with tabs
    /// advancing to the next 4-column stop.
    private static func advanceWidth(of whitespace: String, from column: Int) -> Int {
        var width = 0
        for character in whitespace {
            if character == "\t" {
                width += 4 - ((column + width) % 4)
            } else {
                width += DisplayWidth.width(of: character)
            }
        }
        return width
    }

    /// Tokenising walks the whole paragraph before `fill` emits its first line,
    /// so this is the longest single stretch of work in a run and polls too.
    private static func wrapUnits(_ text: String) throws -> [WrapUnit] {
        var units: [WrapUnit] = []
        var buffer = ""
        var bufferSeparator = ""
        var separator = ""
        var scanned = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            units.append(WrapUnit(text: buffer, width: DisplayWidth.width(of: buffer), separator: bufferSeparator))
            buffer = ""
            bufferSeparator = ""
        }

        for character in text {
            scanned += 1
            if scanned.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            if character.isWhitespace {
                flushBuffer()
                separator.append(character)
                continue
            }
            if isCJK(character) {
                flushBuffer()
                units.append(WrapUnit(
                    text: String(character),
                    width: DisplayWidth.width(of: character),
                    separator: separator
                ))
                separator = ""
                continue
            }
            if buffer.isEmpty {
                bufferSeparator = separator
                separator = ""
            }
            buffer.append(character)
        }
        flushBuffer()
        return units
    }

    // MARK: - Line classification helpers

    /// Display columns occupied by an indent, expanding tabs to 4-column stops.
    private static func indentWidth(_ indent: String) -> Int {
        var width = 0
        for character in indent {
            if character == "\t" {
                width += 4 - (width % 4)
            } else {
                width += 1
            }
        }
        return width
    }

    /// The marker and run length of an opening fence. The length matters: a
    /// three-backtick line inside a four-backtick fence is content, not a
    /// close, so a fenced block that itself shows fenced markdown stays intact.
    /// Indented 4+ columns it is not a fence at all but a line of indented
    /// code, which is checked later and must not be swallowed here.
    private static func fenceOpener(_ line: String) -> (marker: Character, length: Int)? {
        guard leadingIndentWidth(line) < 4 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        var length = 0
        for character in trimmed {
            guard character == marker else { break }
            length += 1
        }
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    /// A closing fence: the same marker, at least as long as the opener,
    /// nothing else on the line, and indented less than 4 columns (deeper than
    /// that it is code inside the block, matching the opener rule).
    private static func isFenceClose(_ line: String, marker: Character, length: Int) -> Bool {
        guard leadingIndentWidth(line) < 4 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= length && trimmed.allSatisfy { $0 == marker }
    }

    private static func leadingIndentWidth(_ line: String) -> Int {
        indentWidth(String(line.prefix { $0 == " " || $0 == "\t" }))
    }

    /// Line indices belonging to a pipe table. A leading `|` is handled inline;
    /// this finds the pipe-less form ("Name | Value" over "--- | ---") from its
    /// delimiter row, which is the only unambiguous marker. Anchoring on the
    /// delimiter row keeps prose that merely contains a pipe (a shell pipeline,
    /// say) out of the table set.
    private static func tableLineIndices(_ lines: [String]) throws -> Set<Int> {
        var indices = Set<Int>()
        var index = 0
        while index < lines.count {
            if index.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
            guard isTableDelimiterRow(lines[index]), index > 0, lines[index - 1].contains("|") else {
                index += 1
                continue
            }
            indices.insert(index - 1)
            indices.insert(index)
            var next = index + 1
            while next < lines.count, lines[next].contains("|") {
                // Polls too: the outer loop skips everything this scan claims,
                // so on a single table spanning the whole entry this is the
                // only loop running.
                if next.isMultiple(of: cancellationCheckInterval) { try Task.checkCancellation() }
                indices.insert(next)
                next += 1
            }
            // Resume past the table rather than at index + 1. A table whose
            // every row looks like a delimiter ("--- | ---" repeated) would
            // otherwise re-scan the remainder once per row, which is quadratic
            // and, at the 1 MiB entry cap, effectively a hang.
            index = next
        }
        return indices
    }

    /// The `--- | :-: | ---:` row under a table header, with or without the
    /// outer pipes.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // Quoted tables are tables: drop the "> " before reading the cells.
        if trimmed.hasPrefix(">") {
            trimmed = splitQuotePrefix(trimmed).rest.trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.contains("|") else { return false }
        var cells = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// A thematic break or a setext heading underline. Thematic breaks are
    /// three or more of one marker and may be spaced apart ("- - -", "* * *");
    /// setext underlines are a run of `=` or `-` with nothing else on the line
    /// and may be as short as a single character.
    private static func isRule(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "-=*_".contains(first) else { return false }
        var markers = 0
        var spaced = false
        for character in trimmed {
            if character == first {
                markers += 1
            } else if character == " " || character == "\t" {
                spaced = true
            } else {
                return false
            }
        }
        if markers >= 3 { return true }
        return !spaced && (first == "=" || first == "-")
    }

    /// Splits a source line into its leading indent, an optional block-quote
    /// prefix, the indentation inside that quote, and the remaining text.
    /// `indent + quote + innerIndent` is the prefix every output line of the
    /// resulting block carries; `innerIndent + body` is what gets classified.
    private static func splitLinePrefixes(
        _ line: String
    ) -> (indent: String, quote: String, innerIndent: String, body: String) {
        let indentEnd = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        let indent = String(line[line.startIndex..<indentEnd])
        var remainder = String(line[indentEnd...])

        var quote = ""
        if remainder.hasPrefix(">") {
            let split = splitQuotePrefix(remainder)
            quote = split.prefix
            remainder = split.rest
        }

        let innerEnd = remainder.firstIndex { !$0.isWhitespace } ?? remainder.endIndex
        let innerIndent = String(remainder[remainder.startIndex..<innerEnd])
        return (indent, quote, innerIndent, String(remainder[innerEnd...]))
    }

    /// Block-quote nesting level of a prefix. Counting markers rather than
    /// comparing prefixes means ">" and "> " read as the same level.
    private static func quoteDepth(_ prefix: String) -> Int {
        prefix.reduce(0) { $0 + ($1 == ">" ? 1 : 0) }
    }

    /// Splits a leading block-quote prefix off a line. Each `>` may carry one
    /// space, so the spaced nesting form ("> > inner") is consumed whole rather
    /// than leaving the inner marker to be joined into the text as content.
    private static func splitQuotePrefix(_ text: String) -> (prefix: String, rest: String) {
        var index = text.startIndex
        while index < text.endIndex, text[index] == ">" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
            }
        }
        return (String(text[text.startIndex..<index]), String(text[index...]))
    }

    /// Returns the leading list marker including its trailing spaces ("- ",
    /// "12. ", "a) "), or nil when the line does not start a list item.
    private static func listMarker(_ text: String) -> String? {
        let bullets: Set<Character> = ["-", "*", "+", "•", "‣"]
        var index = text.startIndex

        if let first = text.first, bullets.contains(first) {
            index = text.index(after: index)
        } else {
            var cursor = text.startIndex
            var count = 0
            while cursor < text.endIndex, text[cursor].isNumber, count < 9 {
                count += 1
                cursor = text.index(after: cursor)
            }
            if count == 0, let first = text.first, first.isLetter, first.isASCII {
                cursor = text.index(after: text.startIndex)
                count = 1
            }
            guard count > 0, cursor < text.endIndex,
                  text[cursor] == "." || text[cursor] == ")" else { return nil }
            index = text.index(after: cursor)
        }

        // A marker needs whitespace and then some content after it.
        guard index < text.endIndex, text[index] == " " || text[index] == "\t" else { return nil }
        while index < text.endIndex, text[index] == " " || text[index] == "\t" {
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        return String(text[text.startIndex..<index])
    }

    /// CJK ideographs, kana and Hangul. Deliberately not "is this 2 cells
    /// wide": emoji are also wide, but lines broken between emoji do want the
    /// space back when they are joined.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x115F,      // Hangul Jamo
             0x2E80...0x303E,      // CJK radicals, Kangxi, CJK symbols and punctuation
             0x3041...0x33FF,      // kana, Bopomofo, Hangul compatibility jamo, CJK compatibility
             0x3400...0x4DBF,      // CJK unified ideographs extension A
             0x4E00...0x9FFF,      // CJK unified ideographs
             0xA000...0xA4CF,      // Yi
             0xAC00...0xD7A3,      // Hangul syllables
             0xF900...0xFAFF,      // CJK compatibility ideographs
             0xFE30...0xFE4F,      // CJK compatibility forms
             0xFF00...0xFF60,      // fullwidth forms
             0xFFE0...0xFFE6,
             0x20000...0x2FA1F:    // CJK extension B and beyond
            return true
        default:
            return false
        }
    }
}
