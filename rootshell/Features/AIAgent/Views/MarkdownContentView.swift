#if !CHINA_BUILD
//
//  MarkdownContentView.swift
//  rootshell
//
//  SwiftUI view for rendering markdown content using UITextView for proper
//  click-and-drag text selection on Mac Catalyst.
//

import SwiftUI
import UIKit

// MARK: - SelectableTextView (UIViewRepresentable)

/// UITextView wrapper that supports click-and-drag text selection on Mac Catalyst
/// This is necessary because SwiftUI's .textSelection(.enabled) doesn't support
/// mouse-based click-and-drag selection on Catalyst.
struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false  // Parent handles scrolling
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = [.link]
        textView.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.delegate = context.coordinator
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        // Enable Dynamic Type support
        textView.adjustsFontForContentSizeCategory = true
        return textView
    }

    func updateUIView(_ textView: SelectableUITextView, context: Context) {
        textView.attributedText = attributedText
        // Force layout update to recalculate intrinsic content size
        textView.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UITextViewDelegate {
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in
                    UIApplication.shared.open(url)
                }
            }
            return defaultAction
        }
    }
}

/// Custom UITextView subclass that properly calculates intrinsic content size
/// when scrolling is disabled
class SelectableUITextView: UITextView {
    override var intrinsicContentSize: CGSize {
        // Calculate the size needed to fit all content
        // Use bounds width if available, otherwise fall back to a reasonable default
        // Note: UIScreen.main is unavailable on visionOS, so we use the window scene bounds
        let fixedWidth: CGFloat
        if bounds.width > 0 {
            fixedWidth = bounds.width
        } else if let windowWidth = window?.bounds.width, windowWidth > 0 {
            fixedWidth = windowWidth - 32
        } else {
            // Fallback for initial layout before view is in window hierarchy
            fixedWidth = 600
        }
        let newSize = sizeThatFits(CGSize(width: fixedWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: newSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Invalidate intrinsic content size when bounds change
        invalidateIntrinsicContentSize()
    }
}

// MARK: - MarkdownContentView

/// SwiftUI view for rendering markdown content with proper text selection
/// Uses UITextView underneath for click-and-drag selection on Mac Catalyst
/// Tables are rendered as proper grid layouts for column alignment
struct MarkdownContentView: View {
    let markdown: String

    /// Observe font manager to refresh when text size changes
    @ObservedObject private var fontManager = AIAgentFontManager.shared

    /// Parsed blocks - recomputed when markdown changes
    private var blocks: [SimpleMarkdownParser.Block] {
        SimpleMarkdownParser.parse(markdown)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
            .id("markdown-\(fontManager.textSize)")  // Force refresh when font size changes
    }
}

/// Shared renderer for parsed markdown blocks
struct MarkdownBlocksView: View {
    let blocks: [SimpleMarkdownParser.Block]

    /// Observe font manager to refresh when text size changes
    @ObservedObject private var fontManager = AIAgentFontManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                BlockView(block: block)
            }
        }
        .id("markdown-blocks-\(fontManager.textSize)")
    }
}

/// Renders a single markdown block
private struct BlockView: View {
    let block: SimpleMarkdownParser.Block

    var body: some View {
        switch block.content {
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)

        case .header(let level, let text):
            SelectableTextView(
                attributedText: MarkdownAttributedStringBuilder.buildHeader(level: level, text: text)
            )
            .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let code):
            SelectableTextView(
                attributedText: MarkdownAttributedStringBuilder.buildCodeBlock(code: code)
            )
            .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            SelectableTextView(
                attributedText: MarkdownAttributedStringBuilder.buildParagraph(text: text)
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Streaming Markdown

/// Streaming markdown view that parses off-main and renders blocks incrementally.
/// Uses throttling and task cancellation to avoid excessive CPU usage.
struct StreamingMarkdownContentView: View {
    let markdown: String
    var throttleInterval: CFTimeInterval = 0.12

    @State private var blocks: [SimpleMarkdownParser.Block] = []
    @State private var pendingText: String = ""
    @State private var lastRenderedText: String = ""
    @State private var lastParseTime: CFTimeInterval = 0
    @State private var parseTask: Task<Void, Never>?

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
            .onAppear {
                scheduleParse(markdown)
            }
            .onChange(of: markdown) { _, newValue in
                scheduleParse(newValue)
            }
            .onDisappear {
                parseTask?.cancel()
                parseTask = nil
            }
    }

    private func scheduleParse(_ text: String) {
        let snapshot = text
        guard snapshot != lastRenderedText else { return }
        pendingText = text
        parseTask?.cancel()
        let interval = throttleInterval
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastParseTime
        let shouldRenderNow = lastParseTime == 0 || elapsed >= interval

        parseTask = Task {
            if !shouldRenderNow {
                let delay = max(0, interval - elapsed)
                let sleepNanos = UInt64(delay * 1_000_000_000)
                if sleepNanos > 0 {
                    try? await Task.sleep(nanoseconds: sleepNanos)
                }
            }
            if Task.isCancelled {
                return
            }

            let parsed = await Task.detached(priority: .utility) {
                SimpleMarkdownParser.parse(snapshot)
            }.value

            await MainActor.run {
                guard pendingText == snapshot else { return }
                blocks = parsed
                lastRenderedText = snapshot
                lastParseTime = CFAbsoluteTimeGetCurrent()
            }
        }
    }
}

// MARK: - Simple Selectable Text

/// Simple selectable text view for plain text content (tool results, commands, etc.)
/// Provides consistent click-and-drag selection across the app
/// Supports Dynamic Type for accessibility
/// Uses throttling and incremental rendering to reduce CPU usage during streaming
struct SimpleSelectableText: UIViewRepresentable {
    let text: String
    var font: UIFont = AIAgentFonts.uiCodeBody
    var textColor: UIColor = .label

