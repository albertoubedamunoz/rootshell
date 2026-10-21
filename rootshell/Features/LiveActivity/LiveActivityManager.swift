//
//  LiveActivityManager.swift
//  rootshell
//
//  Manages a Live Activity on the Lock Screen / Dynamic Island showing active
//  non-resilient sessions (SSH, Kubernetes, Console). Starts automatically when
//  non-resilient sessions are present and the user has enabled the feature.
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import Observation
import os.log
import UIKit

/// Controls which sessions appear in the Live Activity
enum LiveActivitySessionFilter: String, CaseIterable, Sendable {
    /// All sessions including Roam and local active tasks
    case all
    /// Non-roam sessions that trigger location diary + local active tasks
    case diary
    /// Only VPN data, no session info
    case vpnOnly
    /// Always-on info mode: keeps the activity alive on WiFi/Network info alone,
    /// while still showing sessions and VPN when present.
    case infoOnly

    var displayName: String {
        switch self {
        case .all:
            return String(localized: "All Sessions", comment: "Live Activity filter: show all session types")
        case .diary:
            return String(localized: "Diary Sessions", comment: "Live Activity filter: show non-roam sessions")
        case .vpnOnly:
            return String(localized: "VPN Only", comment: "Live Activity filter: show only VPN data")
        case .infoOnly:
            return String(localized: "Info Only", comment: "Live Activity filter: keep activity alive for WiFi/Network info, no sessions required")
        }
    }
}

@MainActor
@Observable
class LiveActivityManager {
    static let shared = LiveActivityManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LiveActivityManager")

    private static let enabledKey = "live_activity_enabled"
    private static let filterKey = "live_activity_session_filter"
    private static let wifiInfoKey = "live_activity_wifi_info_enabled"
    private static let networkInfoKey = "live_activity_network_info_enabled"

