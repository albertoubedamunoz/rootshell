//
//  MoshStateSync.swift
//  rootshell
//

import Foundation
import OSLog

/// Coordinates the mosh State Synchronization Protocol
///
/// Manages:
/// - Bidirectional state streams
/// - Transport layer communication
/// - Local terminal state + prediction overlays
@MainActor
final class MoshStateSync {

    // MARK: - Types

    /// Delegate for state sync events
    protocol Delegate: AnyObject, Sendable {
        /// Called when terminal output is received
        @MainActor func stateSync(_ sync: MoshStateSync, didReceiveOutput data: Data)

        /// Called when terminal resize is received from server
        @MainActor func stateSync(_ sync: MoshStateSync, didReceiveResize width: UInt32, height: UInt32)

        /// Called when connection state changes
        @MainActor func stateSync(_ sync: MoshStateSync, didChangeState state: MoshSessionState)

        /// Called when an error occurs
        @MainActor func stateSync(_ sync: MoshStateSync, didEncounterError error: MoshError)

        /// Called when connection times out and hole-punch should be attempted
        /// Return true if hole-punch will be attempted (prevents shutdown)
        @MainActor func stateSyncNeedsHolePunch(_ sync: MoshStateSync) -> Bool

        /// Called when an actual network packet is received from the server
        /// This is distinct from didReceiveOutput which fires for local terminal output too
        @MainActor func stateSyncDidReceiveServerPacket(_ sync: MoshStateSync)

        /// Called periodically from the send loop to update banner state
        /// This allows the UI to update timers even when no packets are being received
        @MainActor func stateSyncDidUpdateBannerState(_ sync: MoshStateSync, state: MoshRoamBannerState?)
    }

    // MARK: - Properties

    /// The delegate for state sync events
    weak var delegate: Delegate?

    /// The transport layer
    private let transport: MoshTransport

    /// Outbound synchronizer (client → server)
    private var sender: OutboundSynchronizer<MoshInputEventStream>

    /// Inbound assembler (server → client)
    private var receiver: InboundAssembler<MoshRenderedTerminal>

    /// Overlays (prediction + notifications)
    private let overlays = MoshOverlayManager()

    /// Display helper for local output diffs
    private let display = VTDisplayRenderer(useEnvironment: false)

    /// Local framebuffer representing what we've drawn
    private var localFramebuffer: VTFramebuffer

    /// Last remote size we reported
    private var lastRemoteSize: (width: Int, height: Int)

    /// Whether the sync is running
    private(set) var isRunning: Bool = false

    /// Whether the sync is paused (for state saving)
    /// When paused, incoming packets are queued but not processed,
    /// and the send loop is suspended.
    private(set) var isPaused: Bool = false

    /// Whether the sync is throttled (for unfocused tabs)
    /// When throttled:
    /// - Tick frequency reduced from 250ms to 5s
    /// - Frame rendering skipped
    /// - Prediction overlays disabled
    /// - Packets still processed (maintains connection)
    private(set) var isThrottled: Bool = false

    /// Current RTT in milliseconds
    var latencyMs: Int? {
        transport.rttEstimator.latencyMs
    }

    /// Task for next scheduled tick (timer-based, replaces polling loop)
    private var nextTickTask: Task<Void, Never>?

    /// Scheduled time for next tick in ms (for coalescing - only reschedule if earlier)
    private var nextTickTime: UInt64 = UInt64.max

    /// Transport delegate wrapper (must be stored to keep strong reference)
    private var transportDelegateWrapper: TransportDelegateWrapper?

    /// Whether a full repaint is requested
    private var repaintRequested = true

    /// Whether we're stabilizing after resume (suppresses send loop repaints until data arrives)
    private var isResumeStabilizing = false

    /// Whether we received a shutdown request from the server
    private var remoteShutdownRequested = false

    /// Last banner state sent to delegate (for change detection)
    private var lastBannerState: MoshRoamBannerState?

    /// Whether frame needs re-rendering (new data arrived or overlays changed)
    private var frameDirty = true

    /// Whether a tick is already pending (for coalescing multiple trigger requests)
    private var tickPending = false

    /// Connecting notification message
    private var connectingNotification: String

