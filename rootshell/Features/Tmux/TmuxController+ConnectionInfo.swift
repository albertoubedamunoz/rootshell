import Foundation

extension TmuxController {
    /// All queries use this gateway's control client, whether its transport is
    /// a local PTY, SSH, Mosh, Trzsz, or a wrapper session.
    func connectionSnapshot(for request: TmuxConnectionInfo) async throws -> TmuxConnectionSnapshot {
        let revision = connectionInfoSessionRevision
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard !didEnd, !isDetaching, !ownerSurfaceFreed,
                  request.controllerID == nil || request.controllerID == connectionInfoID else {
                throw TmuxCommandError.gatewayEnded
            }
            guard revision == connectionInfoSessionRevision else {
                throw TmuxConnectionInfoError.sessionChanged
            }
        }
        try checkCurrent()
        let metadata = try await sendCommandWithReply(
            "display-message -p -F \(TmuxConnectionInfoParser.formatArgument(TmuxConnectionInfoParser.metadataKeys))",
            timeout: .seconds(4))
        try checkCurrent()
        // Parse identity before using it as a target. Never interpolate names.
        let initial = try TmuxConnectionInfoParser.parseMetadata(metadata, windows: [], windowID: nil, pane: nil)
        guard currentSessionId == initial.session.id else { throw TmuxConnectionInfoError.sessionChanged }
        let body = try await sendCommandWithReply(
            "list-windows -t \"$\(initial.session.id)\" -F \(TmuxConnectionInfoParser.formatArgument(TmuxConnectionInfoParser.windowKeys))",
            timeout: .seconds(4))
        try checkCurrent()
        let windows = try TmuxConnectionInfoParser.parseWindows(body)
        var pane: TmuxConnectionSnapshot.Pane?
        if let paneID = request.paneID, paneID >= 0,
           windows.contains(where: { $0.id == request.windowID }) {
            let body = try await sendCommandWithReply(
                "display-message -p -t %\(paneID) -F \(TmuxConnectionInfoParser.formatArgument(TmuxConnectionInfoParser.paneKeys))",
                timeout: .seconds(4))
            try checkCurrent()
            pane = try TmuxConnectionInfoParser.parsePane(body)
            guard pane?.id == paneID, pane?.windowID == request.windowID else { throw TmuxConnectionInfoError.malformedReply }
        }
        var result = try TmuxConnectionInfoParser.parseMetadata(
            metadata, windows: windows, windowID: request.windowID, pane: pane)
        result.counters = connectionInfoCounters()
        return result
    }
}