    /// Whether the user has enabled Live Activity
    var isEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.enabled, isEnabled)
            }
            if !isEnabled {
                endActivity()
            } else {
                if isAgentInfoEnabled {
                    refreshAgentCountsCache()
                }
                reconcileActivityLifecycle(reason: "feature enabled")
            }
        }
    }

    /// Which sessions to show in the Live Activity
    var sessionFilter: LiveActivitySessionFilter {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.sessionFilter, sessionFilter)
            }
            handleFilterChanged()
        }
    }

    /// Whether to show WiFi info (SSID, AP) on the Live Activity
    var isWiFiInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.wifiInfo, isWiFiInfoEnabled)
            }
            handleWiFiToggleChanged()
        }
    }

    /// Whether to show network/ISP info (public IP, ISP, country) on the Live Activity
    var isNetworkInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.networkInfo, isNetworkInfoEnabled)
            }
            handleNetworkToggleChanged()
        }
    }

    /// Whether to show detected coding agents (working / need attention / idle)
    var isAgentInfoEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                SettingsStore.shared.set(Settings.LiveActivity.agents, isAgentInfoEnabled)
            }
            handleAgentToggleChanged()
        }
    }

    @ObservationIgnored
    private var isReloading = false

    /// Whether a Live Activity is currently running
    private(set) var isActivityActive: Bool = false

    /// The current activity instance
    @ObservationIgnored
    private var currentActivity: Activity<SessionActivityAttributes>?

    /// Timestamp when the activity was first started (for elapsed timer)
    @ObservationIgnored
    private var activityStartDate: Date?

    /// Task observing activity state updates
    @ObservationIgnored
    private var stateObserverTask: Task<Void, Never>?

    /// Periodic sweep that moves one-hour-old island rows into the archive.
    @ObservationIgnored
    private var agentArchiveSweepTask: Task<Void, Never>?

    /// Whether the user explicitly dismissed the Live Activity (swipe-to-dismiss).
    /// Suppresses auto-restart until a meaningful state change occurs.
    @ObservationIgnored
    private var userDismissed: Bool = false

    /// Tracks the ID of an activity being ended asynchronously, so startActivity()
    /// doesn't redundantly try to end it again.
    @ObservationIgnored
    private var endingActivityId: String?

    /// Bounded retry for Activity.request failures during cold-start restore.
    @ObservationIgnored
    private var startRetryTask: Task<Void, Never>?
    @ObservationIgnored
    private var startRetryAttempt: Int = 0

    private static let maxStartRetryAttempts = 3
    private static let startRetryDelay: Duration = .seconds(1)

    /// Last known non-resilient session count (for auto-restart after timeout)
    @ObservationIgnored
    private var lastSessionCount: Int = 0
    @ObservationIgnored
    private var lastSSHCount: Int = 0
    @ObservationIgnored
    private var lastK8sCount: Int = 0
    @ObservationIgnored
    private var lastConsoleCount: Int = 0
    @ObservationIgnored
    private var lastHostNames: [String] = []
    @ObservationIgnored
    private var lastLocalTaskCount: Int = 0
    @ObservationIgnored
    private var lastRoamCount: Int = 0
    @ObservationIgnored
    private var lastRoamHostNames: [String] = []

    // MARK: - Coding Agent Cached State

    @ObservationIgnored
    private var lastAgentWorkingCount: Int = 0
    @ObservationIgnored
    private var lastAgentAttentionCount: Int = 0
    @ObservationIgnored
    private var lastAgentIdleCount: Int = 0

    /// Coalesces bursts of census changes into one publish.
    @ObservationIgnored
    private var agentPublishTask: Task<Void, Never>?

    /// The content most recently handed to ActivityKit, so the background
    /// edge can republish it with `agentCountsFrozen` set without rebuilding
    /// state (see `handleAppBackgrounded`).
    @ObservationIgnored
    private var lastPublishedState: SessionActivityAttributes.ContentState?

    /// One in-flight ActivityKit update plus the newest state waiting behind it.
    /// A burst of session/agent changes must not queue every intermediate
    /// count: the island should land on the latest state, not replay history.
    @ObservationIgnored
    private var publishTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingPublish: PendingPublish?

    private struct PendingPublish {
        let state: SessionActivityAttributes.ContentState
        let activity: Activity<SessionActivityAttributes>
        let reason: String
    }

    private static let agentPublishCoalesceDelay: Duration = .seconds(1)

    // MARK: - VPN Cached State

    @ObservationIgnored
    private var lastVPNProfileName: String?
    @ObservationIgnored
    private var lastVPNHost: String?
    @ObservationIgnored
    private var lastVPNBytesIn: Int64?
    @ObservationIgnored
    private var lastVPNBytesOut: Int64?
    @ObservationIgnored
    private var lastVPNActiveConnections: Int?
    @ObservationIgnored
    private var lastVPNConnectedSince: Date?
    @ObservationIgnored
    private var lastVPNStatus: String?
    /// In-app Tailscale fills the VPN fields; the widget state only knows
    /// about the VPN, so its sync leaves them alone.
    @ObservationIgnored
    private var vpnStateFromInAppTailnet = false

    // MARK: - WiFi Cached State

    @ObservationIgnored
    private var lastWiFiSSID: String?
    @ObservationIgnored
    private var lastWiFiAPName: String?
    @ObservationIgnored
    private var lastWiFiAPDetail: String?
    @ObservationIgnored
    private var lastWiFiBand: String?

    // MARK: - Network/ISP Cached State

    @ObservationIgnored
    private var lastNetworkPublicIP: String?
    @ObservationIgnored
    private var lastNetworkASName: String?
    @ObservationIgnored
    private var lastNetworkCountryFlag: String?
    @ObservationIgnored
    private var lastNetworkType: String?

    // MARK: - Public Read-Only Accessors (for prompt modules)

    var cachedWiFiSSID: String? { lastWiFiSSID }
    var cachedWiFiAPName: String? { lastWiFiAPName }
    var cachedWiFiAPDetail: String? { lastWiFiAPDetail }
    var cachedWiFiBand: String? { lastWiFiBand }
    var cachedPublicIP: String? { lastNetworkPublicIP }
    var cachedASName: String? { lastNetworkASName }
    var cachedCountryFlag: String? { lastNetworkCountryFlag }
    var cachedNetworkType: String? { lastNetworkType }

    // MARK: - WiFi Polling

    @ObservationIgnored
    private var wifiPollTask: Task<Void, Never>?
    @ObservationIgnored
    private var wifiPollInFlight = false
    @ObservationIgnored
    private var wifiPollFollowUpPending = false
    @ObservationIgnored
    private var wifiPollRequestScheduled = false

    private var wifiPollLifecycleDeferralPending = false
    private var wifiPollLifecycleDeferralAttempt = 0
    private static let wifiPollLifecycleDeferralMaxAttempts = 64
    private static let wifiPollLifecycleDeferralDelay: TimeInterval = 0.25
    @ObservationIgnored
    private var lastWiFiPollStartedAt: Date?

    private static let wifiPollCooldownSeconds: TimeInterval = 1.0
    private static let wifiPeriodicPollInterval: Duration = .seconds(30)
    private static let wifiSlowPollLogThresholdMs: Double = 100
    private nonisolated static let verboseWiFiPollLoggingKey = "lifecycleVerboseWiFiPollLoggingEnabled"

    private nonisolated static var isVerboseWiFiPollLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.verboseWiFiPollLoggingKey)
    }

    private init() {
        let store = SettingsStore.shared
        self.isEnabled = store.get(Settings.LiveActivity.enabled)
        self.sessionFilter = store.get(Settings.LiveActivity.sessionFilter)
        self.isWiFiInfoEnabled = store.get(Settings.LiveActivity.wifiInfo)
        self.isNetworkInfoEnabled = store.get(Settings.LiveActivity.networkInfo)
        self.isAgentInfoEnabled = store.get(Settings.LiveActivity.agents)
        SettingsRefreshHub.shared.register(keys: [
            Settings.LiveActivity.enabled.name, Settings.LiveActivity.sessionFilter.name,
            Settings.LiveActivity.wifiInfo.name, Settings.LiveActivity.networkInfo.name,
            Settings.LiveActivity.agents.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }

        // Reclaim any orphaned Live Activity from a previous app launch.
        //
        // The activity is still alive on the lock screen / Dynamic Island
        // (the user can see it). Ending it just to issue a fresh
        // Activity.request races iOS's per-app activity slot: the async
        // orphan-end Task hasn't completed when the first updateSessionDetails
        // → startActivity → Activity.request fires, and iOS rejects the new
        // request. The visible symptom is "Live Activity doesn't restore
        // after launch until I open a new tab" (the next session-count
        // change fires another startActivity by which time the orphan is
        // actually gone).
        //
        // Adopting the orphan instead avoids that race entirely:
        // updateSessionDetails sees `currentActivity != nil` after restore
        // populates per-type counts and routes through updateActivity()
        // (a non-racing in-place update) rather than startActivity().
        let orphans = Activity<SessionActivityAttributes>.activities
        if !isEnabled {
            // Feature was disabled between launches — clean up everything.
            for orphan in orphans {
                Task {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        } else if let primary = orphans.first(where: { Self.isAdoptableActivityState($0.activityState) }) {
            Self.logger.info("Adopting orphaned Live Activity \(primary.id) from previous launch")
            currentActivity = primary
            lastPublishedState = primary.content.state
            adoptAgentInbox(from: primary.content.state)
            isActivityActive = true
            // activityStartDate isn't recoverable from ActivityKit; leave it
            // nil so the next updateActivity / startActivity uses Date(). The
            // elapsed-timer base resets but the activity itself stays visible
            // and gets fresh content on the first updateSessionDetails call.
            observeActivityState()
            startInfoPollingDeferred()
            // End any extra orphans (shouldn't happen in practice — we only
            // ever request one — but defensive).
            for extra in orphans where extra.id != primary.id {
                Task {
                    await extra.end(nil, dismissalPolicy: .immediate)
                }
            }
        } else {
            for orphan in orphans {
                Task {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.LiveActivity.enabled.name) {
            isEnabled = store.get(Settings.LiveActivity.enabled)
        }
        if keys.contains(Settings.LiveActivity.sessionFilter.name) {
            sessionFilter = store.get(Settings.LiveActivity.sessionFilter)
        }
        if keys.contains(Settings.LiveActivity.wifiInfo.name) {
            isWiFiInfoEnabled = store.get(Settings.LiveActivity.wifiInfo)
        }
        if keys.contains(Settings.LiveActivity.networkInfo.name) {
            isNetworkInfoEnabled = store.get(Settings.LiveActivity.networkInfo)
        }
        if keys.contains(Settings.LiveActivity.agents.name) {
            isAgentInfoEnabled = store.get(Settings.LiveActivity.agents)
        }
    }

    // MARK: - Public API

    /// Called by SessionTracker when the non-resilient session count changes.
    ///
    /// Owns neither the start nor the end path — both are owned by
    /// `updateSessionDetails`, which now receives aggregated per-type counts
    /// across all windows from `SessionTracker.handleCountChanged` and
    /// `SessionTracker.removeWindow`. Routing lifecycle through the
    /// per-type aggregates avoids the stale-cache trap where this method's
    /// scalar `count` argument doesn't tell us whether roam sessions or
    /// local tasks under the current filter would still keep the activity
    /// alive.
    ///
    /// What's left here: tracking the non-resilient count for retry/dismiss
    /// bookkeeping. A real change in the count is treated as user-meaningful
    /// activity, so we clear `userDismissed` (the user closed something or
    /// opened something; they are no longer suppressing the widget) and
    /// reset the start-retry counter.
    func updateNonResilientSessionCount(_ count: Int) {
        guard isEnabled else { return }

        if count != lastSessionCount {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastSessionCount = count
    }

    /// Called with detailed per-type session data
    func updateSessionDetails(sshCount: Int, k8sCount: Int, consoleCount: Int, hostNames: [String], localTaskCount: Int = 0, roamCount: Int = 0, roamHostNames: [String] = []) {
        guard isEnabled else { return }

        // Reset dismiss suppression when session composition changes
        let cappedHostNames = Array(hostNames.prefix(3))
        let cappedRoamHostNames = Array(roamHostNames.prefix(3))
        let compositionChanged = sshCount != lastSSHCount
            || k8sCount != lastK8sCount
            || consoleCount != lastConsoleCount
            || cappedHostNames != lastHostNames
            || localTaskCount != lastLocalTaskCount
            || roamCount != lastRoamCount
            || cappedRoamHostNames != lastRoamHostNames

        if compositionChanged {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastSSHCount = sshCount
        lastK8sCount = k8sCount
        lastConsoleCount = consoleCount
        lastHostNames = cappedHostNames
        lastLocalTaskCount = localTaskCount
        lastRoamCount = roamCount
        lastRoamHostNames = cappedRoamHostNames
        lastSessionCount = filteredSessionCount

        reconcileActivityLifecycle(reason: "session details updated")
    }

    /// The total session count visible under the current filter
    var displayedSessionCount: Int {
        filteredSessionCount
    }

    /// Re-drive lifecycle from cached session/VPN details after app or scene activation.
    /// Cold-start restore can deliver session counts before ActivityKit is ready to
    /// accept a new request; activation gives those cached details another chance
    /// without requiring a later tab mutation.
    func reconcileAfterActivation() {
        let start = CFAbsoluteTimeGetCurrent()
        LifecycleDebugLogger.shared.checkpoint("LiveActivity.reconcile.enter")
        // The island's "mark all read" intent runs in the widget extension and
        // can only leave a timestamp behind; apply it before publishing so the
        // activity does not come back with rows the user already dismissed.
        consumeInboxReadMarker()
        if isAgentInfoEnabled {
            refreshAgentCountsCache()
        }
        syncVPNStateFromWidgetState(reason: "activation")
        reconcileActivityLifecycle(reason: "app activation")
        LifecycleDebugLogger.shared.checkpoint("LiveActivity.reconcile.exit",
            ms: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // MARK: - VPN API

    /// Whether a VPN connection is actively tracked
    private var hasActiveVPN: Bool {
        lastVPNStatus != nil
    }

    /// Called by VPNManager when VPN stats are updated (every 2s poll)
    func updateVPNState(
        profileName: String,
        host: String?,
        status: String,
        bytesIn: Int64,
        bytesOut: Int64,
        activeConnections: Int,
        connectedSince: Date?,
        fromInAppTailnet: Bool = false
    ) {
        guard isEnabled else { return }
        vpnStateFromInAppTailnet = fromInAppTailnet

        // Reset dismiss suppression when VPN connects (status transitions to non-nil)
        if lastVPNStatus == nil {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }

        lastVPNProfileName = profileName
        lastVPNHost = host
        lastVPNStatus = status
        lastVPNBytesIn = bytesIn
        lastVPNBytesOut = bytesOut
        lastVPNActiveConnections = activeConnections
        lastVPNConnectedSince = connectedSince

        reconcileActivityLifecycle(reason: "VPN state updated")
    }

    /// Called by VPNManager when VPN disconnects
    func clearVPNState() {
        // Reset dismiss suppression on VPN disconnect
        userDismissed = false

        vpnStateFromInAppTailnet = false
        lastVPNProfileName = nil
        lastVPNHost = nil
        lastVPNStatus = nil
        lastVPNBytesIn = nil
        lastVPNBytesOut = nil
        lastVPNActiveConnections = nil
        lastVPNConnectedSince = nil

        reconcileActivityLifecycle(reason: "VPN state cleared")
    }

    /// Reconcile cached VPN fields from the app-group state written by the
    /// main app, widget/control intents, and packet-tunnel extension.
    func syncVPNStateFromWidgetState(reason: String) {
        #if !CHINA_BUILD
        guard isEnabled else { return }
        let widgetState = VPNWidgetState.read()
        let vpnUp = widgetState.map { ["connected", "connecting", "reconnecting", "disconnecting"].contains($0.status) } ?? false
        if vpnStateFromInAppTailnet && !vpnUp { return }
        guard let state = widgetState else {
            if lastVPNStatus != nil {
                clearVPNState()
            }
            return
        }

        switch state.status {
        case "connected", "connecting", "reconnecting", "disconnecting":
            if lastVPNStatus == nil {
                userDismissed = false
                cancelStartRetry(resetAttempts: true)
            }

            let sameConnection =
                lastVPNProfileName == state.profileName &&
                lastVPNHost == state.host
            lastVPNProfileName = state.profileName ?? "VPN"
            lastVPNHost = state.host
            lastVPNStatus = state.status
            lastVPNConnectedSince = state.status == "connected" ? state.connectedSince : nil

            if !sameConnection || state.status != "connected" {
                lastVPNBytesIn = nil
                lastVPNBytesOut = nil
                lastVPNActiveConnections = nil
            }

            reconcileActivityLifecycle(reason: "VPN widget state synced: \(reason)")
        default:
            Self.logger.warning("Unknown VPN widget status: \(state.status, privacy: .public)")
            if lastVPNStatus != nil {
                clearVPNState()
            }
        }
        #endif
    }

    // MARK: - WiFi Info

    private var shouldSkipInfoPollingForLifecycle: Bool {
        Ghostty.isAppBackgroundedAtomic ||
        Ghostty.isInResumeQuietWindowAtomic ||
        ForegroundActivationGate.shared.isUnsafeForSceneMutation ||
        UIApplication.shared.applicationState != .active
    }

    /// Called by NetworkInfoLiveActivityBridge (or background hook) to refresh WiFi data
    func pollWiFiInfo() async {
        guard currentActivity != nil, isWiFiInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            return
        }
        if wifiPollInFlight {
            wifiPollFollowUpPending = true
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", "inFlight"),
            ])
            return
        }

        wifiPollInFlight = true
        lastWiFiPollStartedAt = Date()
        let start = CFAbsoluteTimeGetCurrent()
        let verbosePollLogging = Self.isVerboseWiFiPollLoggingEnabled
        if verbosePollLogging {
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.start", ms: nil, [
                ("appState", UIApplication.shared.applicationState),
            ])
        }
        defer {
            wifiPollInFlight = false
            if wifiPollFollowUpPending {
                wifiPollFollowUpPending = false
                requestWiFiInfoPoll(reason: "followUp")
            }
        }

        let wifi = WiFiInfoService.shared
        await wifi.pollForChanges()
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            return
        }

        let ssid = wifi.ssid
        let apName = wifi.matchedAP?.name ?? wifi.vendorName
        let apDetail = wifi.matchedAP.flatMap { $0.shortname ?? $0.model }
        let vendorWebsite = wifi.vendorWebsite
        let band = wifi.currentBand?.rawValue

        let changed = ssid != lastWiFiSSID || apName != lastWiFiAPName || apDetail != lastWiFiAPDetail || band != lastWiFiBand
        lastWiFiSSID = ssid
        lastWiFiAPName = apName
        lastWiFiAPDetail = apDetail
        lastWiFiBand = band

        // Fetch WiFi vendor favicon on change
        if changed, let website = vendorWebsite,
           let domain = FaviconFetcher.extractDomain(from: website) {
            if let pngData = await FaviconManager.shared.favicon(for: domain) {
                LiveActivityFaviconStore.write(slot: .wifiFavicon, pngData: pngData)
            } else {
                LiveActivityFaviconStore.remove(slot: .wifiFavicon)
            }
        } else if changed && vendorWebsite == nil {
            LiveActivityFaviconStore.remove(slot: .wifiFavicon)
        }

        if changed, currentActivity != nil { updateActivity() }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if verbosePollLogging || changed || elapsedMs >= Self.wifiSlowPollLogThresholdMs {
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.end", ms: elapsedMs, [
                ("changed", changed),
                ("hasSSID", ssid != nil),
                ("slow", elapsedMs >= Self.wifiSlowPollLogThresholdMs),
            ])
        }
    }

    func requestWiFiInfoPoll(reason: String) {
        guard currentActivity != nil, isWiFiInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            guard !wifiPollLifecycleDeferralPending else { return }
            guard wifiPollLifecycleDeferralAttempt < Self.wifiPollLifecycleDeferralMaxAttempts else {
                wifiPollLifecycleDeferralAttempt = 0
                LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.deferredDropped", ms: nil, [
                    ("reason", reason),
                    ("backgrounded", Ghostty.isAppBackgroundedAtomic),
                    ("quiet", Ghostty.isInResumeQuietWindowAtomic),
                    ("appState", String(describing: UIApplication.shared.applicationState)),
                ])
                return
            }
            wifiPollLifecycleDeferralPending = true
            wifiPollLifecycleDeferralAttempt += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.wifiPollLifecycleDeferralDelay) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wifiPollLifecycleDeferralPending = false
                    self.requestWiFiInfoPoll(reason: reason)
                }
            }
            return
        }
        wifiPollLifecycleDeferralAttempt = 0

        if wifiPollInFlight {
            wifiPollFollowUpPending = true
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", reason),
            ])
            return
        }

        guard !wifiPollRequestScheduled else {
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
            LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.coalesced", ms: nil, [
                ("reason", reason),
            ])
            return
        }

        let cooldownDelay = lastWiFiPollStartedAt.map {
            max(0, Self.wifiPollCooldownSeconds - Date().timeIntervalSince($0))
        } ?? 0
        wifiPollRequestScheduled = true
        LifecycleDebugLogger.shared.checkpoint("LiveWiFi.poll.scheduled", ms: nil, [
            ("reason", reason),
            ("delayMs", String(format: "%.0f", cooldownDelay * 1000)),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + cooldownDelay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wifiPollRequestScheduled = false
                await self.pollWiFiInfo()
            }
        }
    }

    private func startWiFiPolling() {
        guard wifiPollTask == nil else { return }
        wifiPollTask = Task { [weak self] in
            // Minimum deferral inside the task itself: belt-and-suspenders
            // against any caller that runs during a scene-update / foreground
            // transition (e.g. handleWiFiToggleChanged firing during a UI
            // burst). The caller-side 0.5s in startInfoPollingDeferred is the
            // primary protection for the foreground-transition paths; this
            // 250ms keeps the polling task itself safe in isolation.
            try? await Task.sleep(for: .milliseconds(250))
            while !Task.isCancelled {
                guard let self else { break }
                guard !self.shouldSkipInfoPollingForLifecycle else {
                    LifecycleDebugLogger.shared.bumpSuppression("liveActivity_wifi")
                    try? await Task.sleep(for: Self.wifiPeriodicPollInterval)
                    continue
                }
                self.requestWiFiInfoPoll(reason: "periodic")
                try? await Task.sleep(for: Self.wifiPeriodicPollInterval)
            }
        }
    }

    /// Defer the WiFi-poll task and network bridge start by 0.5s past the
    /// current frame so they don't pile onto a scene-update transaction
    /// (same rationale as in startActivity). The currentActivity guard
    /// drops the work if the activity is torn down inside the window.
    ///
    /// Called from every path that produces a non-nil currentActivity:
    /// startActivity (fresh request), init() (orphan adoption from previous
    /// launch), and adoptExistingActivityIfAvailable (mid-session adoption).
    /// Without this on the adoption paths, lastWiFiSSID stays nil forever and
    /// the lock-screen WiFi block never appears even when the toggle is on.
    private func startInfoPollingDeferred() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.currentActivity != nil else { return }
            ForegroundActivationGate.shared.runWhenSafe(reason: "liveActivity.infoPollingStart") {
                guard self.currentActivity != nil else { return }
                if self.isWiFiInfoEnabled { self.startWiFiPolling() }
                if self.isWiFiInfoEnabled || self.isNetworkInfoEnabled {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
        }
    }

    private func stopWiFiPolling() {
        wifiPollTask?.cancel()
        wifiPollTask = nil
    }

    private func handleWiFiToggleChanged() {
        if isWiFiInfoEnabled {
            // Enabling an info source is a meaningful user action — clear
            // dismiss suppression and start-retry so .infoOnly mode can
            // (re)spin up the activity.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            if currentActivity != nil {
                startWiFiPolling()
                // Start bridge for background hooks if not already running
                if !NetworkInfoLiveActivityBridge.shared.isRunning {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
            // .infoOnly relies on WiFi/Network being enabled — re-evaluate
            // lifecycle in case this toggle just made the activity eligible.
            reconcileActivityLifecycle(reason: "WiFi info enabled")
        } else {
            stopWiFiPolling()
            lastWiFiSSID = nil
            lastWiFiAPName = nil
            lastWiFiAPDetail = nil
            lastWiFiBand = nil
            LiveActivityFaviconStore.remove(slot: .wifiFavicon)
            if currentActivity != nil { updateActivity() }
            // Stop bridge only if network is also disabled
            if !isNetworkInfoEnabled {
                NetworkInfoLiveActivityBridge.shared.stop()
            }
            // .infoOnly may now have no eligible content; reconcile so we end
            // the activity if both info toggles are off and there are no
            // sessions / VPN.
            if sessionFilter == .infoOnly {
                reconcileActivityLifecycle(reason: "WiFi info disabled")
            }
        }
    }

    // MARK: - Network/ISP Info

    /// Called by NetworkInfoLiveActivityBridge when STUN+Geo resolution completes
    func updateNetworkInfo(publicIP: String?, asName: String?, countryFlag: String?, connectionType: String?) {
        guard publicIP != lastNetworkPublicIP || asName != lastNetworkASName
                || countryFlag != lastNetworkCountryFlag || connectionType != lastNetworkType else { return }
        lastNetworkPublicIP = publicIP
        lastNetworkASName = asName
        lastNetworkCountryFlag = countryFlag
        lastNetworkType = connectionType
        if currentActivity != nil { updateActivity() }
    }

    /// Called by NetworkInfoLiveActivityBridge when stopping
    func clearNetworkInfo() {
        lastNetworkPublicIP = nil
        lastNetworkASName = nil
        lastNetworkCountryFlag = nil
        lastNetworkType = nil
        if currentActivity != nil { updateActivity() }
    }

    private func handleNetworkToggleChanged() {
        if isNetworkInfoEnabled {
            // Enabling an info source is a meaningful user action — clear
            // dismiss suppression and start-retry so .infoOnly mode can
            // (re)spin up the activity.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            if currentActivity != nil {
                if NetworkInfoLiveActivityBridge.shared.isRunning {
                    // Bridge already running (WiFi started it) — start the
                    // interface poller and trigger an immediate resolve.
                    NetworkInfoLiveActivityBridge.shared.setInterfaceMonitoring(enabled: true)
                    NetworkInfoLiveActivityBridge.shared.resolveNow()
                } else {
                    NetworkInfoLiveActivityBridge.shared.start()
                }
            }
            // .infoOnly relies on WiFi/Network being enabled — re-evaluate
            // lifecycle in case this toggle just made the activity eligible.
            reconcileActivityLifecycle(reason: "Network info enabled")
        } else {
            clearNetworkInfo()
            LiveActivityFaviconStore.remove(slot: .ispFavicon)
            // Stop the interface poller — no longer needed without network info.
            NetworkInfoLiveActivityBridge.shared.setInterfaceMonitoring(enabled: false)
            // Stop bridge only if WiFi is also disabled
            if !isWiFiInfoEnabled || currentActivity == nil {
                NetworkInfoLiveActivityBridge.shared.stop()
            }
            // .infoOnly may now have no eligible content; reconcile so we end
            // the activity if both info toggles are off and there are no
            // sessions / VPN.
            if sessionFilter == .infoOnly {
                reconcileActivityLifecycle(reason: "Network info disabled")
            }
        }
    }

    // MARK: - Coding Agents

    /// Called by `AgentAttentionCenter` after a publish pass changed the
    /// aggregate. Re-reads the census and, if a bucket moved, schedules one
    /// coalesced lifecycle reconcile. Scans run sub-second on the selected
    /// pane and a permission prompt produces several passes in a row; each
    /// publish is an XPC to liveactivitiesd and counts against the paired
    /// Watch's sync budget, so bursts are folded into one update.
    func agentCountsMayHaveChanged() {
        guard isEnabled, isAgentInfoEnabled else { return }
        guard !Ghostty.isAppBackgroundedAtomic else { return }
        guard refreshAgentCountsCache() else { return }
        scheduleAgentPublish()
    }

    /// Detected coding agents shown under the current filter.
    var displayedAgentCount: Int {
        guard isAgentInfoEnabled, sessionFilter != .vpnOnly else { return 0 }
        return lastAgentWorkingCount + lastAgentAttentionCount + lastAgentIdleCount
    }

    private var shownAgentWorkingCount: Int { isAgentInfoEnabled ? lastAgentWorkingCount : 0 }
    private var shownAgentAttentionCount: Int { isAgentInfoEnabled ? lastAgentAttentionCount : 0 }
    private var shownAgentIdleCount: Int { isAgentInfoEnabled ? lastAgentIdleCount : 0 }

    /// Snapshot the census into the cache. Returns true when a bucket changed.
    @discardableResult
    private func refreshAgentCountsCache() -> Bool {
        let counts = AgentAttentionCenter.shared.codingAgentCounts()
        guard counts.working != lastAgentWorkingCount
            || counts.attention != lastAgentAttentionCount
            || counts.idle != lastAgentIdleCount
        else { return false }
        lastAgentWorkingCount = counts.working
        lastAgentAttentionCount = counts.attention
        lastAgentIdleCount = counts.idle
        return true
    }

    private func clearAgentCountsCache() {
        lastAgentWorkingCount = 0
        lastAgentAttentionCount = 0
        lastAgentIdleCount = 0
    }

    private func scheduleAgentPublish() {
        guard agentPublishTask == nil else { return }
        agentPublishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.agentPublishCoalesceDelay)
            guard let self, !Task.isCancelled else { return }
            self.agentPublishTask = nil
            self.publishAgentCountsNow()
        }
    }

    private func cancelAgentPublish() {
        agentPublishTask?.cancel()
        agentPublishTask = nil
    }

    /// Fire-time half of the debounce. The entry guard in
    /// `agentCountsMayHaveChanged` is not enough: a task scheduled in the
    /// foreground can fire after the background edge, and
    /// `reconcileActivityLifecycle` has no gate of its own.
    private func publishAgentCountsNow() {
        guard isEnabled, isAgentInfoEnabled else { return }
        guard !shouldSkipInfoPollingForLifecycle else {
            // The cache is current; the foreground reconcile republishes it.
            LifecycleDebugLogger.shared.bumpSuppression("liveActivity_agents")
            return
        }
        // A pending start retry publishes the newest cache when it lands;
        // requesting again here would burn retry attempts on count churn.
        if startRetryTask != nil, hasEligibleActivityContent { return }
        reconcileActivityLifecycle(reason: "agent counts changed")
    }

    private func handleAgentToggleChanged() {
        guard isEnabled else { return }
        cancelAgentPublish()
        if isAgentInfoEnabled {
            // Enabling is a meaningful user action, like a filter change:
            // clear dismiss suppression and start-retry, snapshot the census
            // now, and reconcile so an agent-only activity can spin up
            // without waiting for the next status change.
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
            refreshAgentCountsCache()
            reconcileActivityLifecycle(reason: "agent info enabled")
        } else {
            clearAgentCountsCache()
            // Ends an agent-only activity; a mixed one republishes without
            // the agent fields.
            reconcileActivityLifecycle(reason: "agent info disabled")
        }
    }

    // MARK: - Agent Inbox

    /// Unread agent events shown on the island, newest first.
    ///
    /// This array is the source of truth; the content state only carries a
    /// prefix of it because the Lock Screen draws at most five rows. The rows
    /// hold no message text — see `AgentInboxItem`.
    @ObservationIgnored
    private var agentInboxItems: [AgentInboxItem] = []

    /// What we keep in memory. Past the lock-screen rows the extra events only
    /// exist to keep the folded total honest, so the cap can be generous
    /// without touching the island's 4KB budget.
    private static let agentInboxMemoryLimit = 50

    /// Unread total published on the island.
    private var agentInboxUnreadTotal: Int { agentInboxItems.count }

    /// Repopulate the island after its in-memory array was lost: the process
    /// restarted, the activity timed out/dismissed, or an activation reconcile
    /// raced session restore. The persisted inbox is the durable copy; only
    /// events newer than the island's "mark all read" watermark come back.
    private func restoreAgentInboxFromStoreIfNeeded() {
        guard ProtectedDataGuard.isAvailable,
              AgentInboxPlatform.isSupported,
              isEnabled, isAgentInfoEnabled, sessionFilter != .vpnOnly,
              agentInboxItems.isEmpty else { return }
        let readAt = AgentInboxReadMarker.lastReadAt()
        if ProtectedDataGuard.isAvailable {
            AgentInboxStore.shared.sweepExpired()
        }
        let now = Date()
        let events = AgentInboxStore.shared.unreadEvents(limit: Self.agentInboxMemoryLimit)
            .filter { item in
                (readAt.map { item.at > $0 } ?? true)
                    && Self.isIslandStatus(AgentInboxStatus(raw: item.status))
                    && now.timeIntervalSince(item.at) < AgentInboxFeed.activeLifetime
            }
        guard !events.isEmpty else { return }
        agentInboxItems = events
        Self.logger.info("Restored \(events.count) unread agent event(s) from the inbox store")
        startAgentArchiveSweepIfNeeded()
    }

    /// Island rows are only actionable for an hour. A sweep is needed because
    /// an idle event produces no further push to trigger a reconcile.
    private func startAgentArchiveSweepIfNeeded() {
        guard AgentInboxPlatform.isSupported,
              !agentInboxItems.isEmpty,
              agentArchiveSweepTask == nil else { return }
        agentArchiveSweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let changed = self.archiveExpiredAgentEvents()
                if ProtectedDataGuard.isAvailable {
                    AgentInboxStore.shared.sweepExpired()
                }
                if changed {
                    self.reconcileActivityLifecycle(reason: "agent archive sweep")
                }
                if self.agentInboxItems.isEmpty {
                    self.stopAgentArchiveSweep()
                }
            }
        }
    }

    private func stopAgentArchiveSweep() {
        agentArchiveSweepTask?.cancel()
        agentArchiveSweepTask = nil
    }

    /// Moves rows past `AgentInboxFeed.activeLifetime` into the inbox archive
    /// and off the island. Returns true when anything changed.
    @discardableResult
    private func archiveExpiredAgentEvents(now: Date = Date()) -> Bool {
        guard !agentInboxItems.isEmpty else { return false }
        let expired = agentInboxItems.filter {
            now.timeIntervalSince($0.at) >= AgentInboxFeed.activeLifetime
        }
        guard !expired.isEmpty else { return false }
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            for item in expired {
                AgentInboxStore.shared.archive(item.id)
            }
        }
        let ids = Set(expired.map(\.id))
        agentInboxItems.removeAll { ids.contains($0.id) }
        Self.logger.info("Archived \(expired.count) stale agent event(s)")
        return true
    }

    /// Unread events by the two statuses that ask for an action. The island
    /// header shows these separately; a single "needs attention" number made a
    /// blocked prompt and a failed run indistinguishable.
    private var agentInboxBlockedCount: Int {
        agentInboxItems.reduce(0) { $0 + (AgentInboxStatus(raw: $1.status) == .blocked ? 1 : 0) }
    }

    private var agentInboxFailedCount: Int {
        agentInboxItems.reduce(0) { $0 + (AgentInboxStatus(raw: $1.status) == .failed ? 1 : 0) }
    }

    private var agentInboxDoneCount: Int {
        agentInboxItems.reduce(0) { $0 + (AgentInboxStatus(raw: $1.status) == .done ? 1 : 0) }
    }

    /// Unread events shown under the current filter. Mirrors
    /// `displayedAgentCount`: the VPN Only filter hides agent content entirely,
    /// and the agent toggle gates the whole feature.
    var displayedAgentInboxCount: Int {
        guard isAgentInfoEnabled, sessionFilter != .vpnOnly else { return 0 }
        return agentInboxUnreadTotal
    }

    /// Rows plus folded total for the current filter.
    private var displayedAgentInbox: (items: [AgentInboxItem], total: Int) {
        guard displayedAgentInboxCount > 0 else { return ([], 0) }
        return (Array(agentInboxItems.prefix(SessionActivityAttributes.ContentState.lockScreenAgentItemLimit)),
                agentInboxUnreadTotal)
    }

    /// Records one delivered agent event and refreshes the island.
    ///
    /// Called from `PushNotificationRouter` at the point a push is actually
    /// surfaced — an event the user is already looking at never reaches here.
    /// The island carries only "which agent, what status, when" (privacy option
    /// A); the app's inbox keeps the message text and the host/tab it came from,
    /// because that screen is only readable after the device is unlocked.
    func noteAgentEvent(id: String, agent: String, status: String, at date: Date = Date(), deepLink: URL,
                        summary: String? = nil, host: String? = nil, tab: String? = nil,
                        windowId: String? = nil, tabID: UUID? = nil,
                        isRestore: Bool = false) {
        guard isEnabled, isAgentInfoEnabled, sessionFilter != .vpnOnly else { return }
        consumeInboxReadMarker()
        // Anything at or before the last "mark all read" was already answered:
        // a ledger replay or a late duplicate must not bring it back.
        if let readAt = AgentInboxReadMarker.lastReadAt(), date <= readAt { return }
        // The inbox persists read/archived state. A Notification Center row
        // that was opened or archived on a previous launch must not come back
        // to the island just because the notification is still delivered.
        if ProtectedDataGuard.isAvailable,
           let existing = AgentInboxStore.shared.row(id: id),
           existing.isRead || existing.isArchived {
            return
        }

        let item = AgentInboxItem(id: id, agent: agent, status: status, at: date, deepLink: deepLink)
        let islandStatus = AgentInboxStatus(raw: status)
        let belongsOnIsland = Self.isIslandStatus(islandStatus)
        // The inbox keeps every message; the island only answers the three
        // states a glance can act on. A working row is history, not a badge.
        let isStale = Date().timeIntervalSince(date) >= AgentInboxFeed.activeLifetime
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            AgentInboxStore.shared.record(event: item, summary: summary, host: host, tab: tab,
                                          windowId: windowId, tabID: tabID)
        }
        guard belongsOnIsland, !isStale else { return }

        // A redelivered push must not add a second row or, worse, jump back to
        // the top of the list.
        guard !agentInboxItems.contains(where: { $0.id == id }) else { return }
        agentInboxItems.insert(item, at: 0)
        if agentInboxItems.count > Self.agentInboxMemoryLimit {
            agentInboxItems.removeLast(agentInboxItems.count - Self.agentInboxMemoryLimit)
        }

        // A hook that needs an answer is exactly the event a previously
        // dismissed island should come back for. A restore from Notification
        // Center is not a new event, so it must not override a swipe-dismiss.
        if !isRestore {
            userDismissed = false
            cancelStartRetry(resetAttempts: true)
        }
        reconcileActivityLifecycle(reason: isRestore ? "restored agent event" : "agent event")
        startAgentArchiveSweepIfNeeded()
    }

    /// Statuses the island draws. Working/unknown rows stay in the inbox only.
    static func isIslandStatus(_ status: AgentInboxStatus) -> Bool {
        switch status {
        case .blocked, .done, .failed: return true
        case .other: return false
        }
    }

    /// Drops one event by id. No-op when it is not in the inbox.
    func markAgentRead(itemID: String) {
        guard agentInboxItems.contains(where: { $0.id == itemID }) else { return }
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            AgentInboxStore.shared.markRead(id: itemID)
        }
        agentInboxItems.removeAll { $0.id == itemID }
        endIfEmpty()
    }

    /// Drops every event that points at one pane — the same path
    /// `PushNotificationRouter.paneViewed` already uses for notification
    /// withdrawal, so looking at a pane answers both surfaces at once.
    func markAgentRead(surfaceID: UUID) {
        let matching = agentInboxItems.filter { item in
            guard let id = UUID(uuidString: item.deepLink.lastPathComponent) else { return false }
            return id == surfaceID
        }
        guard !matching.isEmpty else { return }
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            for item in matching {
                AgentInboxStore.shared.markRead(id: item.id)
            }
        }
        agentInboxItems.removeAll { item in matching.contains { $0.id == item.id } }
        endIfEmpty()
    }

    /// Clears the whole inbox. The island is only ended when nothing else —
    /// sessions, VPN, WiFi/network info — still has a claim on it; sessions
    /// must survive a "mark all read".
    func markAllAgentRead() {
        guard !agentInboxItems.isEmpty else { return }
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            AgentInboxStore.shared.markAllRead()
        }
        agentInboxItems.removeAll()
        stopAgentArchiveSweep()
        AgentInboxReadMarker.markRead()
        reconcileActivityLifecycle(reason: "agent inbox marked read")
    }

    /// Re-reads eligibility and ends the island only if nothing else — a
    /// session, VPN, WiFi/network info — still wants it. An empty inbox alone
    /// must never leave a "0 unread" island behind.
    func endIfEmpty() {
        guard isEnabled else { return }
        if agentInboxItems.isEmpty { stopAgentArchiveSweep() }
        reconcileActivityLifecycle(reason: "agent inbox changed")
    }

    /// Lets the inbox screen apply the same one-hour rule to the island as
    /// soon as its own sweep archives a row.
    func sweepAgentArchiveNow() {
        if archiveExpiredAgentEvents() {
            reconcileActivityLifecycle(reason: "agent archive sweep")
        }
    }

    /// Rebuilds the island's rows from the inbox store. Used after an inbox row
    /// is archived: the island and the section counts must both derive from the
    /// same unread set, not from an in-memory array that may have drifted.
    func syncAgentInboxFromStore() {
        guard AgentInboxPlatform.isSupported,
              ProtectedDataGuard.isAvailable,
              isEnabled, isAgentInfoEnabled, sessionFilter != .vpnOnly else { return }
        AgentInboxStore.shared.sweepExpired()
        let now = Date()
        let events = AgentInboxStore.shared.unreadEvents(limit: Self.agentInboxMemoryLimit)
            .filter {
                Self.isIslandStatus(AgentInboxStatus(raw: $0.status))
                    && now.timeIntervalSince($0.at) < AgentInboxFeed.activeLifetime
            }
        agentInboxItems = events
        if events.isEmpty {
            stopAgentArchiveSweep()
        } else {
            startAgentArchiveSweepIfNeeded()
        }
        reconcileActivityLifecycle(reason: "inbox store sync")
    }

    /// Applies a "mark all read" performed on the island by the widget intent,
    /// which can only leave a timestamp in the app group: the intent runs in
    /// the widget extension and cannot see this array.
    ///
    /// The timestamp stays behind as a watermark — `noteAgentEvent` refuses
    /// anything at or before it — so clearing the island once cannot be undone
    /// by a replayed delivery record.
    private func consumeInboxReadMarker() {
        guard let readAt = AgentInboxReadMarker.lastReadAt(), !agentInboxItems.isEmpty else { return }
        let removed = agentInboxItems.filter { $0.at <= readAt }
        guard !removed.isEmpty else { return }
        if AgentInboxPlatform.isSupported, ProtectedDataGuard.isAvailable {
            for item in removed {
                AgentInboxStore.shared.markRead(id: item.id)
            }
        }
        agentInboxItems.removeAll { $0.at <= readAt }
        Self.logger.info("Agent inbox: \(removed.count) event(s) cleared by island intent")
    }

    /// Seed the in-memory inbox from an activity this process just adopted.
    /// The activity's state is the only record of what the island is already
    /// showing; without this the first republish would silently empty it.
    private func adoptAgentInbox(from state: SessionActivityAttributes.ContentState) {
        guard agentInboxItems.isEmpty, !state.agentItems.isEmpty else { return }
        let now = Date()
        agentInboxItems = state.agentItems.filter {
            Self.isIslandStatus(AgentInboxStatus(raw: $0.status))
                && now.timeIntervalSince($0.at) < AgentInboxFeed.activeLifetime
        }
        // The activity's rows are the only record left when the app was not
        // running when the push arrived. They carry no text or host, but the
        // pane link still resolves, so the in-app inbox keeps them — on the
        // devices that have an inbox.
        guard ProtectedDataGuard.isAvailable, AgentInboxPlatform.isSupported else { return }
        for item in state.agentItems {
            AgentInboxStore.shared.record(event: item, summary: nil, host: nil, tab: nil)
        }
        startAgentArchiveSweepIfNeeded()
    }

    // MARK: - Filter Logic

    /// Computed filtered session count based on current filter
    private var filteredSessionCount: Int {
        switch sessionFilter {
        case .vpnOnly:
            return 0
        case .diary:
            return lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount
        case .all, .infoOnly:
            return lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount + lastRoamCount
        }
    }

    /// Build a ContentState based on the current filter
    private func filteredContentState(at date: Date) -> SessionActivityAttributes.ContentState {
        // Read once: the island and the Lock Screen draw the same prefix, and
        // the folded total has to agree with the rows it labels.
        let inbox = displayedAgentInbox
        switch sessionFilter {
        case .vpnOnly:
            return SessionActivityAttributes.ContentState(
                sessionCount: 0,
                sshCount: 0,
                k8sCount: 0,
                consoleCount: 0,
                hostNames: [],
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                appIconVariant: Self.currentIconVariant,
                agentItems: inbox.items,
                agentUnreadTotal: inbox.total,
                agentInboxBlockedCount: agentInboxBlockedCount,
                agentInboxFailedCount: agentInboxFailedCount,
                agentInboxDoneCount: agentInboxDoneCount
            )

        case .diary:
            let totalCount = lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount
            return SessionActivityAttributes.ContentState(
                sessionCount: totalCount,
                sshCount: lastSSHCount,
                k8sCount: lastK8sCount,
                consoleCount: lastConsoleCount,
                hostNames: lastHostNames,
                localTaskCount: lastLocalTaskCount,
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                agentWorkingCount: shownAgentWorkingCount,
                agentAttentionCount: shownAgentAttentionCount,
                agentIdleCount: shownAgentIdleCount,
                appIconVariant: Self.currentIconVariant,
                agentItems: inbox.items,
                agentUnreadTotal: inbox.total,
                agentInboxBlockedCount: agentInboxBlockedCount,
                agentInboxFailedCount: agentInboxFailedCount,
                agentInboxDoneCount: agentInboxDoneCount
            )

        case .all, .infoOnly:
            let totalCount = lastSSHCount + lastK8sCount + lastConsoleCount + lastLocalTaskCount + lastRoamCount
            var mergedHostNames = lastHostNames
            for host in lastRoamHostNames where !mergedHostNames.contains(host) {
                mergedHostNames.append(host)
            }
            return SessionActivityAttributes.ContentState(
                sessionCount: totalCount,
                sshCount: lastSSHCount,
                k8sCount: lastK8sCount,
                consoleCount: lastConsoleCount,
                hostNames: Array(mergedHostNames.prefix(3)),
                localTaskCount: lastLocalTaskCount,
                roamCount: lastRoamCount,
                roamHostNames: lastRoamHostNames,
                lastUpdated: date,
                vpnProfileName: lastVPNProfileName,
                vpnHost: lastVPNHost,
                vpnBytesIn: lastVPNBytesIn,
                vpnBytesOut: lastVPNBytesOut,
                vpnActiveConnections: lastVPNActiveConnections,
                vpnConnectedSince: lastVPNConnectedSince,
                vpnStatus: lastVPNStatus,
                wifiSSID: isWiFiInfoEnabled ? lastWiFiSSID : nil,
                wifiAPName: isWiFiInfoEnabled ? lastWiFiAPName : nil,
                wifiAPDetail: isWiFiInfoEnabled ? lastWiFiAPDetail : nil,
                wifiBand: isWiFiInfoEnabled ? lastWiFiBand : nil,
                networkPublicIP: isNetworkInfoEnabled ? lastNetworkPublicIP : nil,
                networkASName: isNetworkInfoEnabled ? lastNetworkASName : nil,
                networkCountryFlag: isNetworkInfoEnabled ? lastNetworkCountryFlag : nil,
                networkType: isNetworkInfoEnabled ? lastNetworkType : nil,
                agentWorkingCount: shownAgentWorkingCount,
                agentAttentionCount: shownAgentAttentionCount,
                agentIdleCount: shownAgentIdleCount,
                appIconVariant: Self.currentIconVariant,
                agentItems: inbox.items,
                agentUnreadTotal: inbox.total,
                agentInboxBlockedCount: agentInboxBlockedCount,
                agentInboxFailedCount: agentInboxFailedCount,
                agentInboxDoneCount: agentInboxDoneCount
            )
        }
    }

    /// Called by `AppIconManager` when the user picks a new icon. Rebuilds the
    /// current state so the widget re-renders with the matching display image.
    func refreshIconVariant() {
        guard currentActivity != nil else { return }
        updateActivity()
    }

    /// Re-evaluate activity state after filter changes
    private func handleFilterChanged() {
        guard isEnabled else { return }
        // Filter change is a meaningful user action — clear dismiss suppression
        // so swipe-dismissed activities can come back when the user picks a
        // mode that should be running (e.g. switching into .infoOnly).
        userDismissed = false
        cancelStartRetry(resetAttempts: true)
        reconcileActivityLifecycle(reason: "filter changed")
    }

    private var hasEligibleActivityContent: Bool {
        guard isEnabled else { return false }
        if filteredSessionCount > 0 || hasActiveVPN { return true }
        // Coding agents keep the activity alive on their own (a tssh-only
        // user has no diary sessions to do it), except in VPN Only mode.
        if displayedAgentCount > 0 { return true }
        // An unread agent event is its own reason to be on the island: a hook
        // that needs an answer must be reachable without the app running.
        if displayedAgentInboxCount > 0 { return true }
        // Info Only: keep activity alive on WiFi/Network info alone.
        // Require at least one info source enabled to avoid an empty widget.
        if sessionFilter == .infoOnly && (isWiFiInfoEnabled || isNetworkInfoEnabled) {
            return true
        }
        return false
    }

    /// Icon the island draws. `-AgentInboxDemoIcon <Variant>` pins it in debug
    /// builds so the switcher can be exercised without tapping the system
    /// icon-change alert; shipping builds always follow the real selection.
    static var currentIconVariant: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-AgentInboxDemoIcon"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        #endif
        return AppIconManager.shared.selectedVariant.rawValue
    }

    #if DEBUG
    /// Design-review hook: puts the island into the agent-inbox state without
    /// depending on settings or a real hook push. Debug builds only.
    func debugSeedAgentInbox(_ items: [AgentInboxItem]) {
        isEnabled = true
        isAgentInfoEnabled = true
        let now = Date()
        agentInboxItems = items.filter {
            Self.isIslandStatus(AgentInboxStatus(raw: $0.status))
                && now.timeIntervalSince($0.at) < AgentInboxFeed.activeLifetime
        }
        userDismissed = false
        cancelStartRetry(resetAttempts: true)
        reconcileActivityLifecycle(reason: "debug seed")
        startAgentArchiveSweepIfNeeded()
    }
    #endif

    private func reconcileActivityLifecycle(reason: String) {
        dropInactiveCurrentActivityIfNeeded()
        // Apply the island intent's watermark before anything reads the array;
        // otherwise a WiFi/session publish can put rows the user just cleared
        // back on the island. This also runs before the restore below.
        consumeInboxReadMarker()
        _ = archiveExpiredAgentEvents()
        // Do this before eligibility: a lost in-memory array must not make an
        // activity with durable unread events look ineligible and end it.
        restoreAgentInboxFromStoreIfNeeded()
        #if DEBUG
        Self.logger.info("reconcile(\(reason, privacy: .public)) enabled=\(self.isEnabled) agentInfo=\(self.isAgentInfoEnabled) items=\(self.agentInboxItems.count) eligible=\(self.hasEligibleActivityContent) current=\(self.currentActivity != nil)")
        #endif

        guard hasEligibleActivityContent else {
            cancelStartRetry(resetAttempts: true)
            endActivity()
            return
        }

        if currentActivity == nil {
            adoptExistingActivityIfAvailable()
        }

        if currentActivity == nil {
            startActivity(reason: reason)
        } else {
            cancelStartRetry(resetAttempts: true)
            updateActivity()
        }
    }

    private func adoptExistingActivityIfAvailable() {
        let activities = Activity<SessionActivityAttributes>.activities
        guard let primary = activities.first(where: { Self.isAdoptableActivityState($0.activityState) }) else {
            for activity in activities {
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }

        Self.logger.info("Adopting existing Live Activity \(primary.id) during lifecycle reconciliation")
        currentActivity = primary
        lastPublishedState = primary.content.state
        adoptAgentInbox(from: primary.content.state)
        isActivityActive = true
        observeActivityState()
        startInfoPollingDeferred()

        for extra in activities where extra.id != primary.id {
            Task {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func isAdoptableActivityState(_ state: ActivityState) -> Bool {
        switch state {
        case .pending, .active, .stale:
            return true
        case .ended, .dismissed:
            return false
        @unknown default:
            return false
        }
    }

    private func dropInactiveCurrentActivityIfNeeded() {
        guard let activity = currentActivity,
              !Self.isAdoptableActivityState(activity.activityState) else {
            return
        }

        let stateDescription = String(describing: activity.activityState)
        Self.logger.info("Dropping inactive Live Activity \(activity.id), state: \(stateDescription)")
        stateObserverTask?.cancel()
        stateObserverTask = nil
        currentActivity = nil
        activityStartDate = nil
        isActivityActive = false
        lastPublishedState = nil
    }

    // MARK: - Activity Lifecycle

    private func startActivity(reason: String = "state changed") {
        guard !userDismissed else {
            Self.logger.debug("Live Activity suppressed (user dismissed)")
            return
        }

        guard hasEligibleActivityContent else {
            cancelStartRetry(resetAttempts: true)
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            Self.logger.warning("Live Activities not authorized by user")
            cancelStartRetry(resetAttempts: true)
            return
        }

        // Belt-and-suspenders: end any activities we don't own. This catches
        // edge cases where init cleanup hasn't completed or an async end is
        // still in flight.
        let existingActivities = Activity<SessionActivityAttributes>.activities
        for existing in existingActivities {
            let existingId = existing.id
            if existingId != currentActivity?.id && existingId != endingActivityId {
                Self.logger.info("Ending untracked Live Activity \(existingId) before starting new one")
                Task {
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
            }
        }

        // Preserve start date across system timeout restarts
        let startDate = activityStartDate ?? Date()
        activityStartDate = startDate

        let state = filteredContentState(at: startDate)
        let attributes = SessionActivityAttributes()
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastPublishedState = state
            isActivityActive = true
            pendingPublish = nil
            let count = filteredSessionCount
            cancelStartRetry(resetAttempts: true)
            Self.logger.info("Live Activity started with \(count) session(s), reason: \(reason)")
            observeActivityState()

            startInfoPollingDeferred()
        } catch {
            let errorDesc = error.localizedDescription
            Self.logger.error("Failed to start Live Activity: \(errorDesc)")
            scheduleStartRetry(reason: reason)
        }
    }

    private func updateActivity() {
        guard let activity = currentActivity else { return }

        let state = filteredContentState(at: activityStartDate ?? Date())
        publish(state, to: activity, reason: "update")
    }

    /// Hands the newest content state to ActivityKit. The state replaces any
    /// older state that has not started sending yet, so a burst of updates
    /// cannot make the island replay counts that are already obsolete.
    private func publish(
        _ state: SessionActivityAttributes.ContentState,
        to activity: Activity<SessionActivityAttributes>,
        reason: String
    ) {
        lastPublishedState = state
        pendingPublish = PendingPublish(state: state, activity: activity, reason: reason)
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            while let next = self?.pendingPublish {
                self?.pendingPublish = nil
                let content = ActivityContent(state: next.state, staleDate: nil)
                await next.activity.update(content, alertConfiguration: nil, timestamp: Date())
                Self.logger.info(
                    "Live Activity updated (\(next.reason, privacy: .public)): \(next.state.sessionCount) session(s), blocked=\(next.state.agentInboxBlockedUnreadCount) done=\(next.state.agentInboxDoneUnreadCount) failed=\(next.state.agentInboxFailedUnreadCount)")
            }
            self?.publishTask = nil
        }
    }

    /// Called on the background edge, after the grace task is registered.
    /// Agent detection stops the moment the app leaves the foreground, so the
    /// counts on the widget become a snapshot: republish the last content
    /// with `agentCountsFrozen` set so the widget can say so. Cached state
    /// only: no `Activity.activities` lookup and no state rebuild, both of
    /// which can stall inside the scene transaction (see the deferral notes
    /// in `MainView+Lifecycle`). The foreground reconcile clears the flag.
    func handleAppBackgrounded() {
        cancelAgentPublish()
        // A retry has no activity to freeze yet. Let foreground activation
        // re-drive the request instead of creating an unfrozen activity after
        // the one background-edge callback has already passed.
        cancelStartRetry(resetAttempts: true)
        guard let activity = currentActivity,
              var state = lastPublishedState,
              state.agentTotalCount > 0,
              !state.agentCountsFrozen
        else { return }
        state.agentCountsFrozen = true
        publish(state, to: activity, reason: "background edge")
    }

    private func endActivity() {
        cancelStartRetry(resetAttempts: true)

        guard let activity = currentActivity else { return }

        stateObserverTask?.cancel()
        stateObserverTask = nil

        // Nil out currentActivity FIRST to prevent reentrancy:
        // stop() → clearNetworkInfo() → updateActivity() would see non-nil
        // currentActivity and try to update during teardown.
        currentActivity = nil
        activityStartDate = nil
        isActivityActive = false
        cancelAgentPublish()
        stopAgentArchiveSweep()
        pendingPublish = nil
        lastPublishedState = nil
        // Nothing eligible is left, so the rows describing those events are
        // stale: they must not resurrect the next time an island starts.
        agentInboxItems.removeAll()

        // Stop WiFi polling and network bridge, clean up shared favicons
        stopWiFiPolling()
        NetworkInfoLiveActivityBridge.shared.stop()
        LiveActivityFaviconStore.removeAll()

        let finalState = SessionActivityAttributes.ContentState(
            sessionCount: 0,
            sshCount: 0,
            k8sCount: 0,
            consoleCount: 0,
            hostNames: [],
            lastUpdated: Date(),
            vpnProfileName: nil,
            vpnHost: nil,
            vpnBytesIn: nil,
            vpnBytesOut: nil,
            vpnActiveConnections: nil,
            vpnConnectedSince: nil,
            vpnStatus: nil,
            wifiSSID: nil,
            wifiAPName: nil,
            wifiAPDetail: nil,
            wifiBand: nil,
            networkPublicIP: nil,
            networkASName: nil,
            networkCountryFlag: nil,
            networkType: nil
        )
        let content = ActivityContent(state: finalState, staleDate: nil)

        // Track the activity being ended so startActivity() doesn't
        // redundantly try to end it again while the async end is in flight.
        let activityId = activity.id
        endingActivityId = activityId

        Task {
            await activity.end(content, dismissalPolicy: .immediate)
            Self.logger.info("Live Activity ended")
            self.endingActivityId = nil
        }
    }

    // MARK: - State Observation

    /// Observe activity state to handle system-imposed 8-hour timeout and user dismiss
    private func observeActivityState() {
        stateObserverTask?.cancel()

        guard let activity = currentActivity else { return }

        stateObserverTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }

                if state == .dismissed {
                    // User swiped to dismiss — suppress restart until meaningful change
                    Self.logger.info("Live Activity dismissed by user")
                    await MainActor.run {
                        guard let self else { return }
                        self.currentActivity = nil
                        self.activityStartDate = nil
                        self.isActivityActive = false
                        self.stateObserverTask = nil
                        self.userDismissed = true
                        self.cancelAgentPublish()
                        self.lastPublishedState = nil

                        // Tear down WiFi/network machinery started alongside the activity
                        self.stopWiFiPolling()
                        NetworkInfoLiveActivityBridge.shared.stop()
                        LiveActivityFaviconStore.removeAll()
                    }
                    return
                }

                if state == .ended {
                    // System 8-hour timeout — auto-restart (preserving start date)
                    Self.logger.info("Live Activity ended by system timeout")
                    await MainActor.run {
                        guard let self else { return }
                        self.currentActivity = nil
                        self.isActivityActive = false
                        self.stateObserverTask = nil

                        if self.hasEligibleActivityContent {
                            Self.logger.info("Auto-restarting Live Activity (eligible content still present)")
                            self.startActivity(reason: "system timeout")
                        }
                    }
                    return
                }
            }
        }
    }

    private func scheduleStartRetry(reason: String) {
        guard startRetryAttempt < Self.maxStartRetryAttempts else {
            Self.logger.error("Live Activity start retry limit reached")
            return
        }

        startRetryAttempt += 1
        let attempt = startRetryAttempt
        let delay = Self.startRetryDelay
        startRetryTask?.cancel()

        startRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.startRetryTask = nil

                // Cancellation can race with this MainActor hop. Re-check the
                // lifecycle at fire time so a retry can never start from the
                // background; activation will reconcile cached state again.
                guard !self.shouldSkipInfoPollingForLifecycle else {
                    LifecycleDebugLogger.shared.bumpSuppression("liveActivity_startRetry")
                    return
                }

                guard self.currentActivity == nil,
                      self.hasEligibleActivityContent,
                      !self.userDismissed else {
                    self.cancelStartRetry(resetAttempts: true)
                    return
                }

                Self.logger.info("Retrying Live Activity start attempt \(attempt), reason: \(reason)")
                self.startActivity(reason: "retry after \(reason)")
            }
        }
    }

    private func cancelStartRetry(resetAttempts: Bool = false) {
        startRetryTask?.cancel()
        startRetryTask = nil
        if resetAttempts {
            startRetryAttempt = 0
        }
    }
}
#endif
