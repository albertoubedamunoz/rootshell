#if !CHINA_BUILD
//
//  AIAgentChatView.swift
//  rootshell
//
//  Chat message list for AI Agent
//

import SwiftUI
import UIKit

/// Chat view displaying AI Agent conversation
struct AIAgentChatView: View {
    var session: AIAgentSession

    /// Observe font manager to refresh views when text size changes
    @ObservedObject private var fontManager = AIAgentFontManager.shared

    /// External trigger to scroll to bottom (from parent, e.g., on keyboard appear)
    @Binding var scrollToBottomTrigger: Bool

    @State private var hasAppeared = false
    @State private var lastScrollTime: Date = .distantPast
    
    // Scroll position tracking for "stick to bottom" behavior
    // Once user scrolls away, we stop auto-scrolling until they return to bottom
    @State private var userScrolledAway = false
    
    // Track scroll position to detect when user returns to bottom
    @State private var lastKnownScrollOffset: CGFloat = 0
    @State private var lastKnownContentHeight: CGFloat = 0
    @State private var lastKnownViewHeight: CGFloat = 0
    
    // Ignore scroll changes briefly after programmatic scroll to avoid false positives
    @State private var lastProgrammaticScrollTime: Date = .distantPast
    
    // Track user drag gesture to detect scroll intent immediately
    @GestureState private var isDragging = false
    
    // Pending scroll task for cancellation when new scrolls are requested
    @State private var pendingScrollTask: Task<Void, Never>?
    
    /// Threshold for considering "at bottom" (allows small tolerance)
    private let bottomThreshold: CGFloat = 80
    
    init(session: AIAgentSession, scrollToBottomTrigger: Binding<Bool> = .constant(false)) {
        self.session = session
        self._scrollToBottomTrigger = scrollToBottomTrigger
    }
    
    /// Whether auto-scroll should be active
    private var shouldAutoScroll: Bool {
        !userScrolledAway && !isDragging
    }
    
