import Foundation

/// Restoration timestamps must not override newer activity from a live session.
nonisolated enum TrzszResumeActivity {
    static func latestConfirmedActivity(
        restored: Date?, connected: Date?, heartbeat: Date?, fallback: Date
    ) -> Date {
        [restored, connected, heartbeat].compactMap { $0 }.max() ?? fallback
    }
}
