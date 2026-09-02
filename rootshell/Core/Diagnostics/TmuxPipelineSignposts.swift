import os

/// os_signpost intervals around the Ghostty app tick and the tmux control-mode
/// title/reconcile path. Shows up in Instruments under the os_signpost track
/// (subsystem com.rootshell, category TmuxPipeline) so a hitch can be lined up
/// with the main-thread work that caused it. Near-zero cost when not traced.
nonisolated enum TmuxPipelineSignposts {
    static let signposter = OSSignposter(subsystem: "com.rootshell", category: "TmuxPipeline")

    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
