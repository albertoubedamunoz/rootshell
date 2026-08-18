#if !CHINA_BUILD
//
//  VoiceAgentPillView.swift
//  rootshell
//
//  Floating compact overlay on the terminal for the voice agent.
//  Shows waveform animation, mute toggle, and state text.
//

import SwiftUI

struct VoiceAgentPillView: View {
    @Bindable var session: VoiceAgentSession
    let onTap: () -> Void
    let onClose: () -> Void

    @State private var wavePhase: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            // Waveform / status indicator
            waveformIndicator
                .frame(width: 24, height: 24)

            // Status text
            Text(session.state.statusDescription)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)

            // Mute toggle
            Button {
                session.isMuted.toggle()
            } label: {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.body)
                    .foregroundStyle(session.isMuted ? .red : .white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Close button
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(pillBackground)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .onTapGesture { onTap() }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                wavePhase = .pi * 2
            }
        }
    }

    // MARK: - Components

    @ViewBuilder
    private var waveformIndicator: some View {
        switch session.state {
        case .listening:
            WaveformView(level: session.inputLevel, phase: wavePhase, color: .green)
        case .speaking:
            WaveformView(level: session.outputLevel, phase: wavePhase, color: .blue)
        case .awaitingApproval:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
        case .executingTool, .consultingExpert:
            ProgressView()
                .scaleEffect(0.6)
                .tint(.white)
        case .connecting:
            ProgressView()
                .scaleEffect(0.6)
                .tint(.white)
        default:
            Image(systemName: "waveform.circle")
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 14))
        }
    }

    private var pillBackground: some ShapeStyle {
        Color.black.opacity(0.75)
    }
}

// MARK: - Waveform Visualization

struct WaveformView: View {
    let level: Float
    let phase: CGFloat
    let color: Color

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let barPhase = phase + CGFloat(index) * 0.5
                let height = max(3, CGFloat(level) * 20 * (0.5 + 0.5 * sin(barPhase)))
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 2, height: height)
                    .animation(.easeInOut(duration: 0.1), value: level)
            }
        }
    }
}
#endif
