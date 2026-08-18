#if !CHINA_BUILD
//
//  AIAgentState.swift
//  rootshell
//
//  AI Agent state machine states
//

import Foundation

/// States for the AI Agent conversation
enum AIAgentState: Equatable, Sendable {
    /// Idle - no active conversation or waiting for user input
    case idle

    /// Waiting for LLM response
    case thinking

    /// LLM returned a command, awaiting user approval
    case awaitingApproval(AIAgentCommand)

    /// LLM asked a question, awaiting user answer
    case awaitingAnswer(AIAgentQuestion)

    /// User approved, command is executing
    case executing(AIAgentCommand)

    /// Performing a web search
    case webSearching(query: String, engine: String)

    /// Fetching a web page
    case webFetching(url: String)

    /// Command completed successfully, showing result
    case commandCompleted(AIAgentCommand, output: String)

    /// Command failed with error
    case commandFailed(AIAgentCommand, error: String)

    /// Error state (API error, network error, etc.)
    case error(AIAgentErrorCategory)

    // MARK: - Computed Properties

    /// Whether the agent is busy and shouldn't accept new input
    var isBusy: Bool {
        switch self {
        case .thinking, .executing, .webSearching, .webFetching:
            return true
        case .idle, .awaitingApproval, .awaitingAnswer, .commandCompleted, .commandFailed, .error:
            return false
        }
    }

    /// Whether the agent is awaiting user action (approval or answer)
    var isAwaitingUserAction: Bool {
        switch self {
        case .awaitingApproval, .awaitingAnswer:
            return true
        default:
            return false
        }
    }

    /// Whether the agent is awaiting command approval
    var isAwaitingApproval: Bool {
        if case .awaitingApproval = self {
            return true
        }
        return false
    }

    /// Whether the agent is awaiting user answer
    var isAwaitingAnswer: Bool {
        if case .awaitingAnswer = self {
            return true
        }
        return false
    }

    /// Human-readable status description
    var statusDescription: String {
        switch self {
        case .idle:
            return "Ready"
        case .thinking:
            return "Thinking..."
        case .awaitingApproval:
            return "Awaiting approval"
        case .awaitingAnswer:
            return "Awaiting your answer"
        case .executing:
            return "Executing command..."
        case .webSearching(let query, let engine):
            return "Searching \(engine): \(query)"
        case .webFetching(let url):
            return "Fetching: \(url)"
        case .commandCompleted:
            return "Command completed"
        case .commandFailed:
            return "Command failed"
        case .error(let category):
            return "Error: \(category.title)"
        }
    }

    // MARK: - Equatable

    static func == (lhs: AIAgentState, rhs: AIAgentState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.thinking, .thinking):
            return true
        case (.awaitingApproval(let lhsCmd), .awaitingApproval(let rhsCmd)):
            return lhsCmd.id == rhsCmd.id
        case (.awaitingAnswer(let lhsQ), .awaitingAnswer(let rhsQ)):
            return lhsQ.id == rhsQ.id
        case (.executing(let lhsCmd), .executing(let rhsCmd)):
            return lhsCmd.id == rhsCmd.id
        case (.webSearching(let lhsQuery, let lhsEngine), .webSearching(let rhsQuery, let rhsEngine)):
            return lhsQuery == rhsQuery && lhsEngine == rhsEngine
        case (.webFetching(let lhsURL), .webFetching(let rhsURL)):
            return lhsURL == rhsURL
        case (.commandCompleted(let lhsCmd, let lhsOutput), .commandCompleted(let rhsCmd, let rhsOutput)):
            return lhsCmd.id == rhsCmd.id && lhsOutput == rhsOutput
        case (.commandFailed(let lhsCmd, let lhsError), .commandFailed(let rhsCmd, let rhsError)):
            return lhsCmd.id == rhsCmd.id && lhsError == rhsError
        case (.error(let lhsCategory), .error(let rhsCategory)):
            return lhsCategory == rhsCategory
        default:
            return false
        }
    }
}
#endif
