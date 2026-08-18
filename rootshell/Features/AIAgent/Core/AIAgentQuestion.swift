#if !CHINA_BUILD
//
//  AIAgentQuestion.swift
//  rootshell
//
//  Question model for AI Agent user prompts
//

import Foundation

/// A question proposed by the AI agent for user input
struct AIAgentQuestion: Identifiable, Sendable, Equatable {
    let id: UUID
    let toolCallId: String
    let question: String
    let inputType: InputType
    let options: [String]
    let placeholder: String?
    let context: String?
    let timestamp: Date
    let isFromXMLToolCall: Bool  // True if from MiniMax XML parsing

    /// Types of user input
    enum InputType: String, Sendable, Codable {
        case yesNo = "yes_no"
        case singleChoice = "single_choice"
        case multiChoice = "multi_choice"
        case text = "text"

        var displayName: String {
            switch self {
            case .yesNo: return "Yes/No"
            case .singleChoice: return "Choose One"
            case .multiChoice: return "Select Multiple"
            case .text: return "Text Input"
            }
        }
    }

    init(
        id: UUID = UUID(),
        toolCallId: String,
        question: String,
        inputType: InputType,
        options: [String] = [],
        placeholder: String? = nil,
        context: String? = nil,
        timestamp: Date = Date(),
        isFromXMLToolCall: Bool = false
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.question = question
        self.inputType = inputType
        self.options = options
        self.placeholder = placeholder
        self.context = context
        self.timestamp = timestamp
        self.isFromXMLToolCall = isFromXMLToolCall
    }

    static func == (lhs: AIAgentQuestion, rhs: AIAgentQuestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// User's answer to an AI agent question
struct AIAgentAnswer: Sendable {
    let questionId: UUID
    let toolCallId: String
    let value: Value
    let timestamp: Date

    /// Answer value types
    enum Value: Sendable {
        case yesNo(Bool)
        case singleChoice(String)
        case multiChoice([String])
        case text(String)
        case cancelled

        /// Serialize to string for tool result
        func toResultString() -> String {
            switch self {
            case .yesNo(let answer):
                return answer ? "Yes" : "No"
            case .singleChoice(let selected):
                return selected
            case .multiChoice(let selections):
                if selections.isEmpty {
                    return "No selections made"
                }
                return selections.joined(separator: ", ")
            case .text(let input):
                if input.isEmpty {
                    return "(empty response)"
                }
                return input
            case .cancelled:
                return "User cancelled/skipped this question"
            }
        }
    }

    init(questionId: UUID, toolCallId: String, value: Value, timestamp: Date = Date()) {
        self.questionId = questionId
        self.toolCallId = toolCallId
        self.value = value
        self.timestamp = timestamp
    }
}
#endif
