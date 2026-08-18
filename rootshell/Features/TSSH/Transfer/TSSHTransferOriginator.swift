//
//  TSSHTransferOriginator.swift
//  rootshell
//
//  Coordinates the originating side of a "Transfer to Nearby Device" flow.
//  Owns the NSUserActivity, derives the shared key when the receiver
//  responds, ships the encrypted bootstrap payload, and finalizes by
//  detaching the local session once the peer ack's success.
//

import Combine
import CryptoKit
import Foundation
import os.log
import UIKit

/// A SwiftUI-friendly handle on an in-flight transfer offer. `Identifiable`
/// so it works as the item binding for `.sheet(item:)`.
@MainActor
struct TrzszTransferOriginRequest: Identifiable {
    let id = UUID()
    let originator: TrzszTransferOriginator
    let displayName: String
    let tabId: UUID
    let leafId: UUID
}

@MainActor
final class TrzszTransferOriginator: NSObject, ObservableObject {
    nonisolated private static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszTransferOriginator"
    )

    /// Coarse status published to the origin sheet UI.
    enum Status: Equatable, Sendable {
        case advertising            // NSUserActivity is current, nobody has connected yet.
        case negotiating            // Streams opened; performing key exchange.
        case sendingPayload         // Encrypted bootstrap is being written.
        case waitingForAck          // Bootstrap sent, peer is attaching.
        case completed(peerName: String)
        case failed(message: String)
        case cancelled
    }

    @Published private(set) var status: Status = .advertising
    @Published private(set) var peerDeviceName: String?

    /// Pre-snapshotted at offer time — read from the live session before any
    /// streams open so the user's terminal isn't racing the wire.
    private let payload: TrzszTransferPayload

    /// Ephemeral keypair for this offer. New keypair per transfer; never
    /// persisted.
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// The session we'll detach once the peer ack's success.
    private weak var session: TrzszSession?

    /// Closure called on the main actor after a confirmed-successful
    /// transfer. Must close the originating split/tab. Caller-supplied so
    /// this coordinator stays decoupled from MainView.
    private let onTransferConfirmed: @MainActor () -> Void

    /// The advertising activity. Held to keep it alive (NSUserActivity is
    /// retained by becomeCurrent but releasing our handle drops the delegate).
    private var activity: NSUserActivity?

    /// Channel built once the peer accepts and Apple delivers continuation
    /// streams via the delegate callback.
    private var channel: TrzszTransferChannel?

    /// Background driver for the framing protocol. Held so we can cancel.
    private var pumpTask: Task<Void, Never>?

    init(
        payload: TrzszTransferPayload,
        session: TrzszSession,
        onTransferConfirmed: @escaping @MainActor () -> Void
    ) {
        self.payload = payload
        self.session = session
        self.privateKey = TrzszTransferCrypto.generateEphemeralKeyPair()
        self.onTransferConfirmed = onTransferConfirmed
        super.init()
    }

    /// Builds and broadcasts the NSUserActivity. Idempotent — calling twice
    /// has no effect after the first call.
    func start() {
        guard activity == nil else { return }

        let activity = NSUserActivity(activityType: TrzszTransferActivity.activityType)
        activity.title = String(
            localized: "Transfer SSH Session: \(payload.displayName)",
            comment: "Handoff title shown on nearby devices when a tssh session is being transferred"
        )
        activity.userInfo = [
            TrzszTransferActivity.UserInfoKey.version: TrzszTransferActivity.payloadVersion,
            TrzszTransferActivity.UserInfoKey.originPubKey: privateKey.publicKey.rawRepresentation,
            TrzszTransferActivity.UserInfoKey.originDeviceName: payload.originDeviceName,
            TrzszTransferActivity.UserInfoKey.displayName: payload.displayName,
            TrzszTransferActivity.UserInfoKey.host: payload.sshConfig.host,
        ]
        activity.requiredUserInfoKeys = TrzszTransferActivity.requiredUserInfoKeys
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        activity.supportsContinuationStreams = true
        activity.delegate = self

        self.activity = activity
        activity.becomeCurrent()
        Self.logger.info("Trzsz transfer offer published")
        status = .advertising
    }

    /// User tapped Cancel, or the parent sheet is dismissing. Tears down
    /// the activity and any in-flight stream channel without touching the
    /// underlying TrzszSession.
    func cancel() {
        guard status != .cancelled, !isTerminalStatus else {
            shutdownActivity()
            return
        }
        Self.logger.info("Trzsz transfer cancelled by originator")
        status = .cancelled
        shutdownActivity()
    }

    /// True once we've reached a final state — the parent sheet should
    /// dismiss itself when this is true and `status` is .completed/.failed/.cancelled.
    var isTerminalStatus: Bool {
        switch status {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    // MARK: - Stream pump

    private func handleStreams(input: InputStream, output: OutputStream) {
        guard !isTerminalStatus else {
            input.close()
            output.close()
            return
        }
        guard pumpTask == nil else {
            // Two streams shouldn't arrive twice; if Continuity does deliver
            // a second pair, drop the new one rather than confuse our state.
            input.close()
            output.close()
            return
        }

        let channel = TrzszTransferChannel(input: input, output: output)
        self.channel = channel
        status = .negotiating

        let payload = self.payload
        let privateKey = self.privateKey

        // Status setter the off-main protocol pump uses to publish phase
        // transitions back to the sheet UI. The pump itself never touches
        // `self.status` directly.
        let publishStatus: @MainActor @Sendable (Status) -> Void = { [weak self] new in
            self?.status = new
        }
        let setStatus: @Sendable (Status) -> Void = { new in
            Task { await publishStatus(new) }
        }
        let handleResult: @MainActor @Sendable (Result<ProtocolOutcome, Error>) -> Void = { [weak self] result in
            self?.handleProtocolResult(result)
        }

        // The pump body MUST run off the main thread. With this project's
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Task.detached closures
        // inherit MainActor isolation by default, so we route through a
        // `nonisolated` static helper to force the executor hop.
        pumpTask = Task.detached(priority: .userInitiated) {
            let result = await Self.runProtocolDetached(
                channel: channel,
                payload: payload,
                privateKey: privateKey,
                setStatus: setStatus
            )
            await handleResult(result)
        }
    }

    /// Off-main entry point for the wire protocol. Owns the channel's
    /// open/close lifecycle so the blocking I/O never touches main.
    nonisolated private static func runProtocolDetached(
        channel: TrzszTransferChannel,
        payload: TrzszTransferPayload,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        setStatus: @Sendable (Status) -> Void
    ) async -> Result<ProtocolOutcome, Error> {
        channel.open()
        defer { channel.close() }
        do {
            let outcome = try await runProtocol(
                channel: channel,
                payload: payload,
                privateKey: privateKey,
                setStatus: setStatus
            )
            return .success(outcome)
        } catch {
            return .failure(error)
        }
    }

    private struct ProtocolOutcome {
        let peerName: String
        let success: Bool
        let errorMessage: String?
        let attemptedClientId: UInt64?
    }

    /// Runs the wire protocol off-main:
    ///   1. read RECEIVER_HELLO
    ///   2. derive shared key
    ///   3. seal payload, send BOOTSTRAP
    ///   4. read RECEIVER_ACK
    ///
    /// `setStatus` is invoked at each phase boundary so the origin sheet can
    /// show the user what's actually happening instead of stalling on
    /// "Exchanging encryption keys" the whole way through.
    ///
    /// Every channel I/O carries a deadline so a non-responsive peer
    /// can't park the protocol task indefinitely; the watchdog is more
    /// patient than the human looking at the sheet.
    nonisolated private static func runProtocol(
        channel: TrzszTransferChannel,
        payload: TrzszTransferPayload,
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        setStatus: @Sendable (Status) -> Void
    ) async throws -> ProtocolOutcome {
        // Hello must arrive within 30s of streams opening — Continuity
        // typically delivers it in well under a second.
        let helloDeadline = Date().addingTimeInterval(30)
        let helloFrame = try channel.receiveFrame(deadline: helloDeadline)
        let hello = try JSONDecoder().decode(TrzszTransferHello.self, from: helloFrame)
        guard hello.version == TrzszTransferActivity.payloadVersion else {
            throw TrzszTransferError.versionMismatch(
                received: hello.version,
                expected: TrzszTransferActivity.payloadVersion
            )
        }

        let key = try TrzszTransferCrypto.deriveSharedKey(
            privateKey: privateKey,
            peerPublicKeyRaw: hello.receiverPubKey
        )

        // Adjust dimensions to the receiver's request before sealing — the
        // receiver may have a different screen size and we want attach to
        // resize to match.
        var outgoing = payload
        outgoing = TrzszTransferPayload(
            version: outgoing.version,
            credentials: outgoing.credentials,
            sshConfig: outgoing.sshConfig,
            transportMode: outgoing.transportMode,
            displayName: outgoing.displayName,
            cols: hello.requestedCols > 0 ? hello.requestedCols : outgoing.cols,
            rows: hello.requestedRows > 0 ? hello.requestedRows : outgoing.rows,
            primaryScrollback: outgoing.primaryScrollback,
            alternateScreen: outgoing.alternateScreen,
            sessionStartedAt: outgoing.sessionStartedAt,
            originDeviceName: outgoing.originDeviceName
        )

        setStatus(.sendingPayload)

        let plaintext = try JSONEncoder().encode(outgoing)
        let ciphertext = try TrzszTransferCrypto.seal(plaintext, using: key)

        let bootstrap = TrzszTransferBootstrap(ciphertext: ciphertext)
        let bootstrapFrame = try JSONEncoder().encode(bootstrap)
        // Bootstrap payload can be up to a few hundred KB (scrollback);
        // 30s is generous for the write to drain.
        let bootstrapDeadline = Date().addingTimeInterval(30)
        try channel.sendFrame(bootstrapFrame, deadline: bootstrapDeadline)

        setStatus(.waitingForAck)

        // Ack waits on the receiver actually attaching to the remote
        // session — SSH reconnect + session attach can take a while
        // on a slow link, so allow 60s.
        let ackDeadline = Date().addingTimeInterval(60)
        let ackFrame = try channel.receiveFrame(deadline: ackDeadline)
        let ack = try JSONDecoder().decode(TrzszTransferAck.self, from: ackFrame)
        return ProtocolOutcome(
            peerName: hello.receiverDeviceName,
            success: ack.success,
            errorMessage: ack.errorMessage,
            attemptedClientId: ack.attemptedClientId
        )
    }

    private func handleProtocolResult(_ result: Result<ProtocolOutcome, Error>) {
        guard status != .cancelled else {
            shutdownActivity()
            return
        }
        switch result {
        case .success(let outcome):
            peerDeviceName = outcome.peerName
            if outcome.success {
                Self.logger.info("Trzsz transfer ack'd by \(outcome.peerName, privacy: .public)")
                status = .completed(peerName: outcome.peerName)
                shutdownActivity()
                // Detach our session — peer owns it now.
                session?.detachForTransfer()
                onTransferConfirmed()
            } else {
                let msg = (outcome.errorMessage ?? "Receiver could not attach").trzszTransferDisplaySafe
                Self.logger.error("Trzsz transfer rejected: \(msg, privacy: .public)")
                if let attemptedClientId = outcome.attemptedClientId {
                    session?.advanceTransferClientIdAfterFailedAttempt(attemptedClientId)
                }
                status = .failed(message: msg)
                shutdownActivity()
            }
        case .failure(let error):
            let msg = error.trzszTransferDisplayDescription
            Self.logger.error("Trzsz transfer protocol error: \(msg, privacy: .public)")
            status = .failed(message: msg)
            shutdownActivity()
        }
    }

    private func shutdownActivity() {
        pumpTask?.cancel()
        pumpTask = nil
        let channelToClose = self.channel
        self.channel = nil
        activity?.invalidate()
        activity?.delegate = nil
        activity = nil
        if let channelToClose {
            Task.detached(priority: .userInitiated) {
                channelToClose.close()
            }
        }
    }
}

// MARK: - NSUserActivityDelegate

extension TrzszTransferOriginator: NSUserActivityDelegate {
    nonisolated func userActivity(
        _ userActivity: NSUserActivity,
        didReceive inputStream: InputStream,
        outputStream: OutputStream
    ) {
        // InputStream/OutputStream are not Sendable, but Apple guarantees
        // these are scoped to this delegate call — pass them through to the
        // main actor via an unchecked-Sendable wrapper.
        struct StreamPair: @unchecked Sendable {
            let input: InputStream
            let output: OutputStream
        }
        let pair = StreamPair(input: inputStream, output: outputStream)
        Task { @MainActor [weak self] in
            self?.handleStreams(input: pair.input, output: pair.output)
        }
    }

    nonisolated func userActivityWasContinued(_ userActivity: NSUserActivity) {
        // Receiver tapped the Handoff tile but hasn't called
        // getContinuationStreams yet. We don't change UI state here — the
        // stream-pair callback is what actually starts the transfer.
    }
}

// MARK: - Snapshot helper

/// Plain-Swift snapshot of what a TerminalView's surface looked like at
/// transfer-offer time. Built by the caller (which has the C surface
/// pointer) so this coordinator stays free of GhosttyKit imports.
struct TrzszTransferSnapshot {
    let primaryScrollback: Data
    let alternateScreen: Data?
    let cols: UInt16
    let rows: UInt16
    /// Live OSC-updated terminal title at offer time (e.g. "vim", "~/src"),
    /// or nil/empty to fall back to `sshConfig.displayName` on the receiver.
    let liveTitle: String?
}

extension TrzszTransferOriginator {
    /// Picks the tab title to ship in the payload. Prefers the live OSC
    /// title the user sees on the originating device (e.g. "vim", "~/src")
    /// and falls back to the SSH `user@host` form if the title is empty
    /// or still the default "ghostty" placeholder.
    static func preferredDisplayName(liveTitle: String?, fallback: String) -> String {
        let trimmed = liveTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == "ghostty" {
            return fallback
        }
        return trimmed
    }

    /// Builds the payload from a live TrzszSession + a pre-captured screen
    /// snapshot. Returns nil if the session can't be transferred (no
    /// sessionID yet). Must be called on the main actor.
    static func buildPayload(
        from session: TrzszSession,
        snapshot: TrzszTransferSnapshot
    ) -> TrzszTransferPayload? {
        guard let creds = session.reserveCredentialsForTransferPayload() else {
            return nil
        }

        let primary = TrzszTransferPayload.truncatedScrollback(snapshot.primaryScrollback)

        return TrzszTransferPayload(
            version: TrzszTransferActivity.payloadVersion,
            credentials: creds,
            sshConfig: session.config.sshConfig,
            transportMode: session.config.transportMode,
            displayName: Self.preferredDisplayName(
                liveTitle: snapshot.liveTitle,
                fallback: session.config.sshConfig.displayName
            ),
            cols: max(snapshot.cols, 1),
            rows: max(snapshot.rows, 1),
            primaryScrollback: primary,
            alternateScreen: snapshot.alternateScreen,
            sessionStartedAt: session.connectionStartTime ?? Date(),
            originDeviceName: TrzszTransferActivity.currentDeviceName()
        )
    }
}