    var body: some View {
        GeometryReader { outerGeometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                        
                        // Show command card if awaiting approval
                        if case .awaitingApproval(let command) = session.state {
                            CommandCardView(
                                command: command,
                                onApprove: {
                                    Task { await session.approveCommand() }
                                },
                                onReject: {
                                    Task { await session.rejectCommand() }
                                },
                                onEdit: { newCommand in
                                    Task { await session.editCommand(newCommand) }
                                }
                            )
                            .id("approval-card")
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                        
                        // Show question card if awaiting answer
                        if case .awaitingAnswer(let question) = session.state {
                            QuestionCardView(
                                question: question,
                                onAnswer: { answer in
                                    Task { await session.submitAnswer(answer) }
                                },
                                onSkip: {
                                    Task { await session.skipQuestion() }
                                }
                            )
                            .id("question-card")
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                        
                        // Show streaming response (always visible when streaming to prevent layout thrashing)
                        if session.isStreaming {
                            StreamingMessageBubbleView(
                                text: session.streamingText ?? "",
                                thinking: session.streamingThinking
                            )
                            .id("streaming")
                        }
                        
                        // Show thinking indicator (only when not streaming text yet)
                        if session.state == .thinking && !session.isStreaming {
                            ThinkingIndicatorView()
                                .id("thinking")
                        }
                        
                        // Show executing indicator with streaming output
                        if case .executing(let command) = session.state {
                            ExecutingIndicatorView(
                                command: command,
                                streamingOutput: session.executingStreamOutput,
                                onCancel: { session.cancelExecution() }
                            )
                            .id("executing")
                        }
                        
                        // Show web operation indicator
                        if case .webSearching(let query, let engine) = session.state {
                            WebOperationIndicatorView(operation: .search(query: query, engine: engine))
                                .id("web-searching")
                        }
                        if case .webFetching(let url) = session.state {
                            WebOperationIndicatorView(operation: .fetch(url: url))
                                .id("web-fetching")
                        }
                        
                        // Show error card if in error state
                        if case .error(let errorCategory) = session.state {
                            ErrorCardView(
                                error: errorCategory,
                                onRetry: {
                                    Task { await session.retryLastMessage() }
                                },
                                onDismiss: {
                                    session.dismissError()
                                }
                            )
                            .id("error-card")
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                        
                        // Bottom anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .background(
                        GeometryReader { innerGeometry in
                            Color.clear
                                .onChange(of: innerGeometry.frame(in: .named("chatScroll")).minY) { oldOffset, newOffset in
                                    handleScrollChange(
                                        oldOffset: oldOffset,
                                        newOffset: newOffset,
                                        contentHeight: innerGeometry.size.height,
                                        viewHeight: outerGeometry.size.height
                                    )
                                }
                                .onAppear {
                                    // Initialize tracking values
                                    lastKnownContentHeight = innerGeometry.size.height
                                    lastKnownViewHeight = outerGeometry.size.height
                                }
                        }
                    )
                }
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
                .coordinateSpace(name: "chatScroll")
                .defaultScrollAnchor(.bottom)
                // Detect user drag to immediately stop auto-scroll
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .updating($isDragging) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            // User is dragging up (negative translation = scrolling down toward bottom)
                            // Positive translation = scrolling up away from bottom
                            if value.translation.height > 10 {
                                userScrolledAway = true
                            }
                        }
                )

                .onAppear {
                    // Scroll to bottom on initial appear (no animation)
                    if !hasAppeared {
                        hasAppeared = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: session.messages.count) { oldCount, newCount in
                    // When user sends a new message, reset scroll state - they want to see the response
                    if newCount > oldCount, let lastMessage = session.messages.last, lastMessage.role == .user {
                        userScrolledAway = false
                    }
                    
                    // Scroll when new messages arrive (only if user hasn't scrolled away)
                    guard shouldAutoScroll else { return }
                    scheduleScrollToBottom(delay: 0.05, proxy: proxy)
                }
                .onChange(of: session.state) { oldState, newState in
                    // Scroll on meaningful state transitions (only if user hasn't scrolled away)
                    guard oldState != newState else { return }
                    guard shouldAutoScroll else { return }
                    
                    // Skip idle state - no need to scroll
                    if case .idle = newState { return }
                    
                    // Delay to let SwiftUI render new views, then scroll to bottom
                    // Using "bottom" anchor always exists, eliminating race conditions with content-specific IDs
                    scheduleScrollToBottom(delay: 0.15, proxy: proxy)
                }
                .onChange(of: session.isStreaming) { _, isStreaming in
                    // Scroll when streaming starts (only if user hasn't scrolled away)
                    if isStreaming {
                        guard shouldAutoScroll else { return }
                        scheduleScrollToBottom(delay: 0.05, proxy: proxy)
                    }
                }
                .onChange(of: session.streamingText) { _, _ in
                    scrollToStreamingIfNeeded(proxy: proxy)
                }
                .onChange(of: session.streamingThinking) { _, _ in
                    scrollToStreamingIfNeeded(proxy: proxy)
                }
                .onChange(of: session.executingStreamOutput) { _, _ in
                    scrollToExecutingIfNeeded(proxy: proxy)
                }
                .onChange(of: scrollToBottomTrigger) { _, _ in
                    // External trigger to scroll to bottom (e.g., when keyboard appears)
                    guard shouldAutoScroll else { return }
                    scheduleScrollToBottom(delay: 0, proxy: proxy, animated: false)
                }
                .onDisappear {
                    // Cancel pending scroll to avoid memory leaks
                    pendingScrollTask?.cancel()
                }
            }
        }
    }
    
    /// Handle scroll position changes to detect user scroll intent
    private func handleScrollChange(oldOffset: CGFloat, newOffset: CGFloat, contentHeight: CGFloat, viewHeight: CGFloat) {
        // Ignore changes shortly after programmatic scroll to avoid false positives
        let timeSinceProgrammaticScroll = Date().timeIntervalSince(lastProgrammaticScrollTime)
        guard timeSinceProgrammaticScroll > 0.15 else {
            // Still update tracking values
            lastKnownScrollOffset = newOffset
            lastKnownContentHeight = contentHeight
            lastKnownViewHeight = viewHeight
            return
        }
        
        // Calculate if we're at bottom
        // offset (minY) is negative when scrolled - more negative = scrolled further down
        // At bottom when: contentHeight + offset <= viewHeight + threshold
        let distanceFromBottom = contentHeight + newOffset - viewHeight
        let isCurrentlyAtBottom = distanceFromBottom <= bottomThreshold || contentHeight <= viewHeight
        
        // Note: We do NOT detect "user scrolled away" from geometry changes here.
        // Geometry-based detection is unreliable during keyboard animation (race condition).
        // Instead, we rely solely on the DragGesture.onChanged handler to detect user scroll intent.
        
        // Re-enable auto-scroll when user reaches bottom (regardless of how they got there)
        if isCurrentlyAtBottom && userScrolledAway {
            userScrolledAway = false
        }
        
        // Update tracking values
        lastKnownScrollOffset = newOffset
        lastKnownContentHeight = contentHeight
        lastKnownViewHeight = viewHeight
    }
    
    /// Throttled scroll to executing indicator to avoid excessive updates
    /// Only scrolls if user hasn't scrolled away (respects user scroll intent)
    private func scrollToExecutingIfNeeded(proxy: ScrollViewProxy) {
        guard shouldAutoScroll else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) > 0.08 else { return }
        lastScrollTime = now
        lastProgrammaticScrollTime = now
        
        // Use bottom anchor for more reliable positioning during rapid content growth
        proxy.scrollTo("bottom", anchor: .bottom)
    }
    
    /// Throttled scroll to streaming content to avoid excessive updates
    /// Only scrolls if user hasn't scrolled away (respects user scroll intent)
    private func scrollToStreamingIfNeeded(proxy: ScrollViewProxy) {
        guard shouldAutoScroll else { return }
        
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) > 0.08 else { return }
        lastScrollTime = now
        lastProgrammaticScrollTime = now
        
        // Use bottom anchor for more reliable positioning during rapid content growth
        proxy.scrollTo("bottom", anchor: .bottom)
    }
    
    /// Unified scroll function that cancels pending scrolls to avoid conflicts
    /// Always scrolls to "bottom" anchor which always exists, eliminating race conditions
    private func scheduleScrollToBottom(delay: Double, proxy: ScrollViewProxy, animated: Bool = true) {
        // Cancel any pending scroll to avoid conflicts
        pendingScrollTask?.cancel()
        
        pendingScrollTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            }
            guard !Task.isCancelled else { return }
            
            lastProgrammaticScrollTime = Date()
            
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View, Equatable {
    let message: AIAgentMessage
    
    // Since message content is immutable, we only need to compare IDs
    // This allows SwiftUI to skip body evaluation if the message hasn't changed
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message.id == rhs.message.id
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
            avatarView
            
            // Content
            VStack(alignment: .leading, spacing: 4) {
                // Header row with role label and copy button
                HStack {
                    Text(roleLabel)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(roleColor)
                    
                    Spacer()
                    
                    // Whole message copy button
                    CopyButton(text: fullMessageText)
                }
                
                // Message content
                messageContent
            }
            
            Spacer(minLength: 40)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(action: { UIPasteboard.general.string = fullMessageText }) {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }
    }
    
    /// Concatenate all copyable content from the message
    private var fullMessageText: String {
        switch message.content {
        case .text:
            return message.displayText ?? message.textContent ?? ""
        case .textWithThinking(let text, _):
            return text
        case .toolCall(let call):
            return call.parseArguments()?["command"] as? String ?? ""
        case .toolCalls(let calls, let precedingText, _):
            let commands = calls.compactMap { $0.parseArguments()?["command"] as? String }.joined(separator: "\n")
            if let text = precedingText, !text.isEmpty {
                return text + "\n\n" + commands
            }
            return commands
        case .toolResult(_, let output, _, _):
            return output
        case .toolResults(let results):
            return results.map { $0.output }.joined(separator: "\n\n")
        }
    }
    
    @ViewBuilder
    private var avatarView: some View {
        ZStack {
            Circle()
                .fill(avatarBackgroundColor)
                .frame(width: 32, height: 32)
            
            Image(systemName: avatarIcon)
                .font(AIAgentFonts.avatarIcon)
                .foregroundColor(avatarIconColor)
        }
    }
    
    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .text:
            // Parse thinking at display time (preserves raw text in message history)
            VStack(alignment: .leading, spacing: 8) {
                // Show thinking in distinct style if present
                if let thinking = message.thinkingContent, !thinking.isEmpty {
                    ThinkingContentView(content: thinking)
                }
                
                // Show main text (with thinking tags removed) - rendered as markdown
                if let displayText = message.displayText, !displayText.isEmpty {
                    MarkdownContentView(markdown: displayText)
                }
            }
            
        case .textWithThinking(let text, let thinking):
            // Structured thinking content (new format with signature support)
            VStack(alignment: .leading, spacing: 8) {
                // Show thinking in distinct style
                if !thinking.content.isEmpty {
                    ThinkingContentView(content: thinking.content)
                }
                
                // Show main text - rendered as markdown (filter any remaining tags)
                let filtered = ThinkingParser.parse(text).text
                if !filtered.isEmpty {
                    MarkdownContentView(markdown: filtered)
                }
            }
            
        case .toolCall(let call):
            ToolCallBubble(call: call)
            
        case .toolCalls(let calls, let precedingText, let thinkingBlock):
            let parsed = parsedToolCallContent(precedingText: precedingText, thinkingBlock: thinkingBlock)
            VStack(alignment: .leading, spacing: 8) {
                // Show thinking in distinct style (structured thinking takes precedence)
                if let thinking = parsed.thinking, !thinking.isEmpty {
                    ThinkingContentView(content: thinking)
                }

                if let displayText = parsed.displayText, !displayText.isEmpty {
                    MarkdownContentView(markdown: displayText)
                }

                // Show tool call bubbles
                ForEach(calls) { call in
                    ToolCallBubble(call: call)
                }
            }
            
        case .toolResult(_, let output, let isError, _):
            ToolResultBubble(output: output, isError: isError)
            
        case .toolResults(let results):
            // Show all batched tool results
            ForEach(results, id: \.toolCallId) { result in
                ToolResultBubble(output: result.output, isError: result.isError)
            }
        }
    }
    
    private var roleLabel: String {
        switch message.role {
        case .user:
            return "You"
        case .assistant:
            return "AI Agent"
        case .system:
            return "System"
        case .tool:
            return "Result"
        }
    }

    private func parsedToolCallContent(
        precedingText: String?,
        thinkingBlock: AIThinkingBlock?
    ) -> (displayText: String?, thinking: String?) {
        var parsedThinking: String?
        var parsedDisplayText: String?

        if let rawText = precedingText, !rawText.isEmpty {
            let thinkingResult = ThinkingParser.parse(rawText)
            let filtered = MiniMaxToolCallParser.parse(thinkingResult.text).remainingText
            let displayText = TextToolCallParser.parse(filtered).remainingText
            let trimmedDisplay = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            parsedDisplayText = trimmedDisplay.isEmpty ? nil : trimmedDisplay

            let trimmedThinking = thinkingResult.thinking?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedThinking, !trimmedThinking.isEmpty {
                parsedThinking = trimmedThinking
            }
        }

        let structuredThinking = thinkingBlock?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinkingToShow = structuredThinking?.isEmpty == false ? structuredThinking : parsedThinking

        return (parsedDisplayText, thinkingToShow)
    }
    
    private var roleColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .purple
        case .system:
            return .gray
        case .tool:
            return .orange
        }
    }
    
    private var avatarBackgroundColor: Color {
        switch message.role {
        case .user:
            return .blue.opacity(0.15)
        case .assistant:
            return .purple.opacity(0.15)
        case .system:
            return .gray.opacity(0.15)
        case .tool:
            return .orange.opacity(0.15)
        }
    }
    
    private var avatarIcon: String {
        switch message.role {
        case .user:
            return "person.fill"
        case .assistant:
            return "brain"
        case .system:
            return "gearshape.fill"
        case .tool:
            return "terminal.fill"
        }
    }
    
    private var avatarIconColor: Color {
        switch message.role {
        case .user:
            return .blue
        case .assistant:
            return .purple
        case .system:
            return .gray
        case .tool:
            return .orange
        }
    }
}

