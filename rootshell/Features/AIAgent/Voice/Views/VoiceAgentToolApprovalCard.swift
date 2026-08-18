#if !CHINA_BUILD
//
//  VoiceAgentToolApprovalCard.swift
//  rootshell
//
//  Tool approval card shown when the voice agent requests a write operation.
//  Styled consistently with CommandCardView from the text AI agent.
//

import SwiftUI

struct VoiceAgentToolApprovalCard: View {
    let toolCall: VoiceAgentToolCall
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with risk indicator
            HStack {
                riskBadge
                Spacer()
                Text(toolCall.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            // Tool description
            Text(toolCall.displayDescription)
                .font(.callout)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)

            if let command = toolCall.args["command"] {
                scrollableArgumentSection(title: "Command", value: command, maxHeight: 140)
            }

            if let keys = toolCall.args["keys"] {
                scrollableArgumentSection(title: "Keystrokes", value: keys, maxHeight: 140)
            }

            if let text = toolCall.args["text"] {
                scrollableArgumentSection(title: "Paste Contents", value: text, maxHeight: 180)
            }

            // Action buttons
            ViewThatFits(in: .horizontal) {
                approvalButtons(horizontal: true)
                approvalButtons(horizontal: false)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    // MARK: - Components

    @ViewBuilder
    private var riskBadge: some View {
        let (text, color) = riskInfo
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var riskInfo: (String, Color) {
        switch toolCall.riskLevel {
        case .low:
            return ("LOW", .green)
        case .medium:
            return ("MEDIUM", .yellow)
        case .high:
            return ("HIGH", .orange)
        case .critical:
            return ("CRITICAL", .red)
        }
    }

    private var cardBackground: some ShapeStyle {
        Color(.systemBackground).opacity(0.95)
    }

    private var borderColor: Color {
        switch toolCall.riskLevel {
        case .low: return .green.opacity(0.3)
        case .medium: return .yellow.opacity(0.3)
        case .high: return .orange.opacity(0.3)
        case .critical: return .red.opacity(0.5)
        }
    }

    private func scrollableArgumentSection(title: String, value: String, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.vertical) {
                argumentBlock(value)
            }
            .frame(maxHeight: maxHeight)
        }
    }

    private func argumentBlock(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func approvalButtons(horizontal: Bool) -> some View {
        let stackSpacing: CGFloat = 12

        Group {
            if horizontal {
                HStack(spacing: stackSpacing) {
                    rejectButton
                    approveButton
                }
            } else {
                VStack(spacing: stackSpacing) {
                    approveButton
                    rejectButton
                }
            }
        }
    }

    private var rejectButton: some View {
        Button {
            onReject()
        } label: {
            Label("Reject", systemImage: "xmark")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private var approveButton: some View {
        Button {
            onApprove()
        } label: {
            Label("Approve", systemImage: "checkmark")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
    }
}
#endif
