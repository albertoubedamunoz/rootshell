#if !CHINA_BUILD
//
//  QuestionCardView.swift
//  rootshell
//
//  Question card for AI Agent user prompts
//

import SwiftUI

/// Card displaying a question awaiting user answer
struct QuestionCardView: View {
    let question: AIAgentQuestion
    let onAnswer: (AIAgentAnswer.Value) -> Void
    let onSkip: () -> Void

    @State private var selectedOption: String?
    @State private var selectedOptions: Set<String> = []
    @State private var textInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            header

            // Question text
            questionText

            // Context if provided
            if let context = question.context, !context.isEmpty {
                contextView(context)
            }

            // Input area based on type
            inputArea

            // Action buttons (except for yes/no which has integrated buttons)
            if question.inputType != .yesNo {
                actionButtons
            } else {
                skipLink
            }
        }
        .padding(16)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill")
                .font(.caption.weight(.semibold))

            Text("Question")
                .font(.caption.weight(.semibold))

            Spacer()

            Text(question.inputType.displayName)
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(uiColor: .tertiarySystemFill))
                .clipShape(Capsule())
        }
        .foregroundColor(.accentColor)
    }

    // MARK: - Question Text

    private var questionText: some View {
        Text(question.question)
            .font(.body)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Context

    private func contextView(_ context: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(context)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Input Area

    @ViewBuilder
    private var inputArea: some View {
        switch question.inputType {
        case .yesNo:
            yesNoInput
        case .singleChoice:
            singleChoiceInput
        case .multiChoice:
            multiChoiceInput
        case .text:
            textInputArea
        }
    }

    // MARK: - Yes/No Input

    private var yesNoInput: some View {
        HStack(spacing: 12) {
            Button(action: { onAnswer(.yesNo(false)) }) {
                Label("No", systemImage: "xmark.circle")
                    .font(AIAgentFonts.buttonSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            Button(action: { onAnswer(.yesNo(true)) }) {
                Label("Yes", systemImage: "checkmark.circle")
                    .font(AIAgentFonts.button)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Single Choice Input

    private var singleChoiceInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(question.options, id: \.self) { option in
                Button(action: { selectedOption = option }) {
                    HStack {
                        Image(systemName: selectedOption == option ? "circle.inset.filled" : "circle")
                            .foregroundColor(selectedOption == option ? .accentColor : .secondary)
                            .font(AIAgentFonts.selectionIcon)

                        Text(option)
                            .foregroundColor(.primary)
                            .font(.body)

                        Spacer()
                    }
                    .padding(12)
                    .background(selectedOption == option ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Multi Choice Input

    private var multiChoiceInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(question.options, id: \.self) { option in
                Button(action: { toggleOption(option) }) {
                    HStack {
                        Image(systemName: selectedOptions.contains(option) ? "checkmark.square.fill" : "square")
                            .foregroundColor(selectedOptions.contains(option) ? .accentColor : .secondary)
                            .font(AIAgentFonts.selectionIcon)

                        Text(option)
                            .foregroundColor(.primary)
                            .font(.body)

                        Spacer()
                    }
                    .padding(12)
                    .background(selectedOptions.contains(option) ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            if !selectedOptions.isEmpty {
                Text("\(selectedOptions.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Text Input

    private var textInputArea: some View {
        // Enable autocorrect when using virtual keyboard, disable for hardware keyboard
        TextField(question.placeholder ?? "Enter your response...", text: $textInput, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...5)
            .autocorrectionDisabled(KeyboardTracker.shared.isHardwareKeyboard)
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: onSkip) {
                Text("Skip")
                    .font(AIAgentFonts.buttonSecondary)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)

            Spacer()

            Button(action: submitAnswer) {
                Label("Submit", systemImage: "arrow.right.circle.fill")
                    .font(AIAgentFonts.button)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .padding(.top, 4)
    }

    private var skipLink: some View {
        HStack {
            Spacer()
            Button(action: onSkip) {
                Text("Skip question")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var canSubmit: Bool {
        switch question.inputType {
        case .yesNo:
            return true // Handled by direct buttons
        case .singleChoice:
            return selectedOption != nil
        case .multiChoice:
            return true // Empty selection is valid
        case .text:
            return !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func toggleOption(_ option: String) {
        if selectedOptions.contains(option) {
            selectedOptions.remove(option)
        } else {
            selectedOptions.insert(option)
        }
    }

    private func submitAnswer() {
        let value: AIAgentAnswer.Value

        switch question.inputType {
        case .yesNo:
            return // Handled by direct buttons
        case .singleChoice:
            guard let selected = selectedOption else { return }
            value = .singleChoice(selected)
        case .multiChoice:
            value = .multiChoice(Array(selectedOptions))
        case .text:
            value = .text(textInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        onAnswer(value)
    }
}

// MARK: - Preview

#if DEBUG
struct QuestionCardView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 20) {
                QuestionCardView(
                    question: AIAgentQuestion(
                        toolCallId: "1",
                        question: "Do you want to proceed with the installation?",
                        inputType: .yesNo,
                        context: "This will install nginx and its dependencies."
                    ),
                    onAnswer: { _ in },
                    onSkip: {}
                )

                QuestionCardView(
                    question: AIAgentQuestion(
                        toolCallId: "2",
                        question: "Which web server would you like to install?",
                        inputType: .singleChoice,
                        options: ["nginx", "apache2", "caddy", "lighttpd"]
                    ),
                    onAnswer: { _ in },
                    onSkip: {}
                )

                QuestionCardView(
                    question: AIAgentQuestion(
                        toolCallId: "3",
                        question: "Select the services to restart:",
                        inputType: .multiChoice,
                        options: ["nginx", "php-fpm", "mysql", "redis"],
                        context: "Selected services will be restarted one by one."
                    ),
                    onAnswer: { _ in },
                    onSkip: {}
                )

                QuestionCardView(
                    question: AIAgentQuestion(
                        toolCallId: "4",
                        question: "What domain name should be used?",
                        inputType: .text,
                        placeholder: "example.com"
                    ),
                    onAnswer: { _ in },
                    onSkip: {}
                )
            }
            .padding()
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
#endif
#endif
