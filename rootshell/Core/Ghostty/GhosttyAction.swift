import SwiftUI
import GhosttyKit
import Combine

extension Ghostty.Action {
    /// Wrapper for the start_search action from C API
    struct StartSearch {
        let needle: String?

        init(c: ghostty_action_start_search_s) {
            if let cStr = c.needle {
                self.needle = String(cString: cStr)
            } else {
                self.needle = nil
            }
        }
    }
}

// MARK: - Search State

extension Ghostty {
    /// Observable state for scrollback search
    @MainActor
    final class SearchState: ObservableObject {
        @Published var needle: String = ""
        @Published var selected: UInt? = nil
        @Published var total: UInt? = nil

        init(from startSearch: Ghostty.Action.StartSearch) {
            self.needle = startSearch.needle ?? ""
        }
    }
}

extension Ghostty.Action {
    struct ProgressReport {
        enum State: CustomStringConvertible {
            case remove
            case set
            case error
            case indeterminate
            case pause

            init(_ c: ghostty_action_progress_report_state_e) {
                switch c {
                case GHOSTTY_PROGRESS_STATE_REMOVE:
                    self = .remove
                case GHOSTTY_PROGRESS_STATE_SET:
                    self = .set
                case GHOSTTY_PROGRESS_STATE_ERROR:
                    self = .error
                case GHOSTTY_PROGRESS_STATE_INDETERMINATE:
                    self = .indeterminate
                case GHOSTTY_PROGRESS_STATE_PAUSE:
                    self = .pause
                default:
                    self = .remove
                }
            }

            var description: String {
                switch self {
                case .remove: return "remove"
                case .set: return "set"
                case .error: return "error"
                case .indeterminate: return "indeterminate"
                case .pause: return "pause"
                }
            }
        }

        let state: State
        let progress: UInt8?

        init(c: ghostty_action_progress_report_s) {
            self.state = State(c.state)
            self.progress = c.progress >= 0 ? UInt8(c.progress) : nil
        }

        init(state: State, progress: UInt8?) {
            self.state = state
            self.progress = progress
        }
    }

    /// An OSC 7501 program status report, copied out of the C payload,
    /// which is only valid during the action callback.
    struct ProgramStatus {
        enum State {
            case idle, working, done, blocked, error, clear
        }

        enum Kind {
            case none, permission, question, auth
        }

        let state: State
        let kind: Kind
        let progress: UInt8?
        /// Empty for the root record.
        let id: String
        let app: String
        let title: String
        let msg: String

        init(c: ghostty_action_program_status_s) {
            switch c.state {
            case GHOSTTY_PROGRAM_STATUS_IDLE: state = .idle
            case GHOSTTY_PROGRAM_STATUS_WORKING: state = .working
            case GHOSTTY_PROGRAM_STATUS_DONE: state = .done
            case GHOSTTY_PROGRAM_STATUS_BLOCKED: state = .blocked
            case GHOSTTY_PROGRAM_STATUS_ERROR: state = .error
            default: state = .clear
            }
            switch c.kind {
            case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: kind = .permission
            case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: kind = .question
            case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: kind = .auth
            default: kind = .none
            }
            progress = c.progress >= 0 ? UInt8(c.progress) : nil
            id = c.id.map { String(cString: $0) } ?? ""
            app = c.app.map { String(cString: $0) } ?? ""
            title = c.title.map { String(cString: $0) } ?? ""
            msg = c.msg.map { String(cString: $0) } ?? ""
        }

        /// One line for ProgramStatusDebugLogger.
        var logDescription: String {
            "id=\"\(id)\" state=\(state) kind=\(kind) progress=\(progress.map(String.init) ?? "nil")"
                + " app=\"\(app)\" title=\"\(title)\" msg=\"\(msg)\""
        }
    }
}
