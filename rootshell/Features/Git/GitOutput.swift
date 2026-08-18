#if !targetEnvironment(macCatalyst)

import Foundation

/// Styled terminal output builder for git commands.
/// Accumulates text and flushes to an output callback.
struct GitOutput: @unchecked Sendable {
    private var buffer: String = ""
    let write: @Sendable (String) -> Void

    init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    /// Append a line (with \r\n terminal line ending).
    mutating func line(_ text: String = "") {
        buffer.append(text)
        buffer.append("\r\n")
    }

    /// Append styled (colored) text without a newline.
    mutating func styled(_ color: TerminalStyle.Color, _ text: String) {
        buffer.append(GitStyle.fg(color, text))
    }

    /// Append bold+colored text without a newline.
    mutating func boldStyled(_ color: TerminalStyle.Color, _ text: String) {
        buffer.append(GitStyle.boldFg(color, text))
    }

    /// Append a Nerd Font icon with color, followed by a space.
    mutating func icon(_ icon: String, color: TerminalStyle.Color) {
        buffer.append(GitStyle.fg(color, icon))
        buffer.append(" ")
    }

    /// Append raw text without formatting.
    mutating func raw(_ text: String) {
        buffer.append(text)
    }

    /// Flush accumulated buffer to the output callback and clear.
    mutating func flush() {
        guard !buffer.isEmpty else { return }
        write(buffer)
        buffer = ""
    }

    /// Write text directly without buffering.
    func writeDirect(_ text: String) {
        write(text)
    }
}

#endif
