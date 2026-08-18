//
//  TaskAttentionTracker.swift
//  rootshell
//
//  Per-pane state machine for task detection (long-running commands and
//  input prompts), the lightweight sibling of AgentPaneMonitor's agent
//  identity. Tasks are print-and-exit programs, not long-lived TUIs, so
//  the rules differ in three deliberate ways:
//
//  - A matching working/blocked rule IS identification; there is no
//    separate signature pass and no presence pass. Terminal states
//    (done/failed) can only classify while a task is held, so scrollback
//    can never mint identity or invent a completion.
//  - No match is evidence of ABSENCE, not idleness: a short streak of
//    no-match scans clears the identity silently (an interrupted run
//    never announces a result).
//  - Blocked commits additionally require the same prompt line on two
//    consecutive scans, so a prompt must persist (≥1 scan interval of
//    quiescence) before it may badge or notify.
//
//  Pure Foundation so the standalone harness compiles it without UIKit.
//

import Foundation

nonisolated struct TaskAttentionTracker {

    // MARK: - Identity

    private(set) var taskID: String?
    private(set) var displayName: String?
    private(set) var family: TaskFamily?

    /// Identity of the task whose run just ended, retained so the
    /// completion card and notification still name it after the live
    /// identity clears. Mirrors the monitor's finishedAgentID.
    private(set) var finishedTaskID: String?
    private(set) var finishedDisplayName: String?
    private(set) var finishedFamily: TaskFamily?

    var isActive: Bool { taskID != nil }

    // MARK: - State machine

    private(set) var stableState: AgentScreenState = .unknown
    private var stabilizer = AgentScreenStateStabilizer()
    private var eventState = AgentAttentionEventState()

    /// Consecutive scans in which no rule of the held task (nor the
    /// prompt overlay) matched. Tasks decay fast: their output scrolls
    /// away the moment the program exits or is interrupted.
    private var noMatchStreak = 0

    /// Last non-empty bottom line seen alongside a blocked
    /// classification. Blocked commits require the SAME line twice in a
    /// row — the persistence guard that keeps a scrolling `password:` in
    /// output from ever badging.
    private(set) var lastPromptLine: String?

    /// A blocked classification recorded its line and is waiting for the
    /// identical line on the next scan. Must drive the center's
    /// confirmation follow-up: a waiting prompt is SILENT, so no content
    /// event will ever schedule that second scan on its own (field repro:
    /// an apt confirm sat unrecognized for 32s, then a second run was
    /// never recognized at all).
    private var pendingPromptConfirmation = false

    var needsConfirmation: Bool { stabilizer.needsConfirmation || pendingPromptConfirmation }
    var hasNoMatchStreak: Bool { isActive && noMatchStreak > 0 }

    // MARK: - Timing / inbox fields

    private(set) var workingSince: Date?
    private(set) var finishedAt: Date?
    private(set) var exitCode: Int?
    private(set) var lastDuration: TimeInterval?
    private(set) var doneUnseen = false
    private(set) var failedUnseen = false
    private(set) var progressText: String?

    var hasUnseenCompletion: Bool { doneUnseen || failedUnseen }

    private enum Tuning {
        /// Live identity clears after this many consecutive no-match scans.
        static let noMatchClearStreak = 3
    }

    // MARK: - Identity transitions

    /// Adopt (or re-confirm) a task identity. Re-adopting the same id is
    /// a no-op so repeated identification scans don't reset the machine.
    mutating func adopt(id: String, displayName: String, family: TaskFamily, now: Date) {
        guard taskID != id else { return }
        taskID = id
        self.displayName = displayName
        self.family = family
        finishedTaskID = nil
        finishedDisplayName = nil
        finishedFamily = nil
        stableState = .unknown
        stabilizer.reset()
        noMatchStreak = 0
        lastPromptLine = nil
        pendingPromptConfirmation = false
        workingSince = nil
        finishedAt = nil
        exitCode = nil
        lastDuration = nil
        doneUnseen = false
        failedUnseen = false
        progressText = nil
        eventState.updateScreenStatus(nil)
        eventState.clearCompletion()
    }

    /// Full reset, dropping unseen completions too. Used when an agent
    /// takes the pane or the feature (or the task's family) turns off.
    mutating func reset() {
        self = TaskAttentionTracker()
    }

    // MARK: - Observations

    /// Fold one scan's classification of the held task in. Returns true
    /// when the display-relevant state changed (commit, completion, or a
    /// progress-bucket change).
    mutating func observe(
        _ classification: AgentClassification,
        promptLine: String?,
        progress: String?,
        viewedNow: Bool,
        now: Date
    ) -> Bool {
        guard isActive else { return false }
        noMatchStreak = 0

        var changed = false
        if progressText != progress {
            progressText = progress
            changed = true
        }

        // Blocked needs the same prompt line on two consecutive scans.
        // The first sighting only records the line; the stabilizer's
        // immediate-commit path (unknown + visible evidence) then fires
        // on the second identical sighting, which is exactly the
        // two-observation persistence the prompts family promises.
        if classification.state == .blocked {
            let line = promptLine ?? ""
            if line != lastPromptLine {
                lastPromptLine = line
                pendingPromptConfirmation = stableState != .blocked
                return changed
            }
        } else {
            lastPromptLine = classification.state == .unknown ? lastPromptLine : nil
            pendingPromptConfirmation = false
        }

        switch stabilizer.observe(current: stableState, classification: classification) {
        case .hold:
            return changed
        case .commit(let target):
            pendingPromptConfirmation = false
            return commit(target, viewedNow: viewedNow, now: now) || changed
        }
    }

    /// One scan matched nothing for the held task. Returns true when the
    /// live identity cleared (display change). An unseen completion from
    /// a just-finished run survives the clear.
    mutating func noteNoMatch() -> Bool {
        guard isActive else { return false }
        noMatchStreak += 1
        guard noMatchStreak >= Tuning.noMatchClearStreak else { return false }
        clearLiveIdentity()
        return true
    }

    /// OSC 133 command-finished fusion: the shell's exit code is
    /// authoritative and instant where shell integration exists; screen
    /// summary rules cover hosts without it. Returns true when the
    /// display changed.
    mutating func finalize(exitCode: Int?, duration: TimeInterval, viewedNow: Bool, now: Date) -> Bool {
        guard isActive else { return false }
        self.exitCode = exitCode
        lastDuration = duration
        let failed = (exitCode ?? 0) != 0
        return concludeRun(failed: failed, viewedNow: viewedNow, now: now)
    }

    /// The pane was actually viewed: consume unseen results and drop the
    /// finished identity, exactly like the agent side.
    mutating func markSeen() {
        guard doneUnseen || failedUnseen else { return }
        doneUnseen = false
        failedUnseen = false
        finishedTaskID = nil
        finishedDisplayName = nil
        finishedFamily = nil
        eventState.clearCompletion()
    }

    // MARK: - Display

    /// The semantic event this tracker contributes, or nil when there is
    /// nothing to show. Blocked outranks an unseen completion (the pane
    /// is demanding attention NOW); otherwise unseen results win over
    /// the live screen state.
    func displayEvent() -> AgentAttentionEvent? {
        if isActive, stableState == .blocked { return eventState.screenEvent }
        if hasUnseenCompletion { return eventState.completionEvent }
        guard isActive else { return nil }
        return eventState.screenEvent
    }

    /// Everything the monitor needs to build an AgentRowState for this
    /// tracker; nil when nothing should show.
    func rowFragment() -> (
        status: AgentAttentionStatus,
        taskID: String,
        displayName: String,
        workingSince: Date?,
        finishedAt: Date?,
        exitCode: Int?,
        lastDuration: TimeInterval?,
        unread: Bool,
        progress: String?
    )? {
        guard let event = displayEvent() else { return nil }
        guard let id = taskID ?? finishedTaskID else { return nil }
        let name = displayName ?? finishedDisplayName ?? id
        return (
            status: event.status,
            taskID: id,
            displayName: name,
            workingSince: event.status == .working ? workingSince : nil,
            finishedAt: finishedAt,
            exitCode: exitCode,
            lastDuration: lastDuration,
            unread: hasUnseenCompletion,
            progress: event.status == .working ? progressText : nil
        )
    }

    // MARK: - Private

    private mutating func commit(_ target: AgentScreenState, viewedNow: Bool, now: Date) -> Bool {
        switch target {
        case .working:
            stableState = .working
            if workingSince == nil { workingSince = now }
            // Resumed work invalidates a stale unread result the same way
            // the monitor's commit does.
            doneUnseen = false
            failedUnseen = false
            eventState.clearCompletion()
            eventState.updateScreenStatus(.working, category: .task)
            return true
        case .blocked:
            stableState = .blocked
            doneUnseen = false
            failedUnseen = false
            eventState.clearCompletion()
            eventState.updateScreenStatus(.blocked, category: .task)
            return true
        case .done:
            return concludeRun(failed: false, viewedNow: viewedNow, now: now)
        case .failed:
            return concludeRun(failed: true, viewedNow: viewedNow, now: now)
        case .idle, .unknown:
            stableState = target
            eventState.updateScreenStatus(nil)
            return true
        }
    }

    private mutating func concludeRun(failed: Bool, viewedNow: Bool, now: Date) -> Bool {
        finishedAt = now
        if lastDuration == nil, let start = workingSince {
            lastDuration = now.timeIntervalSince(start)
        }
        if !viewedNow {
            if failed {
                failedUnseen = true
            } else {
                doneUnseen = true
            }
            eventState.recordCompletion(failed ? .failed : .done, category: .task)
        }
        clearLiveIdentity()
        return true
    }

    /// Drop the live identity, keeping completion fields so an unseen
    /// result still renders and names its task.
    private mutating func clearLiveIdentity() {
        if let taskID {
            finishedTaskID = taskID
            finishedDisplayName = displayName
            finishedFamily = family
        }
        taskID = nil
        displayName = nil
        family = nil
        stableState = .unknown
        stabilizer.reset()
        noMatchStreak = 0
        lastPromptLine = nil
        pendingPromptConfirmation = false
        workingSince = nil
        progressText = nil
        eventState.updateScreenStatus(nil)
    }
}
