/// Eligibility for the existing, finite UIKit background grace request.
/// Live Activity and Location Diary state deliberately are not inputs: neither
/// establishes that the app currently has execution time for its connections.
nonisolated enum RemoteSessionBackgroundGracePolicy {
    enum SkipReason: String {
        case settingDisabled
        case noSessions
        case alreadyActive
    }

    static func skipReason(isEnabled: Bool, sessionCount: Int, hasActiveTask: Bool) -> SkipReason? {
        guard isEnabled else { return .settingDisabled }
        guard sessionCount > 0 else { return .noSessions }
        guard !hasActiveTask else { return .alreadyActive }
        return nil
    }
}