// MARK: - Tool Call Bubble

struct ToolCallBubble: View {
    let call: AIToolCall
    
    private var command: String? {
        call.parseArguments()?["command"] as? String
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(AIAgentFonts.badgeIcon)
                Text("Command requested")
                    .font(.caption)
                
                Spacer()
                
                // Copy button for command
                if let command = command {
                    CopyButton(text: command)
                }
            }
            .foregroundColor(.secondary)
            
            if let command = command {
                SimpleSelectableText(
                    text: command,
                    font: AIAgentFonts.uiCodeBody,
                    textColor: .label
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button(action: { UIPasteboard.general.string = command }) {
                        Label("Copy Command", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}

// MARK: - Tool Result Bubble

struct ToolResultBubble: View {
    let output: String
    let isError: Bool
    
    @State private var isExpanded = false
    
    private var displayText: String {
        isExpanded || output.count <= 200 ? output : String(output.prefix(200)) + "..."
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(AIAgentFonts.badgeIcon)
                    .foregroundColor(isError ? .red : .green)

                Text(isError ? String(localized: "Error", comment: "Command output type: error") : String(localized: "Output", comment: "Command output type: standard output"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Copy button - always visible
                CopyButton(text: output)

                if output.count > 200 {
                    Button(action: { isExpanded.toggle() }) {
                        Text(isExpanded ? String(localized: "Collapse", comment: "Toggle: collapse output") : String(localized: "Expand", comment: "Toggle: expand output"))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }
            
            SimpleSelectableText(
                text: displayText,
                font: AIAgentFonts.uiCodeBody,
                textColor: isError ? .systemRed : .secondaryLabel
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contextMenu {
                Button(action: { UIPasteboard.general.string = output }) {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicatorView: View {
    @State private var animationPhase = 0.0
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: "brain")
                    .font(AIAgentFonts.avatarIcon)
                    .foregroundColor(.purple)
                    .symbolEffect(.pulse, options: .repeating)
            }

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.purple)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animationPhase == Double(index) ? 1.2 : 0.8)
                        .opacity(animationPhase == Double(index) ? 1.0 : 0.5)
                }
            }

            Text("Thinking...")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: false)) {
                animationPhase = 3.0
            }
        }
    }
}

// MARK: - Streaming Message Bubble

struct StreamingMessageBubbleView: View {
    let text: String
    let thinking: String?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // AI Avatar
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: "brain")
                    .font(AIAgentFonts.avatarIcon)
                    .foregroundColor(.purple)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("AI Agent")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.purple)

