//
//  VPNLiveActivityUpdater.swift
//  SessionActivityWidget
//
//  Keeps the Live Activity's VPN fields in sync when VPN AppIntents run from
//  the widget/control extension instead of the main app process.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

enum VPNLiveActivityUpdater {
    static func syncFromWidgetState() async {
        guard let vpnState = VPNWidgetState.read() else { return }

        switch vpnState.status {
        case "connected", "connecting", "reconnecting", "disconnecting":
            await updateActivities { currentState in
                var state = currentState
                state.vpnProfileName = vpnState.profileName ?? "VPN"
                state.vpnHost = vpnState.host
                state.vpnStatus = vpnState.status
                state.vpnConnectedSince = vpnState.status == "connected" ? vpnState.connectedSince : nil
                if vpnState.status != "connected" {
                    state.vpnBytesIn = nil
                    state.vpnBytesOut = nil
                    state.vpnActiveConnections = nil
                }
                state.lastUpdated = Date()
                return .update(state)
            }
        default:
            await clearVPNState()
        }
    }

    static func clearVPNState() async {
        await updateActivities { currentState in
            var state = currentState
            state.vpnProfileName = nil
            state.vpnHost = nil
            state.vpnStatus = nil
            state.vpnConnectedSince = nil
            state.vpnBytesIn = nil
            state.vpnBytesOut = nil
            state.vpnActiveConnections = nil
            state.lastUpdated = Date()

            let hasSessionContent = state.sessionCount > 0 || state.roamCount > 0 || state.localTaskCount > 0
            let hasInfoContent =
                state.wifiSSID != nil ||
                state.wifiAPName != nil ||
                state.networkPublicIP != nil ||
                state.networkASName != nil
            return hasSessionContent || hasInfoContent ? .update(state) : .end(state)
        }
    }

    private enum Action {
        case update(SessionActivityAttributes.ContentState)
        case end(SessionActivityAttributes.ContentState)
    }

    private static func updateActivities(
        _ transform: (SessionActivityAttributes.ContentState) -> Action
    ) async {
        for activity in Activity<SessionActivityAttributes>.activities {
            switch transform(activity.content.state) {
            case .update(let state):
                await activity.update(ActivityContent(state: state, staleDate: nil))
            case .end(let state):
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
