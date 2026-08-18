#if !CHINA_BUILD
//
//  VoiceAgentExpandedView.swift
//  rootshell
//
//  Expanded overlay showing transcript, controls, and tool approvals
//  for the voice agent session.
//

import SwiftUI

struct VoiceAgentExpandedView: View {
    @Bindable var session: VoiceAgentSession
    let onCollapse: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(session.transcript) { entry in
                            transcriptRow(entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                #if !os(visionOS)
                .scrollDismissesKeyboard(.immediately)
                #endif
                .onAppear {
                    scrollToLatestTranscript(with: proxy, animated: false)
                }
                .onChange(of: session.transcript.count) { _, _ in
                    scrollToLatestTranscript(with: proxy, animated: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomPanel
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Audio level indicator
            VoiceAgentAudioIndicator(
                inputLevel: session.inputLevel,
                outputLevel: session.outputLevel,
                state: session.state
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Agent")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(session.state.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onCollapse()
            } label: {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private func transcriptRow(_ entry: VoiceAgentTranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            transcriptIcon(for: entry.role)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                transcriptBody(for: entry)

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func transcriptIcon(for role: VoiceAgentTranscriptEntry.Role) -> some View {
        switch role {
        case .user:
            Image(systemName: "person.fill")
                .font(.caption)
                .foregroundStyle(.blue)
        case .assistant:
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.green)
        case .tool:
            Image(systemName: "wrench.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .system:
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func transcriptBody(for entry: VoiceAgentTranscriptEntry) -> some View {
        if shouldUseScrollableToolOutput(for: entry) {
            VoiceAgentToolResultView(entry: entry)
        } else {
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(transcriptColor(for: entry.role))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shouldUseScrollableToolOutput(for entry: VoiceAgentTranscriptEntry) -> Bool {
        guard case .tool = entry.role else { return false }
        return entry.fullContentFilePath != nil || entry.text.contains("\n") || entry.text.count > 160
    }

    private func transcriptColor(for role: VoiceAgentTranscriptEntry.Role) -> Color {
        switch role {
        case .user: return .primary
        case .assistant: return .primary
        case .tool: return .secondary
        case .system: return .secondary
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if let toolCall = session.pendingApproval {
                VoiceAgentToolApprovalCard(
                    toolCall: toolCall,
                    onApprove: { session.approveToolCall() },
                    onReject: { session.rejectToolCall() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Divider()

            controls
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(.regularMaterial)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            // Mute button
            Button {
                session.isMuted.toggle()
            } label: {
                Label(
                    session.isMuted ? "Unmute" : "Mute",
                    systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill"
                )
                .font(.callout)
                .foregroundStyle(session.isMuted ? .red : .primary)
            }
            .buttonStyle(.bordered)
            .tint(session.isMuted ? .red : .secondary)

            Spacer()

            // End session
            Button {
                onEnd()
            } label: {
                Label("End Session", systemImage: "xmark.circle.fill")
                    .font(.callout)
                    #if !os(visionOS)
                    .foregroundStyle(.red)
                    #endif
            }
            #if os(visionOS)
            .buttonStyle(.borderedProminent)
            #else
            .buttonStyle(.bordered)
            #endif
            .tint(.red)
        }
    }

    private func scrollToLatestTranscript(with proxy: ScrollViewProxy, animated: Bool) {
        guard let last = session.transcript.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct VoiceAgentToolResultView: View {
    let entry: VoiceAgentTranscriptEntry

    @State private var fullText: String?
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                Text(fullText ?? entry.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: fullText == nil ? 180 : 260)
            .padding(8)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let path = entry.fullContentFilePath, fullText == nil {
                Button {
                    loadFullText(from: path)
                } label: {
                    if isLoading {
                        Label("Loading...", systemImage: "hourglass")
                    } else {
                        Label("Load Full Output", systemImage: "arrow.down.doc")
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(isLoading)
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadFullText(from path: String) {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil

        Task {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                await MainActor.run {
                    fullText = text
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    loadError = "Failed to load full output"
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Audio Indicator

struct VoiceAgentAudioIndicator: View {
    let inputLevel: Float
    let outputLevel: Float
    let state: VoiceAgentState

    var body: some View {
        Circle()
            .fill(indicatorColor.gradient)
            .scaleEffect(indicatorScale)
            .animation(.easeInOut(duration: 0.15), value: indicatorScale)
    }

    private var indicatorColor: Color {
        switch state {
        case .listening: return .green
        case .speaking: return .blue
        case .awaitingApproval: return .orange
        case .executingTool, .consultingExpert: return .purple
        default: return .gray
        }
    }

    private var indicatorScale: CGFloat {
        switch state {
        case .listening:
            return 0.6 + CGFloat(inputLevel) * 0.4
        case .speaking:
            return 0.6 + CGFloat(outputLevel) * 0.4
        default:
            return 0.6
        }
    }
}
#endif
