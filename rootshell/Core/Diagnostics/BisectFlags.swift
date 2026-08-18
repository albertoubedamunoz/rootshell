//
//  BisectFlags.swift
//  rootshell
//
//  Compile-time toggles for the resume-wedge bisection commits.
//  Flip any combination to false and rebuild — the matching gate site
//  reverts to the pre-bisect behavior. Each flag corresponds to one of
//  the bisect commits (1/4 ... 4/4).
//
//  All flags default to true (gate active) so the file as-shipped is the
//  "all four gates on" build. To narrow down the culprit, set one or
//  more to false and rebuild.
//

enum BisectFlags {
    /// bisect 1/4 — gate TrzszSession.publishRoamBannerState during the
    /// resume quiet window. Set to false to let banner publishes flow
    /// normally on resume.
    static let gate1_publishRoamBannerState = true

    /// bisect 2/4 — gate TerminalView.applyConnectionHealth's @Published
    /// write during the resume quiet window. Set to false to let health
    /// updates propagate normally on resume.
    static let gate2_connectionHealth = true

    /// bisect 3/4 — skip the post-drain ghosttyApp.appTick() that would
    /// otherwise process every buffered C-side mailbox event. Set to
    /// false to drain the mailbox immediately when the gate opens.
    static let gate3_appTick = true

    /// bisect 4/4 — skip per-visible-terminal setOcclusion(true) on
    /// resume during the quiet window. Set to false to call
    /// setOcclusion(true) immediately as part of resume work.
    static let gate4_setOcclusion = true
}