    /// Throttle interval for rendering updates (50ms = 20fps max)
    private static let renderThrottleInterval: CFTimeInterval = 0.05

    func makeUIView(context: Context) -> SelectableUITextView {
        let textView = SelectableUITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        // Enable Dynamic Type support
        textView.adjustsFontForContentSizeCategory = true
        return textView
    }

    func updateUIView(_ textView: SelectableUITextView, context: Context) {
        let coordinator = context.coordinator

        // Always track the latest text for final render
        coordinator.pendingText = text

        // Skip if text hasn't changed from last render
        guard text != coordinator.lastRenderedText else { return }

        // Throttle rendering to reduce CPU usage during streaming
        let now = CFAbsoluteTimeGetCurrent()
        let timeSinceLastRender = now - coordinator.lastRenderTime

        if timeSinceLastRender < Self.renderThrottleInterval {
            // Schedule a delayed render if not already scheduled
            if coordinator.pendingRenderWorkItem == nil {
                let delay = Self.renderThrottleInterval - timeSinceLastRender
                let workItem = DispatchWorkItem { [weak textView] in
                    guard let textView = textView else { return }
                    coordinator.pendingRenderWorkItem = nil
                    self.performRender(textView: textView, coordinator: coordinator)
                }
                coordinator.pendingRenderWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
            return
        }

        // Render immediately
        performRender(textView: textView, coordinator: coordinator)
    }

    private func performRender(textView: SelectableUITextView, coordinator: Coordinator) {
        let textToRender = coordinator.pendingText
        guard textToRender != coordinator.lastRenderedText else { return }

        // Use terminal paragraph style for proper table/ASCII alignment
        let paragraphStyle = MarkdownAttributedStringBuilder.terminalParagraphStyle(font: font)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
            .kern: 0,  // Disable font kerning for consistent monospace spacing
            .ligature: 0  // Disable ligatures for consistent character width
        ]

        // Use incremental append when possible for better performance
        if !coordinator.lastRenderedText.isEmpty,
           textToRender.hasPrefix(coordinator.lastRenderedText) {
            let delta = textToRender.dropFirst(coordinator.lastRenderedText.count)
            if !delta.isEmpty {
                textView.textStorage.append(NSAttributedString(string: String(delta), attributes: attributes))
            }
        } else {
            textView.attributedText = NSAttributedString(string: textToRender, attributes: attributes)
        }

        coordinator.lastRenderedText = textToRender
        coordinator.lastRenderTime = CFAbsoluteTimeGetCurrent()
        textView.invalidateIntrinsicContentSize()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var lastRenderedText: String = ""
        var pendingText: String = ""
        var lastRenderTime: CFTimeInterval = 0
        var pendingRenderWorkItem: DispatchWorkItem?
    }
}

#if DEBUG
#Preview("Markdown Content") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            MarkdownContentView(
                markdown: """
                # Header 1
                This is **bold** and *italic* text.

                ## Header 2
                Here's some `inline code` and a [link](https://example.com).

                | Metric | Status | Details |
                |--------|--------|---------|
                | Uptime | Good | 10 days |
                | CPU | Excellent | 0.07 |
                | Memory | Healthy | 1.9GB |

                ### Header 3
                A code block:

                ```swift
                func hello() {
                    print("Hello, World!")
                }
                ```

                And more text after.
                """
            )
        }
        .padding()
    }
}
#endif
#endif
