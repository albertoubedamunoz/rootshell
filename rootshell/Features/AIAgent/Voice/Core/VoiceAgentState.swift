#if !CHINA_BUILD
//
//  VoiceAgentState.swift
//  rootshell
//
//  State machine for the voice agent session lifecycle.
//

import Foundation

/// States for the voice agent session.
enum VoiceAgentState: Equatable, Sendable {
    /// Not started
    case idle

    /// Connecting WebSocket to Gemini Live API
    case connecting

    /// Connected and listening for user speech
    case listening

    /// Model is generating/speaking a response
    case speaking

    /// Waiting for tool call approval from user
    case awaitingApproval(VoiceAgentToolCall)

    /// Executing a tool call
    case executingTool(VoiceAgentToolCall)

    /// Consulting the expert model (Gemini Pro)
    case consultingExpert

    /// Session disconnected (can reconnect)
    case disconnected(reason: String?)

    /// Unrecoverable error
    case error(String)

    // MARK: - Computed Properties

    var isActive: Bool {
        switch self {
        case .listening, .speaking, .awaitingApproval, .executingTool, .consultingExpert:
            return true
        default:
            return false
        }
    }

    var isConnected: Bool {
        switch self {
        case .listening, .speaking, .awaitingApproval, .executingTool, .consultingExpert:
            return true
        default:
            return false
        }
    }

    var statusDescription: String {
        switch self {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting..."
        case .listening:
            return "Listening..."
        case .speaking:
            return "Speaking..."
        case .awaitingApproval:
            return "Approve to continue"
        case .executingTool:
            return "Running..."
        case .consultingExpert:
            return "Thinking deeply..."
        case .disconnected(let reason):
            return reason ?? "Disconnected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    // MARK: - Equatable

    static func == (lhs: VoiceAgentState, rhs: VoiceAgentState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.connecting, .connecting):
            return true
        case (.listening, .listening):
            return true
        case (.speaking, .speaking):
            return true
        case (.awaitingApproval(let a), .awaitingApproval(let b)):
            return a.id == b.id
        case (.executingTool(let a), .executingTool(let b)):
            return a.id == b.id
        case (.consultingExpert, .consultingExpert):
            return true
        case (.disconnected(let a), .disconnected(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Represents a tool call from the voice agent for approval and execution.
struct VoiceAgentToolCall: Identifiable, Sendable {
    let id: String
    let name: String
    let args: [String: String]
    let displayDescription: String
    let requiresApproval: Bool
    let riskLevel: AIAgentCommand.RiskLevel

    var isWrite: Bool {
        switch name {
        case "send_keystrokes", "send_paste", "execute_ssh_command":
            return true
        default:
            return false
        }
    }
}

/// A transcript entry for the voice agent conversation.
struct VoiceAgentTranscriptEntry: Identifiable, Sendable {
    let id = UUID()
    let role: Role
    let text: String
    let fullContentFilePath: String?
    let timestamp: Date

    enum Role: Sendable {
        case user
        case assistant
        case tool(name: String)
        case system
    }

    init(role: Role, text: String, fullContentFilePath: String? = nil) {
        self.role = role
        self.text = text
        self.fullContentFilePath = fullContentFilePath
        self.timestamp = Date()
    }
}
#endif
