//
//  HardwareKeyActivityCoordinator.swift
//  rootshell
//
//  Single source of truth for surfacing an in-flight YubiKey PIV signing
//  operation to the terminal UI, so the user knows when to insert or touch
//  their key instead of the app silently waiting.
//
//  Design notes:
//   - Driven ONLY by the SSH/agent signing entry points in YubiKeySigner
//     (signWithPIV). YubiKey PIV signing funnels through there regardless of
//     how the connection was started — plain SSH, mosh, tssh/trzsz, a
//     local-shell `ssh`, or a reconnect — so a single hook here covers every
//     path. Settings/management ops (PIN change, key gen, discovery) never call
//     the signer, so they never surface this overlay.
//   - The overlay is app-global. There is exactly one physical YubiKey and
//     YubiKeySigner serialises all signing against it, so at most one activity
//     is ever in flight. Rendering it on the focused terminal (rather than
//     attributing to a specific TerminalView) keeps it robust across the many
//     connection code paths and avoids "didn't show" gaps.
//   - A short grace delay gates visibility: when the key is already inserted a
//     wired sign completes in well under the grace, so the overlay never
//     flashes. Only a genuine wait (key absent) or a touch-policy block (sign
//     stalls on a finger) outlasts the grace and becomes visible.
//
//  Apple FIDO2 is intentionally NOT routed here: iOS presents its own system
//  sheet (insert + touch + transport) for ASAuthorizationController, so there
//  is nothing for us to add and a second overlay would double-prompt.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import os.log

/// Coordinates the "insert / touch your YubiKey" overlay shown over the
/// terminal during a PIV signing operation.
@MainActor
@Observable
final class HardwareKeyActivityCoordinator {
    @ObservationIgnored private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "HardwareKeyActivity"
    )

    static let shared = HardwareKeyActivityCoordinator()

    private init() {}

    // MARK: - Phases

    /// The distinct things we ask the user to do (or inform them of) while a PIV
    /// signing operation is in flight. Only `waitingForDevice` and
    /// `touchRequired` are ever shown; the others are internal/transient and
    /// suppressed (the system NFC sheet / PIN sheet own the screen, or the op is
    /// fast enough to never warrant an overlay).
    enum Phase: Equatable, Sendable {
        /// Wired key (USB-C / Lightning) not yet inserted — the connect blocks
        /// until it appears. Shown after a grace delay (so a present key never
        /// flashes it), then persists with a Cancel until inserted/cancelled.
        case waitingForDevice(transport: YubiKeyConnectionMethod)
        /// The sign APDU is blocking on a physical touch (slot touch policy).
        case touchRequired
        /// Talking to the card / signing — transient, not shown.
        case working
        /// The system NFC sheet (or PIN sheet) owns the screen — not shown.
        case nfcPresented
        /// A terminal error — not shown here (the session surfaces its own).
        case failed(String)

        /// Whether this phase is user-actionable enough to display an overlay.
        var isUserActionable: Bool {
            switch self {
            case .waitingForDevice, .touchRequired: return true
            case .working, .nfcPresented, .failed: return false
            }
        }
    }

    /// A user-visible PIV signing activity.
    struct Activity: Equatable, Sendable {
        var phase: Phase
    }

    /// The activity currently being presented, if any. Observed by the UI. Only
    /// ever holds an actionable phase (insert / touch).
    private(set) var activity: Activity?

    /// The current op's full intent (tracks every phase, shown or not). Distinct
    /// from `activity`, which is gated by `isUserActionable` + the grace delay.
    @ObservationIgnored private var intent: Activity?

    @ObservationIgnored private var graceTask: Task<Void, Never>?

    /// How long a wired wait must persist before we show "Insert your YubiKey".
    /// Long enough that an already-inserted key (fast sign) never flashes it.
    private static let waitingGrace: Duration = .milliseconds(600)

    // MARK: - Lifecycle (driven by YubiKeySigner)

    /// Begin tracking an SSH/agent PIV signing op. Nothing is shown yet — the
    /// phase driver decides if/when an overlay appears.
    func beginActivity() {
        cancelGrace()
        intent = Activity(phase: .working)
        activity = nil
    }

    /// Clear everything. Called from the signer's `defer`, so it always runs on
    /// success, failure, or cancellation.
    func finishActivity() {
        cancelGrace()
        intent = nil
        activity = nil
    }

    /// Force a specific phase (used by the signer's touch-escalation timer).
    func update(phase: Phase) {
        applyPhase(phase)
    }

    // MARK: - Phase driver (from YubiKeyConnectionManager.connectionState)

    /// Map a raw connection-manager state onto a phase, but only while an
    /// activity is being tracked. No-op otherwise (Settings ops, idle).
    func connectionStateChanged(_ state: YubiKeyConnectionState, isNFCActive: Bool) {
        guard intent != nil else { return }
        guard let phase = Self.phase(for: state, isNFCActive: isNFCActive) else { return }
        applyPhase(phase)
    }

    // MARK: - Internals

    private func applyPhase(_ phase: Phase) {
        guard intent != nil else { return }
        intent?.phase = phase

        switch phase {
        case .waitingForDevice:
            // Show only if the wait outlasts the grace — a present key
            // transitions out of this phase first, so nothing flashes.
            if activity == nil {
                scheduleGraceShow()
            } else {
                activity?.phase = phase
            }
        case .touchRequired:
            // A real touch block (already past the working phase) — show now.
            cancelGrace()
            activity = intent
        case .working, .nfcPresented, .failed:
            // Not actionable here: hide and cancel any pending show.
            cancelGrace()
            activity = nil
        }
    }

    private func scheduleGraceShow() {
        cancelGrace()
        graceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.waitingGrace)
            guard let self, !Task.isCancelled else { return }
            guard let intent = self.intent, case .waitingForDevice = intent.phase else { return }
            self.activity = intent
        }
    }

    private func cancelGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    /// Pure mapping. Returns nil to leave the current phase unchanged.
    private static func phase(for state: YubiKeyConnectionState, isNFCActive: Bool) -> Phase? {
        // The system NFC sheet always wins: never stack our overlay on it.
        if isNFCActive { return .nfcPresented }
        switch state {
        case .waitingForDevice(let transport):
            return .waitingForDevice(transport: transport)
        case .connecting(let method):
            // Wired connecting == waiting for the key to appear.
            return method == .nfc ? .nfcPresented : .waitingForDevice(transport: method)
        case .authenticating:
            // PIN entry has its own sheet on top — suppress our overlay.
            return .working
        case .signing:
            return .working
        case .connected:
            return .working
        case .error(let message):
            return .failed(message)
        case .disconnected:
            return nil
        }
    }
}
