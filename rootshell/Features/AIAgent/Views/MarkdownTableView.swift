#if !CHINA_BUILD
//
//  MarkdownTableView.swift
//  rootshell
//
//  SwiftUI view for rendering markdown tables with proper column alignment.
//  Uses Grid layout to ensure columns align regardless of content width.
//

import SwiftUI
import UIKit

/// Renders a markdown table as a proper grid layout
/// Ensures columns align correctly even with emoji or variable-width content
struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    /// Observe font manager for consistent sizing
    @ObservedObject private var fontManager = AIAgentFontManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    TableCell(
                        text: header,
                        isHeader: true,
                        isFirstColumn: index == 0,
                        isLastColumn: index == headers.count - 1
                    )
                }
            }

            // Separator
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 1)

            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                        TableCell(
                            text: cell,
                            isHeader: false,
                            isFirstColumn: colIndex == 0,
                            isLastColumn: colIndex == row.count - 1
                        )
                    }
                    // Fill remaining columns if row is shorter than headers
                    if row.count < headers.count {
                        ForEach(row.count..<headers.count, id: \.self) { colIndex in
                            TableCell(
                                text: "",
                                isHeader: false,
                                isFirstColumn: false,
                                isLastColumn: colIndex == headers.count - 1
                            )
                        }
                    }
                }

                // Row separator (lighter than header separator)
                if rowIndex < rows.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 1)
                }
            }
        }
        .background(Color(uiColor: .tertiarySystemBackground).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

/// Individual table cell with consistent styling and inline markdown support
private struct TableCell: View {
    let text: String
    let isHeader: Bool
    let isFirstColumn: Bool
    let isLastColumn: Bool

    @ObservedObject private var fontManager = AIAgentFontManager.shared

    /// Parse inline markdown and convert to NSAttributedString
    private var nsAttributedText: NSAttributedString {
        // Get the appropriate font
        let font = isHeader
            ? UIFont.monospacedSystemFont(ofSize: CGFloat(fontManager.textSize), weight: .semibold)
            : UIFont.monospacedSystemFont(ofSize: CGFloat(fontManager.textSize), weight: .regular)

        // Parse inline markdown (handles **bold**, `code`, etc.)
        return MarkdownAttributedStringBuilder.parseInlineMarkdown(text, baseFont: font)
    }

    var body: some View {
        SelectableTextView(attributedText: nsAttributedText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHeader ? Color(uiColor: .tertiarySystemBackground) : Color.clear)
    }
}

#if DEBUG
#Preview("Markdown Table") {
    VStack(spacing: 20) {
        MarkdownTableView(
            headers: ["Metric", "Status", "Details"],
            rows: [
                ["**Uptime**", "Good", "Running for 10 days"],
                ["**CPU Load**", "Excellent", "0.07/0.02/0.00"],
                ["**Memory**", "Healthy", "1.9GB total, 627MB used"]
            ]
        )

        MarkdownTableView(
            headers: ["Name", "Value"],
            rows: [
                ["foo", "bar"],
                ["`hello`", "world"]
            ]
        )
    }
    .padding()
}
#endif
#endif
