import Foundation

/// Local `select-pane` commands tmux hasn't answered, per window. tmux echoes
/// `%window-pane-changed` to the sender too, and serializes commands, so focus
/// reports for a window with selects in flight are our own stale echoes.
/// ROOTSHELL-TMUX (id=tmux-focus-echo-gate)
nonisolated struct TmuxLocalFocusGate {
    /// Completions carry their entry's token so one issued before a remove can't
    /// release an entry recreated for the same window.
    struct Token: Equatable, Sendable {
        fileprivate let windowId: Int
        fileprivate let entry: UInt64
    }

    private var pending: [Int: (entry: UInt64, outstanding: Int, paneId: Int)] = [:]
    private var nextEntry: UInt64 = 0

    mutating func noteSent(windowId: Int, paneId: Int) -> Token {
        if let existing = pending[windowId] {
            pending[windowId] = (existing.entry, existing.outstanding + 1, paneId)
            return Token(windowId: windowId, entry: existing.entry)
        }
        nextEntry &+= 1
        pending[windowId] = (nextEntry, 1, paneId)
        return Token(windowId: windowId, entry: nextEntry)
    }

    mutating func noteCompleted(_ token: Token) {
        guard let existing = pending[token.windowId], existing.entry == token.entry else { return }
        if existing.outstanding <= 1 {
            pending.removeValue(forKey: token.windowId)
        } else {
            pending[token.windowId] = (existing.entry, existing.outstanding - 1, existing.paneId)
        }
    }

    /// A report naming the latest local intent passes; applying it is a no-op.
    func suppresses(windowId: Int, paneId: Int) -> Bool {
        guard let existing = pending[windowId] else { return false }
        return existing.paneId != paneId
    }

    mutating func remove(windowId: Int) {
        pending.removeValue(forKey: windowId)
    }

    mutating func removeAll() {
        pending.removeAll()
    }
}
