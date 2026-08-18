#if !CHINA_BUILD
//
//  CommandCardView.swift
//  rootshell
//
//  Command approval card for AI Agent
//

import SwiftUI
import UIKit

/// Card displaying a command awaiting approval
struct CommandCardView: View {
    let command: AIAgentCommand
    let onApprove: () -> Void
    let onReject: () -> Void
    let onEdit: (String) -> Void

    @State private var isEditing = false
    @State private var editedCommand: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with risk and operation type indicators
            HStack {
                riskBadge
                operationTypeBadge

                Spacer()

                if !isEditing {
                    // Copy button
                    CopyButton(text: command.command)

                    Button(action: { startEditing() }) {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Command display or editor
            if isEditing {
                commandEditor
            } else {
                commandDisplay
            }

            // Explanation if present
            if let explanation = command.explanation, !explanation.isEmpty, !isEditing {
                Text(explanation)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // LLM reason if present
            if let reason = command.reason, !reason.isEmpty, !isEditing {
                reasonDisplay(reason)
            }

            // Misclassification warning
            if command.isMisclassified && !isEditing {
                misclassificationWarning
            }

            // Risk warnings
            if !command.riskReasons.isEmpty && !isEditing {
                riskWarnings
            }

            // Action buttons
            actionButtons
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(riskBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Components

    private var riskBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: riskIcon)
                .font(.caption.weight(.semibold))

            Text(command.riskLevel.displayName)
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(riskColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(riskColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private var operationTypeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: command.effectiveOperationType.icon)
                .font(.caption2.weight(.semibold))
            Text(command.effectiveOperationType.displayName)
                .font(.caption2.weight(.semibold))
        }
        .foregroundColor(operationTypeColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(operationTypeColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private func reasonDisplay(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb")
                .font(.caption)
                .foregroundColor(.yellow)
            Text(reason)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var misclassificationWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
            Text("LLM declared 'read' but this command may modify data")
                .font(.caption)
                .foregroundColor(.red)
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var commandDisplay: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(attributedCommand)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(action: { UIPasteboard.general.string = command.command }) {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
        }
    }

    private var commandEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Command", text: $editedCommand, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                )

            HStack {
                Button("Cancel") {
                    isEditing = false
                    editedCommand = command.command
                }
                .buttonStyle(.bordered)

                Button("Save Edit") {
                    onEdit(editedCommand)
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(editedCommand.isEmpty || editedCommand == command.command)
            }
        }
    }

    private var riskWarnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(command.riskReasons.prefix(3), id: \.self) { reason in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)

                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Reject button
            Button(action: onReject) {
                Label("Deny", systemImage: "xmark.circle.fill")
                    .font(AIAgentFonts.buttonSecondary)
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Spacer()

            // Approve button
            Button(action: onApprove) {
                Label("Run Command", systemImage: "play.circle.fill")
                    .font(AIAgentFonts.button)
            }
            .buttonStyle(.borderedProminent)
            .tint(approveButtonColor)
        }
        .padding(.top, 4)
    }

    // MARK: - Attributed Command

    private var attributedCommand: AttributedString {
        var attributed = AttributedString(command.command)

        // Highlight dangerous keywords
        let ranges = command.dangerousKeywordRanges()
        for (range, _) in ranges {
            // Convert String.Index range to AttributedString range
            if let attrRange = attributed.range(of: command.command[range]) {
                attributed[attrRange].foregroundColor = .red
                attributed[attrRange].font = .system(.body, design: .monospaced).bold()
            }
        }

        return attributed
    }

    // MARK: - Styling

    private var cardBackground: Color {
        Color(uiColor: .systemBackground)
    }

    private var operationTypeColor: Color {
        switch command.effectiveOperationType {
        case .read: return .blue
        case .write: return .orange
        }
    }

    private var riskColor: Color {
        switch command.riskLevel {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        case .critical:
            return Color(red: 0.8, green: 0, blue: 0)
        }
    }

    private var riskBorderColor: Color {
        switch command.riskLevel {
        case .low:
            return .clear
        case .medium:
            return .orange.opacity(0.3)
        case .high:
            return .red.opacity(0.3)
        case .critical:
            return .red.opacity(0.5)
        }
    }

    private var riskIcon: String {
        switch command.riskLevel {
        case .low:
            return "checkmark.shield.fill"
        case .medium:
            return "exclamationmark.shield.fill"
        case .high:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.octagon.fill"
        }
    }

    private var approveButtonColor: Color {
        switch command.riskLevel {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        case .critical:
            return Color(red: 0.8, green: 0, blue: 0)
        }
    }

    // MARK: - Actions

    private func startEditing() {
        editedCommand = command.command
        isEditing = true
    }
}

// MARK: - Preview

#if DEBUG
struct CommandCardView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            CommandCardView(
                command: AIAgentCommand(
                    toolCallId: "1",
                    command: "ls -la /home/user",
                    explanation: "List all files in the home directory"
                ),
                onApprove: {},
                onReject: {},
                onEdit: { _ in }
            )

            CommandCardView(
                command: AIAgentCommand(
                    toolCallId: "2",
                    command: "sudo rm -rf /tmp/old_files",
                    explanation: "Remove temporary files with elevated privileges"
                ),
                onApprove: {},
                onReject: {},
                onEdit: { _ in }
            )

            CommandCardView(
                command: AIAgentCommand(
                    toolCallId: "3",
                    command: "rm -rf /",
                    explanation: nil
                ),
                onApprove: {},
                onReject: {},
                onEdit: { _ in }
            )
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
#endif
#endif
