#if !CHINA_BUILD
//
//  MarkdownAttributedStringBuilder.swift
//  rootshell
//
//  Converts markdown text to NSAttributedString for UITextView rendering.
//  Uses SimpleMarkdownParser for block-level parsing and NSAttributedString
//  for inline markdown (bold, italic, code, links).
//

import UIKit

/// Converts markdown text to NSAttributedString with proper styling
/// Uses monospace fonts throughout for consistent table/ASCII alignment
/// Supports Dynamic Type for accessibility compliance
enum MarkdownAttributedStringBuilder {

    // MARK: - Public API

    /// Build attributed string from markdown text
    /// - Parameter markdown: Raw markdown text
    /// - Returns: NSAttributedString with proper styling for UITextView
    static func build(from markdown: String) -> NSAttributedString {
        let blocks = SimpleMarkdownParser.parse(markdown)
        let result = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                // Add paragraph spacing between blocks
                result.append(NSAttributedString(string: "\n\n"))
            }

            switch block.content {
            case .header(let level, let text):
                result.append(buildHeader(level: level, text: text))

            case .codeBlock(_, let code):
                result.append(buildCodeBlock(code: code))

            case .table(let headers, let rows):
                // Tables are rendered separately by MarkdownTableView
                // Fallback: render as plain text for contexts that don't support table views
                result.append(buildTableFallback(headers: headers, rows: rows))

            case .paragraph(let text):
                result.append(buildParagraph(text: text))
            }
        }

        return result
    }

    // MARK: - Tab Stop Configuration

    /// Create paragraph style with terminal-standard tab stops (8 characters)
    /// UITextView uses default ~28pt tab stops which don't align with monospace fonts
    /// Public so streaming views can use proper tab stops during incremental rendering
    static func terminalParagraphStyle(font: UIFont, spacing: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing

        // Prevent character spacing compression - critical for monospace alignment
        style.allowsDefaultTighteningForTruncation = false
        style.lineBreakMode = .byWordWrapping
        style.hyphenationFactor = 0  // Disable hyphenation

        // Calculate character width for monospace font using "M" (widest char, matches em-width)
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

        // Terminal standard: tabs every 8 characters
        let tabInterval = charWidth * 8

        // Create tab stops (UITextView needs explicit stops for reliable rendering)
        var tabStops: [NSTextTab] = []
        for i in 1...20 {  // 20 tab stops covers tables up to ~160 characters wide
            tabStops.append(NSTextTab(textAlignment: .left, location: tabInterval * CGFloat(i)))
        }
        style.tabStops = tabStops
        style.defaultTabInterval = tabInterval

        return style
    }

    // MARK: - Block Builders

    /// Build attributed string for a header (monospace, bold)
    /// Strips inline bold/italic markers since headers are already bold
    static func buildHeader(level: Int, text: String) -> NSAttributedString {
        // Strip ** and * markers from header text (headers are already bold)
        let cleanedText = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")

        // Use Dynamic Type scaled header font
        let font = AIAgentFonts.uiHeader(level: level)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: terminalParagraphStyle(font: font, spacing: 4),
            .kern: 0,  // Disable font kerning for consistent monospace spacing
            .ligature: 0  // Disable ligatures for consistent character width
        ]

        return NSAttributedString(string: cleanedText, attributes: attributes)
    }

    /// Build attributed string for a code block (monospace with background)
    static func buildCodeBlock(code: String) -> NSAttributedString {
        // Use Dynamic Type scaled code font
        let font = AIAgentFonts.uiCodeBody

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .backgroundColor: UIColor.tertiarySystemBackground,
            .paragraphStyle: terminalParagraphStyle(font: font, spacing: 4),
            .kern: 0,  // Disable font kerning for consistent monospace spacing
            .ligature: 0  // Disable ligatures for consistent character width
        ]

        return NSAttributedString(string: code, attributes: attributes)
    }

    /// Build attributed string for a paragraph with inline markdown (monospace)
    static func buildParagraph(text: String) -> NSAttributedString {
        // Use custom inline markdown parsing for reliable bold/italic handling
        return parseInlineMarkdown(text)
    }

    /// Fallback rendering for tables as plain text
    /// Used when table view is not available (e.g., in some contexts that use build())
    private static func buildTableFallback(headers: [String], rows: [[String]]) -> NSAttributedString {
        let font = AIAgentFonts.uiCodeBody
        let paragraphStyle = terminalParagraphStyle(font: font)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle,
            .kern: 0,
            .ligature: 0
        ]

        // Reconstruct table as plain text
        var text = "| " + headers.joined(separator: " | ") + " |\n"
        text += "|" + headers.map { _ in "---" }.joined(separator: "|") + "|\n"
        for row in rows {
            text += "| " + row.joined(separator: " | ") + " |\n"
        }

        return NSAttributedString(string: text.trimmingCharacters(in: .newlines), attributes: attributes)
    }

    /// Parse inline markdown (bold, inline code) manually for reliable rendering
    /// NSAttributedString(markdown:) can be unreliable with certain patterns
    /// Public so streaming views can use it too
    /// Uses Dynamic Type scaled fonts for accessibility
    static func parseInlineMarkdown(_ text: String, baseFont: UIFont? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = baseFont ?? AIAgentFonts.uiCodeBody
        let boldFont = baseFont != nil
            ? UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: font.pointSize)
            : AIAgentFonts.uiCodeBodyBold
        let paragraphStyle = terminalParagraphStyle(font: font)

        // Process text character by character, handling ** for bold
        var remaining = text[...]
        var currentText = ""

        while !remaining.isEmpty {
            // Check for bold marker **
            if remaining.hasPrefix("**") {
                // Flush current text as regular
                if !currentText.isEmpty {
                    result.append(NSAttributedString(string: currentText, attributes: [
                        .font: font,
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: paragraphStyle,
                        .kern: 0,
                        .ligature: 0
                    ]))
                    currentText = ""
                }

                // Find closing **
                let afterOpening = remaining.dropFirst(2)
                if let closeRange = afterOpening.range(of: "**") {
                    let boldText = String(afterOpening[..<closeRange.lowerBound])
                    result.append(NSAttributedString(string: boldText, attributes: [
                        .font: boldFont,
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: paragraphStyle,
                        .kern: 0,
                        .ligature: 0
                    ]))
                    remaining = afterOpening[closeRange.upperBound...]
                } else {
                    // No closing **, treat as literal
                    currentText += "**"
                    remaining = afterOpening
                }
            }
            // Check for inline code `
            else if remaining.hasPrefix("`") {
                // Flush current text
                if !currentText.isEmpty {
                    result.append(NSAttributedString(string: currentText, attributes: [
                        .font: font,
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: paragraphStyle,
                        .kern: 0,
                        .ligature: 0
                    ]))
                    currentText = ""
                }

                // Find closing `
                let afterOpening = remaining.dropFirst(1)
                if let closeIndex = afterOpening.firstIndex(of: "`") {
                    let codeText = String(afterOpening[..<closeIndex])
                    result.append(NSAttributedString(string: codeText, attributes: [
                        .font: font,
                        .foregroundColor: UIColor.label,
                        .backgroundColor: UIColor.tertiarySystemBackground,
                        .paragraphStyle: paragraphStyle,
                        .kern: 0,
                        .ligature: 0
                    ]))
                    remaining = afterOpening[afterOpening.index(after: closeIndex)...]
                } else {
                    // No closing `, treat as literal
                    currentText += "`"
                    remaining = afterOpening
                }
            }
            else {
                // Regular character
                currentText.append(remaining.removeFirst())
            }
        }

        // Flush remaining text
        if !currentText.isEmpty {
            result.append(NSAttributedString(string: currentText, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle,
                .kern: 0,
                .ligature: 0
            ]))
        }

        return result
    }
}
#endif
