//
//  AgentPromptSummary.swift
//  rootshell
//
//  Pulls the question an agent is waiting on out of its visible screen, so
//  a "needs input" notification can say what is actually being asked
//  instead of repeating the tab title.
//
//  Agent-independent by construction: it works on the shape of a prompt
//  (a sentence, above the choices, below the transcript) rather than on any
//  agent's wording. Every agent draws a dialog the same way (a question,
//  a list of choices, a key-hint footer), so the chrome tests below are
//  what generalise, not a needle list.
//
//  Only ever consulted while a pane is classified blocked, which is what
//  keeps ordinary transcript prose out of it.
//
//  Pure: no UIKit, no isolation, no manifest. Runs against the same rows
//  the detection rules see, and is covered by tests/agent-attention.
//

import Foundation

nonisolated enum AgentPromptSummary {

    /// How far up from the bottom to look. Wide enough to clear a wrapped
    /// footer and a long list of choices, short enough that transcript text
    /// above the dialog stays out of reach.
    private static let windowRows = 24

    /// How far above the choices the fallback may look for a heading.
    private static let headingRows = 10

    /// Hard ceiling on the returned string. A notification body shows about
    /// four lines; past that the tail is never read.
    private static let maxLength = 140

    /// Rows joined onto a question that soft-wrapped.
    private static let maxJoinedRows = 2

    /// A row only soft-wraps if it filled the width, so a short row above a
    /// question is a separate statement rather than its head.
    private static let wrapWidthFraction = 0.6

    /// The question the pane is waiting on, or nil when the screen carries
    /// nothing a person would recognise as one.
    ///
    /// `lines` are the rows the rules ran against, already border-peeled by
    /// `AgentDetectionInput`, so a pane inside tmux or zellij reads the same
    /// as a bare one. `cols` is the pane width, used only to tell a wrapped
    /// question from two separate lines; 0 means unknown and disables the
    /// join.
    static func summarize(lines: [String], cols: Int = 0) -> String? {
        let window = Array(lines.suffix(windowRows))
        guard !window.isEmpty else { return nil }

        // The question is the last sentence that asks something. Choices and
        // footers sit below it, so scanning up from the bottom finds the
        // live dialog rather than an answered one higher in the transcript.
        for index in window.indices.reversed() {
            guard let content = contentText(window[index]), content.hasSuffix("?") else { continue }
            return present(joiningWrap(at: index, in: window, tail: content, cols: cols))
        }

        // No question mark: plenty of dialogs state the request instead of
        // asking it ("Action required (1 left)", "Select Model"). The
        // heading of the block the choices belong to is that statement.
        return heading(above: window).flatMap(present)
    }

    // MARK: - Heading fallback

    /// Walks up from the last selectable row to the top of its block. A
    /// horizontal rule ends the block, which is what stops an agent's status
    /// bar or the transcript above from being read as the heading.
    private static func heading(above window: [String]) -> String? {
        guard let anchor = window.lastIndex(where: isSelectableRow) else { return nil }
        var heading: String?
        var cursor = anchor - 1
        var scanned = 0
        while cursor >= window.startIndex, scanned < headingRows {
            if isRule(window[cursor]) { break }
            if let content = contentText(window[cursor]) { heading = content }
            cursor -= 1
            scanned += 1
        }
        return heading
    }

    // MARK: - Wrapped questions

    /// Agents soft-wrap a long question across rows, so the row carrying the
    /// "?" is often only its tail. Walk back over rows that are directly
    /// adjacent (a blank line means a different block), wide enough to have
    /// wrapped, and unfinished (no sentence-ending punctuation).
    private static func joiningWrap(at index: Int, in window: [String], tail: String, cols: Int) -> String {
        guard cols > 0 else { return tail }
        let wrapWidth = Double(cols) * wrapWidthFraction
        var parts = [tail]
        var cursor = index - 1
        var joined = 0
        while cursor >= window.startIndex, joined < maxJoinedRows {
            guard let previous = contentText(window[cursor]) else { break }
            guard Double(previous.count) >= wrapWidth else { break }
            if let last = previous.last, ".?!:".contains(last) { break }
            parts.insert(previous, at: 0)
            joined += 1
            cursor -= 1
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Presentation

    private static func present(_ text: String) -> String? {
        let collapsed = collapseWhitespace(text)
        guard collapsed.count >= 4 else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        // Truncate on a word boundary so the body never ends mid-word.
        let clipped = collapsed.prefix(maxLength)
        if let space = clipped.lastIndex(of: " "),
           clipped.distance(from: clipped.startIndex, to: space) > maxLength / 2 {
            return String(clipped[..<space]) + "…"
        }
        return String(clipped) + "…"
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Chrome

    /// The row's prose, or nil when the row is chrome.
    private static func contentText(_ line: String) -> String? {
        let text = unboxed(line)
        guard !text.isEmpty else { return nil }
        guard !isRule(line) else { return nil }
        guard !isSelectableRow(line) else { return nil }
        guard !isMarkerRow(text) else { return nil }
        guard !isKeyHintRow(text) else { return nil }
        guard !isCounterRow(text) else { return nil }
        return text
    }

    /// Box sides that survived `AgentDetectionInput`'s peel: an agent's own
    /// panel inside an already-peeled multiplexer pane, or the far edge of a
    /// box whose near edge was peeled. Structure, not meaning: strip it and
    /// judge what it contains.
    private static let boxGlyphs: Set<Character> = ["│", "┃", "▌", "┆", "┊", "|"]

    private static func unboxed(_ line: String) -> String {
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" || boxGlyphs.contains(first) {
            rest = rest.dropFirst()
        }
        while let last = rest.last, last == " " || last == "\t" || boxGlyphs.contains(last) {
            rest = rest.dropLast()
        }
        return String(rest)
    }

    /// Every character is box drawing. Covers `───`, `┌───┐` and `╭───╮`
    /// alike, where `AgentDetectionRegions.isHorizontalRule` only knows the
    /// plain rule its own rules are anchored on.
    private static let ruleGlyphs: Set<Character> = [
        "─", "━", "│", "┃", "┄", "┅", "┆", "┈", "┉", "┊",
        "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼",
        "╭", "╮", "╰", "╯", "═", "║", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬",
        "▀", "▄", "▁", "▔", "▏", "▕", "_", "-", "=",
    ]

    private static func isRule(_ line: String) -> Bool {
        if AgentDetectionRegions.isHorizontalRule(line) { return true }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { ruleGlyphs.contains($0) || $0 == " " }
    }

    /// Prompt markers, selectors and status glyphs. Excluding these whole
    /// rows is what keeps the user's own typed input out of the body: their
    /// text always sits behind a prompt marker, a question they are being
    /// asked never does.
    private static let markerGlyphs: Set<Character> = [
        "❯", "›", ">", "⏵", "⏺", "»", "▶",
        "·", "•", "◦", "○", "◯", "●", "■", "✗", "✓", "☐", "□",
        "✢", "✳", "✶", "✻", "✽", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]

    /// Selector markers specifically: the glyph an agent puts against the
    /// row the arrow keys are currently on.
    private static let selectorGlyphs: Set<Character> = ["❯", "›", ">", "»", "▶", "*"]

    private static func isMarkerRow(_ text: String) -> Bool {
        guard let first = text.first else { return true }
        return markerGlyphs.contains(first)
    }

    /// A row the user can pick: a numbered choice ("1. Yes", "❯ 2. No") or
    /// any non-empty row behind a selector marker. These bound the heading
    /// search, because a dialog is exactly the block of prose above its choices.
    private static func isSelectableRow(_ line: String) -> Bool {
        var rest = Substring(unboxed(line))
        guard !rest.isEmpty else { return false }
        var hadSelector = false
        if let first = rest.first, selectorGlyphs.contains(first) {
            hadSelector = true
            rest = rest.dropFirst().drop(while: { $0 == " " })
            // A bare prompt marker is an empty input line, not a choice.
            if rest.isEmpty { return false }
        }
        if hadSelector { return true }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        let after = rest.dropFirst(digits.count)
        guard let separator = after.first, separator == "." || separator == ")" else { return false }
        return after.dropFirst().first == " "
    }

    /// Key-hint footers. Matched on the chord vocabulary rather than on any
    /// agent's phrasing, because the wording differs per agent and per
    /// terminal width while the chords do not.
    ///
    /// Every needle here is chord-anchored or a phrase that only ever
    /// appears in a footer. A bare verb like "to approve" or "to select"
    /// belongs to the question at least as often as to the footer (codex's
    /// own "Do you want to approve network access to ...?" was suppressed by
    /// exactly that), and the chord form catches the footer anyway.
    private static let hintNeedles = [
        "esc to", "enter to", "tab to", "space to", "ctrl+", "ctrl-", "shift+",
        "to cancel", "to submit", "to interrupt", "to skip", "for shortcuts",
        "↑/↓", "←/→", "↑↓",
    ]

    private static func isKeyHintRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return hintNeedles.contains { lower.contains($0) }
    }

    /// The agents' own status counters ("4m 30s · ↓ 58.2k tokens"). Never a
    /// question, and they change every second.
    private static func isCounterRow(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("tokens") && (lower.contains("↓") || lower.contains("↑"))
    }
}