    /// Logger
    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "MoshStateSync"
    )

    // MARK: - Initialization

    /// Resume state for state sync layer
    struct ResumeState: Sendable {
        let sentStateNum: UInt64
        let assumedReceiverStateNum: UInt64
        let lastReceivedStateNum: UInt64
    }

    /// Creates a state sync coordinator with the given transport
    init(transport: MoshTransport) {
        self.transport = transport

        let initialWidth = 80
        let initialHeight = 24

        let local = MoshInputEventStream()
        let remote = MoshRenderedTerminal(width: initialWidth, height: initialHeight)
        self.sender = OutboundSynchronizer(transport: transport, initialState: local)
        self.receiver = InboundAssembler(initialRemote: remote)
        self.localFramebuffer = VTFramebuffer(width: initialWidth, height: initialHeight)
        self.lastRemoteSize = (width: initialWidth, height: initialHeight)
        self.connectingNotification = "No packets from server on UDP port \(transport.port)."

        // Match reference client defaults
        sender.setMinimumTransmitGap(ProtocolTiming.defaultMinimumTransmitGapMs)

        // Set up transport delegate synchronously to avoid race conditions
        setupTransportDelegate()
    }

    /// Creates a state sync coordinator with resume state
    /// - Parameters:
    ///   - transport: The transport layer
    ///   - resumeState: Saved state numbers for resume
    init(transport: MoshTransport, resumeState: ResumeState) {
        self.transport = transport

        let initialWidth = 80
        let initialHeight = 24

        let local = MoshInputEventStream()
        let remote = MoshRenderedTerminal(width: initialWidth, height: initialHeight)
        // Initialize with saved state numbers
        self.sender = OutboundSynchronizer(transport: transport, initialState: local, startingStateNum: resumeState.sentStateNum)
        self.receiver = InboundAssembler(initialRemote: remote, startingStateNum: resumeState.lastReceivedStateNum)
        self.localFramebuffer = VTFramebuffer(width: initialWidth, height: initialHeight)
        self.lastRemoteSize = (width: initialWidth, height: initialHeight)
        self.connectingNotification = "Reconnecting to roam server on UDP port \(transport.port)..."

        // CRITICAL: Set the ackNum to what we last received from server
        // Without this, our first packet would have ackNum=0, confusing the server
        sender.updatePeerStateVersion(resumeState.lastReceivedStateNum)

        // Match reference client defaults
        sender.setMinimumTransmitGap(ProtocolTiming.defaultMinimumTransmitGapMs)

        // On resume, suppress send loop repaints until we receive actual server data.
        // Our local state is empty, so premature repaints would draw garbage.
        isResumeStabilizing = true

        Self.logger.info("StateSync resuming with sentStateNum=\(resumeState.sentStateNum), lastReceivedStateNum=\(resumeState.lastReceivedStateNum)")

        // Set up transport delegate synchronously to avoid race conditions
        setupTransportDelegate()
    }

    // MARK: - State Access (for resume persistence)

    /// Returns the current state for saving (for session resume)
    func getCurrentState() -> ResumeState {
        ResumeState(
            sentStateNum: sender.currentStateNum,
            assumedReceiverStateNum: sender.assumedReceiverStateNum,
            lastReceivedStateNum: receiver.latestRemoteVersion
        )
    }

    /// Returns true when the roam banner should be visible
    func isNetworkBannerVisible() -> Bool {
        overlays.getNotificationEngine().isBannerVisible()
    }

    /// Returns the current banner state for SwiftUI overlay, or nil if banner should not be visible
    func getCurrentBannerState() -> MoshRoamBannerState? {
        overlays.getNotificationEngine().getCurrentBannerState()
    }

    // MARK: - Lifecycle

    /// Starts the state synchronization
    func start() async {
        guard !isRunning else { return }

        isRunning = true
        remoteShutdownRequested = false
        repaintRequested = true

        // Initialize the local terminal state
        emitOutput(display.open())
        emitOutput(display.renderDelta(initialized: false, last: localFramebuffer, f: localFramebuffer))

        startTickScheduler()

        Self.logger.info("State sync started")
    }

    /// Stops the state synchronization
    func stop() {
        isRunning = false
        isPaused = false

        nextTickTask?.cancel()
        nextTickTask = nil
        nextTickTime = UInt64.max

        emitOutput(display.close())

        Self.logger.info("State sync stopped")
    }

    // MARK: - Pause/Resume (for state saving)

    /// Pauses the state synchronization
    ///
    /// When paused:
    /// - The send loop stops sending new packets
    /// - Incoming packets are dropped (not processed)
    /// - State numbers are frozen for consistent saving
    ///
    /// Call this BEFORE capturing state for persistence.
    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        // Cancel pending tick - resume() will restart scheduling
        nextTickTask?.cancel()
        nextTickTask = nil
        nextTickTime = UInt64.max
        Self.logger.info("State sync paused for state capture")
    }

    /// Resumes the state synchronization after a pause
    ///
    /// Call this AFTER saving state to resume normal operation.
    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false

        // Reset punch timing to give server a grace period to respond
        // naturally before triggering hole-punches. The latestRemoteTimestamp is
        // stale (from before backgrounding), so without this reset we'd immediately
        // trigger a punch on resume.
        lastPunchTime = ProtocolTiming.monotonicNowMs()
        holePunchInFlight = false
        overlays.getNotificationEngine().setHolePunchInProgress(false)

        Self.logger.info("State sync resumed (punch timing reset)")

        // If the tab became visible while paused, the unthrottle was deferred to here (the
        // foreground occlusion flip can beat this resume()). Apply it now that isPaused is
        // false so the visible tab repaints incoming packets instead of staying frozen.
        if let mode = pendingUnthrottlePredictionMode {
            pendingUnthrottlePredictionMode = nil
            unthrottle(predictionMode: mode)
        }

        // Wake the sender to resume operation
        triggerTick()
    }

    // MARK: - Throttle/Unthrottle (for tab visibility)

    /// Set when `unthrottle` is called while still paused. On foreground the occlusion flip
    /// (`setTabVisible(true)` → `unthrottle`) and `resume()` (which clears `isPaused`) are
    /// deferred independently; if the unthrottle lands first its `!isPaused` guard would drop
    /// it and leave `isThrottled` stuck true — suppressing repaints so the visible tab stays
    /// frozen with live data until the next manual visibility toggle. `resume()` replays this.
    private var pendingUnthrottlePredictionMode: MoshConfig.PredictionMode?

    /// Throttles the state synchronization for unfocused tabs
    ///
    /// When throttled:
    /// - Tick frequency reduced from 250ms to 5s (95% CPU reduction)
    /// - Frame rendering skipped (no outputNewFrame calls)
    /// - Prediction overlays disabled
    /// - Packets still processed to maintain connection
    ///
    /// This is distinct from pause() which completely stops processing.
    /// Throttled sessions stay connected and responsive to incoming data.
    func throttle() {
        // Tab went unfocused — cancel any unthrottle that was deferred to resume().
        pendingUnthrottlePredictionMode = nil
        guard isRunning, !isPaused, !isThrottled else { return }
        isThrottled = true

        // Disable prediction engine to reduce CPU
        overlays.getPredictionEngine().setDisplayPreference(.never)

        Self.logger.debug("State sync throttled (tab unfocused)")

        // Reschedule tick with longer interval
        scheduleNextTick()
    }

    /// Unthrottles the state synchronization when tab becomes visible
    ///
    /// Restores normal operation:
    /// - Normal 250ms tick frequency
    /// - Frame rendering enabled
    /// - Prediction mode restored to configured value
    /// - Requests full repaint to show current state
    func unthrottle(predictionMode: MoshConfig.PredictionMode) {
        guard isRunning, isThrottled else { return }
        // If the tab became visible while we're still paused (the foreground occlusion flip
        // can run before resume() clears isPaused), defer to resume() instead of dropping the
        // unthrottle — otherwise isThrottled stays true and repaints are suppressed.
        guard !isPaused else {
            pendingUnthrottlePredictionMode = predictionMode
            return
        }
        isThrottled = false

        // Restore configured prediction mode
        setPredictionMode(predictionMode)

        // Request repaint to refresh display with any accumulated changes
        repaintRequested = true
        frameDirty = true

        Self.logger.debug("State sync unthrottled (tab focused)")

        // Trigger immediate tick to refresh display
        triggerTick()
    }

    // MARK: - Input

    /// Sends a keystroke to the server (synchronous for minimal latency)
    /// - Parameter data: The keystroke data
    func sendKeystroke(_ data: Data) {
        guard isRunning, !sender.getShutdownInProgress() else { return }

        let prediction = overlays.getPredictionEngine()
        prediction.setLocalFrameSent(sender.getSentStateLast())

        let isPaste = data.count > 100
        if isPaste {
            prediction.reset()
        }

        for byte in data {
            if !isPaste {
                prediction.newUserByte(byte, fb: localFramebuffer)
            }
            if byte == 0x0C { // Ctrl-L
                repaintRequested = true
            }
            sender.getCurrentState().append(keystroke: byte)
        }

        // Mark frame dirty for prediction overlay updates
        frameDirty = true
        triggerTick()
    }

    /// Sends a resize notification to the server
    /// - Parameters:
    ///   - width: New terminal width in columns
    ///   - height: New terminal height in rows
    ///   - requestRepaint: Whether to request a full repaint after resize (default true).
    ///     Set to false during resume jiggle to avoid premature repaints with garbage state.
    ///   - wakeSender: Whether to wake the send loop (default true).
    ///     Set to false during resume to avoid triggering outputNewFrame() before good data arrives.
    func sendResize(width: UInt32, height: UInt32, requestRepaint: Bool = true, wakeSender: Bool = true) async throws {
        guard isRunning, !sender.getShutdownInProgress() else { return }

        sender.getCurrentState().append(resize: Int(width), height: Int(height))
        overlays.getPredictionEngine().reset()
        if requestRepaint {
            repaintRequested = true
        }
        if wakeSender {
            self.triggerTick()
        }
    }

    /// Sets the prediction display mode
    /// - Parameter mode: The prediction mode from MoshConfig
    func setPredictionMode(_ mode: MoshConfig.PredictionMode) {
        let engineMode: MoshPredictionEngine.DisplayPreference
        switch mode {
        case .always: engineMode = .always
        case .adaptive: engineMode = .adaptive
        case .never: engineMode = .never
        }
        overlays.getPredictionEngine().setDisplayPreference(engineMode)
    }

    /// Sets whether predictions replace existing cells instead of shifting the row.
    func setPredictOverwrite(_ overwrite: Bool) {
        overlays.getPredictionEngine().setPredictOverwrite(overwrite)
    }

    /// Requests a full repaint of the terminal display
    /// Call this after resume to ensure the display is properly refreshed
    /// Note: This only sets the flag - the actual repaint happens when new data arrives
    /// or on the next send loop tick. We don't call outputNewFrame() immediately
    /// because on resume our local state may be stale/empty.
    func requestRepaint() {
        repaintRequested = true
        // Don't call outputNewFrame() immediately - on resume, our localFramebuffer
        // is empty and receiver state has diffs applied to empty base (garbage).
        // Let incoming data trigger the repaint naturally.
    }

    /// Enables repainting after resume stabilization is complete.
    /// Call this after the resize jiggle has been sent to allow subsequent
    /// incoming packets to trigger repaint.
    func enableRepainting() {
        Self.logger.info("Resume stabilization complete - enabling repainting")
        isResumeStabilizing = false
        repaintRequested = true
    }

    /// Requests a fast recovery on foreground by sending an immediate ack/keepalive.
    /// If the transport can't send, forces an immediate reconnect attempt.
    func requestForegroundRecovery(reason: String = "foreground") {
        guard isRunning else { return }

        if !transport.canSend {
            transport.requestImmediateReconnect(reason: reason)
        }

        sender.requestImmediateAck()
        triggerTick()
    }

    // MARK: - Private Methods

    private func emitOutput(_ string: String) {
        guard !string.isEmpty else { return }
        delegate?.stateSync(self, didReceiveOutput: Data(string.utf8))
    }

    /// Emits a resize callback if the remote framebuffer size changed.
    /// Used when output rendering is suppressed (resume stabilization, throttling)
    /// so we can still track server size changes deterministically.
    private func notifyRemoteResizeIfNeeded() {
        let remoteFb = receiver.latestRemoteState.framebuffer
        let width = remoteFb.cursorState.getWidth()
        let height = remoteFb.cursorState.getHeight()

        if width != lastRemoteSize.width || height != lastRemoteSize.height {
            lastRemoteSize = (width: width, height: height)
            delegate?.stateSync(self, didReceiveResize: UInt32(width), height: UInt32(height))
        }
    }

    private func outputNewFrame() {
        guard isRunning else { return }

        // Skip expensive framebuffer operations if nothing has changed
        guard frameDirty || repaintRequested else { return }

        let remoteFb = receiver.latestRemoteState.framebuffer.copy()

        if remoteFb.cursorState.getWidth() != lastRemoteSize.width || remoteFb.cursorState.getHeight() != lastRemoteSize.height {
            lastRemoteSize = (remoteFb.cursorState.getWidth(), remoteFb.cursorState.getHeight())
            delegate?.stateSync(self, didReceiveResize: UInt32(lastRemoteSize.width), height: UInt32(lastRemoteSize.height))
        }

        overlays.apply(remoteFb)
        let diff = display.renderDelta(initialized: !repaintRequested, last: localFramebuffer, f: remoteFb)
        emitOutput(diff)

        repaintRequested = false
        frameDirty = false
        localFramebuffer = remoteFb
    }

    // MARK: - Timer-based Tick Scheduling

    /// Starts the timer-based tick system (replaces the old polling loop)
    private func startTickScheduler() {
        nextTickTask?.cancel()
        nextTickTime = UInt64.max
        scheduleNextTick()
    }

    /// Performs protocol tick and schedules the next one
    private func performTick() {
        guard isRunning, !isPaused else {
            // If paused, don't schedule next tick - resume() will restart
            return
        }

        // When throttled, skip expensive operations but still run protocol
        if isThrottled {
            // Only run essential protocol operations
            sender.performCycle()

            // Keep the roam/network banner current even while throttled. It's cheap (no
            // framebuffer render) and a stale "Last contact Ns ago" banner that never
            // updates or clears is worse than the CPU this saves.
            let currentBanner = getCurrentBannerState()
            if currentBanner != lastBannerState {
                lastBannerState = currentBanner
                delegate?.stateSyncDidUpdateBannerState(self, state: currentBanner)
            }

            // Still check shutdown conditions
            if remoteShutdownRequested && sender.getCounterpartyShutdownAcknowledged() {
                Self.logger.info("Server requested shutdown (ack sent). Stopping state sync.")
                stop()
                delegate?.stateSync(self, didChangeState: .serverShutdown)
                return
            }

            if sender.getShutdownInProgress() && sender.getShutdownAcknowledged() {
                Self.logger.info("Shutdown acknowledged. Stopping state sync.")
                stop()
                delegate?.stateSync(self, didChangeState: .serverShutdown)
                return
            }

            if sender.getShutdownInProgress() && sender.hasCloseTimedOut {
                Self.logger.info("Shutdown ack timed out. Stopping state sync.")
                stop()
                delegate?.stateSync(self, didChangeState: .disconnected)
                return
            }

            scheduleNextTick()
            return
        }

        // PRE-RENDER PATTERN: Output frame FIRST, before protocol operations.
        // Render at the START of the loop
        // before waiting for events. This reduces perceived latency by showing predicted
        // keystrokes immediately rather than waiting for protocol tick completion.
        if frameDirty && !isResumeStabilizing {
            outputNewFrame()
        }

        // Protocol operations
        sender.performCycle()
        updateConnectionNotifications()

        // Update banner state - only notify on change
        let currentBanner = getCurrentBannerState()
        if currentBanner != lastBannerState {
            lastBannerState = currentBanner
            delegate?.stateSyncDidUpdateBannerState(self, state: currentBanner)
        }

        // Check shutdown conditions
        if remoteShutdownRequested && sender.getCounterpartyShutdownAcknowledged() {
            Self.logger.info("Server requested shutdown (ack sent). Stopping state sync.")
            stop()
            delegate?.stateSync(self, didChangeState: .serverShutdown)
            return
        }

        if sender.getShutdownInProgress() && sender.getShutdownAcknowledged() {
            Self.logger.info("Shutdown acknowledged. Stopping state sync.")
            stop()
            delegate?.stateSync(self, didChangeState: .serverShutdown)
            return
        }

        if sender.getShutdownInProgress() && sender.hasCloseTimedOut {
            Self.logger.info("Shutdown ack timed out. Stopping state sync.")
            stop()
            delegate?.stateSync(self, didChangeState: .disconnected)
            return
        }

        // Schedule next tick based on protocol timers
        scheduleNextTick()
    }

    /// Schedules the next tick based on protocol timers
    private func scheduleNextTick() {
        guard isRunning, !isPaused else { return }

        // Already on MainActor - no Task wrapper needed
        let waitMs = nextWaitTimeMs()
        let now = ProtocolTiming.monotonicNowMs()
        let targetTime = waitMs == UInt64.max ? UInt64.max : now + waitMs

        // Only reschedule if we need to wake earlier than currently planned
        guard targetTime < nextTickTime else { return }
        nextTickTime = targetTime

        nextTickTask?.cancel()

        if waitMs == UInt64.max {
            // Nothing to schedule - will be triggered by events
            nextTickTask = nil
            return
        }

        nextTickTask = Task { @MainActor [weak self] in
            if waitMs > 0 {
                try? await Task.sleep(nanoseconds: waitMs * 1_000_000)
            }
            guard let self = self, !Task.isCancelled, self.isRunning else { return }
            self.nextTickTime = UInt64.max
            self.performTick()
        }
    }

    /// Triggers an immediate tick (called from event handlers like packet reception)
    private func triggerTick() {
        guard isRunning, !isPaused else { return }

        // Coalesce multiple trigger requests - if a tick is already pending, skip
        // This prevents creating multiple Task objects when rapid events occur
        guard !tickPending else { return }
        tickPending = true

        // Cancel any pending scheduled tick
        nextTickTask?.cancel()
        nextTickTime = UInt64.max

        // Perform tick immediately (synchronous - no Task needed!)
        tickPending = false
        performTick()
    }

    private func nextWaitTimeMs() -> UInt64 {
        let senderWait = sender.nextWakeInterval()

        // When throttled, predictions are disabled (display set to .never), so honor ONLY the
        // notification/roam-banner timer — NOT overlays.waitTime(), which also folds in the
        // prediction engine's ~50ms wake and would keep a hidden tab ticking at ~20Hz while
        // stale prediction overlays linger. Cap at the long throttled interval; when no banner
        // is active the banner timer is Int.max, so this stays at the throttled cadence.
        if isThrottled {
            let bannerWait = overlays.getNotificationEngine().waitTime()
            let bannerMs: UInt64 = bannerWait >= Int.max ? UInt64.max : UInt64(max(0, bannerWait))
            return min(senderWait, bannerMs, ProtocolTiming.throttledCycleIntervalMs)
        }

        let overlayWait = overlays.waitTime()
        let overlayMs: UInt64 = overlayWait >= Int.max ? UInt64.max : UInt64(max(0, overlayWait))
        var wait = min(senderWait, overlayMs)

        if stillConnecting() {
            wait = min(wait, 250)
        }
        return wait
    }

    private func stillConnecting() -> Bool {
        receiver.latestRemoteVersion == 0
    }

    /// Whether a hole-punch is currently in-flight (delegate approved and awaiting response)
    private var holePunchInFlight = false

    /// Timeout threshold for triggering mid-session hole-punch (faster than serverLate's 6.5s)
    private static let midSessionPunchThreshold: UInt64 = 2000  // 2 seconds

    /// Last time we attempted a hole-punch request (initial or mid-session)
    private var lastPunchTime: UInt64 = 0

    /// Minimum interval between hole-punch requests
    private static let punchInterval: UInt64 = 5_000  // 5 seconds

    private func updateConnectionNotifications() {
        // Don't request hole-punches while paused (app backgrounded)
        guard !isPaused else { return }

        let now = ProtocolTiming.monotonicNowMs()
        let latestRemoteTimestamp = receiver.getLatestRemoteTimestamp()

        // CASE 1: Initial connection - waiting for first server response
        if stillConnecting() && !sender.getShutdownInProgress() && now - latestRemoteTimestamp > 250 {
            if now - latestRemoteTimestamp > 15_000 {
                overlays.getNotificationEngine().setNotificationString("Timed out waiting for server...", permanent: true)
                sender.initiateGracefulClose()
            } else {
                // Show connecting overlay and request hole-punch (throttled)
                overlays.getNotificationEngine().setNotificationString(connectingNotification)

                let canPunch = (now - lastPunchTime) > Self.punchInterval

                if canPunch {
                    lastPunchTime = now
                    // Only attempt when the banner is visible
                    if overlays.getNotificationEngine().isBannerVisible(),
                       delegate?.stateSyncNeedsHolePunch(self) == true {
                        holePunchInFlight = true
                        overlays.getNotificationEngine().setHolePunchInProgress(true)
                        Self.logger.info("Hole-punch requested by delegate")
                    }
                }
            }
        }
        // CASE 2: Mid-session connectivity loss - server unresponsive after connection was established
        else if !stillConnecting() && !sender.getShutdownInProgress() {
            let timeSinceLastResponse = now - latestRemoteTimestamp
            let serverUnresponsive = timeSinceLastResponse > Self.midSessionPunchThreshold
            let canPunch = (now - lastPunchTime) > Self.punchInterval

            if serverUnresponsive && canPunch && overlays.getNotificationEngine().isBannerVisible() {
                lastPunchTime = now

                // Ask delegate if hole-punch should be attempted
                if delegate?.stateSyncNeedsHolePunch(self) == true {
                    holePunchInFlight = true
                    overlays.getNotificationEngine().setHolePunchInProgress(true)
                    Self.logger.info("Mid-session hole-punch requested (server unresponsive for \(timeSinceLastResponse)ms)")
                }
            }
        }
        // CASE 3: Connection recovered - clear notifications and reset punch tracking
        else if receiver.latestRemoteVersion != 0
                    && overlays.getNotificationEngine().getNotificationString() == connectingNotification {
            overlays.getNotificationEngine().setNotificationString("")
            // Reset hole-punch flags when connection succeeds
            holePunchInFlight = false
            overlays.getNotificationEngine().setHolePunchInProgress(false)
            lastPunchTime = now
        }
        // CASE 4: Received data after mid-session punch - reset punch flag
        else if holePunchInFlight && !stillConnecting() {
            // Check if we've received recent data (within threshold)
            if now - latestRemoteTimestamp < Self.midSessionPunchThreshold {
                holePunchInFlight = false
                overlays.getNotificationEngine().setHolePunchInProgress(false)
                lastPunchTime = now
            }
        }
    }

    /// Sets up the transport delegate
    private func setupTransportDelegate() {
        let delegateWrapper = TransportDelegateWrapper(stateSync: self)
        transportDelegateWrapper = delegateWrapper
        transport.delegate = delegateWrapper
    }

    fileprivate func handleTransportError(_ error: MoshError) {
        overlays.getNotificationEngine().setNetworkError(error.localizedDescription)
        if !error.isRecoverable {
            delegate?.stateSync(self, didEncounterError: error)
        }
    }

    /// Handles a received packet (synchronous hot path - no Task overhead)
    /// - Parameters:
    ///   - packet: The received packet
    ///   - estimatedRTT: Current RTT estimate from transport (for immediate sendInterval update)
    fileprivate func handleReceivedPacket(_ packet: MoshPacket, estimatedRTT: Double) {
        guard isRunning else { return }

        // Drop packets while paused to prevent state advancement during save
        if isPaused {
            Self.logger.debug("Dropping packet while paused (seq=\(packet.sequenceNumber))")
            return
        }

        do {
            try receiver.processPacket(packet, synchronizer: &sender)
            overlays.getNotificationEngine().serverHeard(receiver.getLatestRemoteTimestamp())
            overlays.getNotificationEngine().serverAcked(sender.getSentStateAckedTimestamp())
            overlays.getPredictionEngine().setLocalFrameAcked(sender.getSentStateAcked())
            // Update sendInterval cache IMMEDIATELY from RTT (not async)
            // This ensures prediction engine sees current value, not stale cache
            sender.updateTransmitInterval(fromRTT: estimatedRTT)
            overlays.getPredictionEngine().setSendInterval(sender.getTransmitInterval())
            overlays.getPredictionEngine().setLocalFrameLateAcked(receiver.latestRemoteState.echoAcknowledgment)

            if receiver.latestRemoteVersion == UInt64.max {
                remoteShutdownRequested = true
            }

            overlays.getNotificationEngine().clearNetworkError()

            // Mark frame as dirty - new data arrived from server
            frameDirty = true

            // When output rendering is suppressed (resume stabilization or throttling),
            // still track remote resize changes so callers can wait on them.
            if isResumeStabilizing || isThrottled {
                notifyRemoteResizeIfNeeded()
            }

            // Only call outputNewFrame if not in resume stabilization mode or throttled.
            // During stabilization, we suppress repaints until the resize jiggle
            // has been sent and we've been told it's safe to repaint.
            // When throttled, we skip frame rendering to save CPU - the frame will
            // render when the tab becomes visible again and unthrottle() is called.
            if !isResumeStabilizing && !isThrottled {
                outputNewFrame()
            }
            triggerTick()

            // Notify delegate of latency (estimatedRTT already passed in, convert to Int for display)
            let latencyMs = estimatedRTT < 1000 ? Int(estimatedRTT) : nil
            delegate?.stateSync(self, didChangeState: .running(latencyMs: latencyMs))

            // Notify that we received an actual network packet (distinct from local output)
            delegate?.stateSyncDidReceiveServerPacket(self)
        } catch let error as MoshError {
            Self.logger.error("Failed to process packet: \(error.localizedDescription)")
            delegate?.stateSync(self, didEncounterError: error)
        } catch {
            Self.logger.error("Unexpected error processing packet: \(error.localizedDescription)")
        }
    }

    /// Handles transport state changes
    fileprivate func handleTransportStateChange(_ state: MoshTransport.State) {
        guard isRunning else { return }

        switch state {
        case .connected:
            overlays.getNotificationEngine().clearNetworkError()
            delegate?.stateSync(self, didChangeState: .running(latencyMs: nil))
        case .roaming(let previousPath):
            overlays.getNotificationEngine().setNetworkError("Waiting for network...")
            delegate?.stateSync(self, didChangeState: .roaming(previousNetwork: previousPath))
        case .disconnected:
            // Keep session alive; mosh tolerates long disconnects.
            // Still notify delegate so UI can update, but don't trigger reconnect
            overlays.getNotificationEngine().setNetworkError("Network unavailable")
        case .failed(let reason):
            // Keep session alive; treat as transient unless explicitly stopped.
            // The transport layer handles reconnection internally.
            overlays.getNotificationEngine().setNetworkError(reason)
        default:
            break
        }
    }
}

// MARK: - Transport Delegate Wrapper

/// Wrapper to bridge transport delegate to state sync
private final class TransportDelegateWrapper: MoshTransport.Delegate, @unchecked Sendable {
    private weak var stateSync: MoshStateSync?

    init(stateSync: MoshStateSync) {
        self.stateSync = stateSync
    }

    @MainActor
    func transport(_ transport: MoshTransport, didChangeState state: MoshTransport.State) {
        stateSync?.handleTransportStateChange(state)
    }

    @MainActor
    func transport(_ transport: MoshTransport, didReceivePacket packet: MoshPacket, estimatedRTT: Double) {
        // Call packet handler synchronously - both are MainActor-isolated
        // Removing Task wrapper eliminates ~2-5ms overhead per packet
        // Pass estimatedRTT for immediate sendInterval cache update
        stateSync?.handleReceivedPacket(packet, estimatedRTT: estimatedRTT)
    }

    @MainActor
    func transport(_ transport: MoshTransport, didEncounterError error: MoshError) {
        guard let stateSync = stateSync else { return }
        stateSync.handleTransportError(error)
    }
}
