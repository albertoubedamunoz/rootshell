#if !targetEnvironment(macCatalyst)

import Foundation

/// Wraps a libgit2 C API call, throwing a descriptive error on failure.
func lg2Check(_ error: Int32, _ message: String, extra: String? = nil) throws {
    guard error < 0 else { return }
    let lg2err = git_error_last()
    let detail: String
    if let lg2err, let msg = lg2err.pointee.message {
        detail = String(cString: msg)
    } else {
        detail = "unknown error"
    }
    throw GitError.libgit2(code: error, message: message, detail: detail, extra: extra)
}

/// Request to open an editor for composing a commit message.
struct GitEditorRequest: Sendable {
    let filePath: String
    let workingDirectory: String
    let passthroughArgs: [String]  // flags to forward (e.g., ["--allow-empty"])
}

/// Errors from git command execution.
enum GitError: LocalizedError {
    case libgit2(code: Int32, message: String, detail: String, extra: String?)
    case invalidArguments(String)
    case notARepository
    case cancelled
    case editorNeeded(request: GitEditorRequest)

    var errorDescription: String? {
        switch self {
        case .libgit2(_, let message, let detail, let extra):
            var desc = "\(message): \(detail)"
            if let extra { desc += " (\(extra))" }
            return desc
        case .invalidArguments(let msg):
            return msg
        case .notARepository:
            return "not a git repository (or any parent up to mount point /)"
        case .cancelled:
            return "operation cancelled"
        case .editorNeeded:
            return "editor needed for commit message"
        }
    }

    var styledDescription: String {
        let msg = errorDescription ?? "unknown error"
        return "\(GitStyle.fg(GitStyle.errorColor, "fatal: "))\(msg)\r\n"
    }
}

#endif