                    Spacer()

                    // Streaming indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Streaming")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Show thinking in distinct style (non-collapsible)
                if let thinking = thinking, !thinking.isEmpty {
                    ThinkingContentView(content: thinking)
                }
                
                // Streaming text rendered as markdown
                StreamingMarkdownContentView(markdown: text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Streaming Thinking Disclosure

struct StreamingThinkingDisclosureView: View {
    let content: String
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                SimpleSelectableText(
                    text: content,
                    font: AIAgentFonts.uiCodeBody,
                    textColor: .secondaryLabel
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("Reasoning")
                    .font(.caption)
            }
            .foregroundColor(.purple.opacity(0.8))
        }
        .padding(8)
        .background(Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Executing Indicator

struct ExecutingIndicatorView: View {
    let command: AIAgentCommand
    let streamingOutput: String?
    let onCancel: () -> Void
    
    @State private var isOutputExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with command info and controls
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Executing command...")
                        .font(.callout)
                        .foregroundColor(.primary)
                    
                    Text(command.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Toggle for output visibility
                if streamingOutput != nil {
                    Button(action: { isOutputExpanded.toggle() }) {
                        Image(systemName: isOutputExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                // Cancel button
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // Streaming output preview
            if isOutputExpanded, let output = streamingOutput, !output.isEmpty {
                ScrollView {
                    SimpleSelectableText(
                        text: output,
                        font: AIAgentFonts.uiCodeBody,
                        textColor: .secondaryLabel
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Web Operation Indicator

struct WebOperationIndicatorView: View {
    enum Operation {
        case search(query: String, engine: String)
        case fetch(url: String)
        
        var title: String {
            switch self {
            case .search: return "Searching the web..."
            case .fetch: return "Fetching page..."
            }
        }
        
        var detail: String {
            switch self {
            case .search(let query, let engine):
                return "\(engine): \(query)"
            case .fetch(let url):
                // Truncate long URLs
                if url.count > 50 {
                    return String(url.prefix(50)) + "..."
                }
                return url
            }
        }
        
        var iconName: String {
            switch self {
            case .search: return "magnifyingglass"
            case .fetch: return "globe"
            }
        }
        
        var color: Color {
            .blue
        }
    }
    
    let operation: Operation
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(operation.color.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(operation.color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.callout)
                    .foregroundColor(.primary)
                
                Text(operation.detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()

            Image(systemName: operation.iconName)
                .font(.callout)
                .foregroundColor(operation.color.opacity(0.6))
        }
        .padding(12)
        .background(operation.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Thinking Content (Non-collapsible)

/// Simple thinking content view - shows thinking in a distinct style without collapsing
struct ThinkingContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("Reasoning")
                    .font(.caption)
                Spacer()
                CopyButton(text: content)
            }
            .foregroundColor(.purple.opacity(0.8))

            SimpleSelectableText(
                text: content,
                font: AIAgentFonts.uiCodeBody,
                textColor: .secondaryLabel
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(action: { UIPasteboard.general.string = content }) {
                Label("Copy Reasoning", systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - Thinking Disclosure (Collapsible - Legacy)

struct ThinkingDisclosureView: View {
    let content: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    CopyButton(text: content)
                }

                ScrollView {
                    SimpleSelectableText(
                        text: content,
                        font: AIAgentFonts.uiCodeBody,
                        textColor: .secondaryLabel
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("Reasoning")
                    .font(.caption)
            }
            .foregroundColor(.purple.opacity(0.8))
        }
        .padding(8)
        .background(Color.purple.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button(action: { UIPasteboard.general.string = content }) {
                Label("Copy Reasoning", systemImage: "doc.on.doc")
            }
        }
    }
}
#endif
